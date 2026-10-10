// CameraManager.swift
// RetroPix — AVFoundation capture pipeline.
//
// Captures at 720p (16:9) on the back wide camera, uploads each frame to a
// Metal texture via CVMetalTextureCache (zero-copy). Thread-safe texture access
// via NSLock since the delegate callback fires on a private queue.

import AVFoundation
import Metal
import UIKit

final class CameraManager: NSObject, @unchecked Sendable {

    // MARK: — State

    private var captureSession: AVCaptureSession?
    nonisolated(unsafe) private var textureCache: CVMetalTextureCache?
    nonisolated(unsafe) private var currentCamera: AVCaptureDevice?   // retained for EV bias updates

    nonisolated(unsafe) private(set) var isTorchOn: Bool = false
    nonisolated(unsafe) private(set) var hasTorch: Bool = true
    nonisolated(unsafe) private var isSwitching: Bool = false
    var isFrontCamera: Bool = false
    private var currentPosition: AVCaptureDevice.Position = .back

    private let textureLock = NSLock()
    nonisolated(unsafe) private var _cameraTexture: MTLTexture?

    /// Latest camera frame as a Metal texture. Safe to read from any thread.
    var cameraTexture: MTLTexture? {
        textureLock.withLock { _cameraTexture }
    }

    private let sessionQueue = DispatchQueue(label: "retropix.camera.session", qos: .userInteractive)

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: — Setup

    func setup(device: MTLDevice) {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        requestPermissionAndStart()
    }

    @objc private func handleMemoryWarning() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.setupSession() }
            }
        default:
            break  // User denied — camera stays black
        }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .hd1280x720
            }

            // --- Input ---
            guard
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            // Minimal processing — continuous AF/AE, 30 FPS cap for efficiency + retro cadence
            try? camera.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: 30)
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameDuration <= frameDuration && frameDuration <= $0.maxFrameDuration
            }) {
                camera.activeVideoMinFrameDuration = frameDuration
                camera.activeVideoMaxFrameDuration = frameDuration
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.unlockForConfiguration()
            self.currentCamera = camera
            self.currentPosition = .back
            let torchAvail = camera.hasTorch
            DispatchQueue.main.async {
                self.hasTorch = torchAvail
                self.isFrontCamera = false
            }

            // --- Output ---
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true

            let captureQueue = DispatchQueue(label: "retropix.camera.capture", qos: .userInteractive)
            output.setSampleBufferDelegate(self, queue: captureQueue)

            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)

            // Force landscape (0°) — sensor native, matches our locked landscape UI
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }

            session.commitConfiguration()
            self.captureSession = session
            session.startRunning()
        }
    }

    /// Toggles between front and back camera inputs seamlessly with no jerks or glitches.
    func switchCamera(toFront: Bool? = nil, completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.captureSession else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let targetPosition: AVCaptureDevice.Position
            if let toFront = toFront {
                targetPosition = toFront ? .front : .back
            } else {
                targetPosition = (self.currentPosition == .back) ? .front : .back
            }

            if targetPosition == self.currentPosition {
                DispatchQueue.main.async { completion?(targetPosition == .front) }
                return
            }

            // If torch is on, turn it off before switching
            if self.isTorchOn {
                self.isTorchOn = false
                if let camera = self.currentCamera, camera.hasTorch {
                    try? camera.lockForConfiguration()
                    camera.torchMode = .off
                    camera.unlockForConfiguration()
                }
            }

            self.isSwitching = true
            self.textureLock.withLock {
                self._cameraTexture = nil
            }

            session.beginConfiguration()

            if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
                session.removeInput(currentInput)
            }

            guard
                let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: targetPosition),
                let newInput = try? AVCaptureDeviceInput(device: newCamera),
                session.canAddInput(newInput)
            else {
                // Rollback if unavailable
                if let currentCamera = self.currentCamera,
                   let fallbackInput = try? AVCaptureDeviceInput(device: currentCamera),
                   session.canAddInput(fallbackInput) {
                    session.addInput(fallbackInput)
                }
                session.commitConfiguration()
                self.isSwitching = false
                let actualFront = (self.currentPosition == .front)
                DispatchQueue.main.async {
                    self.isFrontCamera = actualFront
                    completion?(actualFront)
                }
                return
            }

            session.addInput(newInput)

            // Configure frame rate, focus, exposure, white balance
            try? newCamera.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: 30)
            if newCamera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameDuration <= frameDuration && frameDuration <= $0.maxFrameDuration
            }) {
                newCamera.activeVideoMinFrameDuration = frameDuration
                newCamera.activeVideoMaxFrameDuration = frameDuration
            }
            if newCamera.isFocusModeSupported(.continuousAutoFocus) {
                newCamera.focusMode = .continuousAutoFocus
            }
            if newCamera.isExposureModeSupported(.continuousAutoExposure) {
                newCamera.exposureMode = .continuousAutoExposure
            }
            if newCamera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                newCamera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            newCamera.unlockForConfiguration()

            if let output = session.outputs.first as? AVCaptureVideoDataOutput,
               let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }

            session.commitConfiguration()

            self.currentCamera = newCamera
            self.currentPosition = targetPosition
            self.isSwitching = false
            let torchAvail = newCamera.hasTorch
            let isFront = (targetPosition == .front)
            DispatchQueue.main.async {
                self.hasTorch = torchAvail
                self.isFrontCamera = isFront
                completion?(isFront)
            }
        }
    }

    // MARK: — Lifecycle

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession, !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    /// Adjusts the exposure target bias (-2.0 … +2.0 EV). No-op if device unavailable.
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let camera = self?.currentCamera else { return }
            try? camera.lockForConfiguration()
            camera.setExposureTargetBias(bias, completionHandler: nil)
            camera.unlockForConfiguration()
        }
    }

    /// Adjusts the camera zoom factor (1.0 ... maxAvailable, clamped to 6.0 max).
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let camera = self?.currentCamera else { return }
            try? camera.lockForConfiguration()
            let maxZoom = min(camera.activeFormat.videoMaxZoomFactor, 6.0)
            let clamped = max(1.0, min(factor, maxZoom))
            camera.videoZoomFactor = clamped
            camera.unlockForConfiguration()
        }
    }

    // MARK: — Tap to Focus & Exposure

    /// Focuses and exposes at view coordinates by mapping to device sensor coordinates.
    func focus(at viewPoint: CGPoint, in viewSize: CGSize) {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.currentCamera, viewSize.width > 0, viewSize.height > 0 else { return }
            let nx = max(0.0, min(1.0, viewPoint.x / viewSize.width))
            let ny = max(0.0, min(1.0, viewPoint.y / viewSize.height))
            let devicePoint = self.isFrontCamera ? CGPoint(x: ny, y: nx) : CGPoint(x: ny, y: 1.0 - nx)

            do {
                try camera.lockForConfiguration()
                if camera.isFocusPointOfInterestSupported && camera.isFocusModeSupported(.autoFocus) {
                    camera.focusPointOfInterest = devicePoint
                    camera.focusMode = .autoFocus
                }
                if camera.isExposurePointOfInterestSupported && camera.isExposureModeSupported(.autoExpose) {
                    camera.exposurePointOfInterest = devicePoint
                    camera.exposureMode = .autoExpose
                }
                camera.unlockForConfiguration()
            } catch {
                // Non-fatal lock failure
            }
        }
    }

    // MARK: — Torch / Flash

    /// Toggles hardware torch on camera asynchronously on sessionQueue. Returns optimistic new torch state.
    @discardableResult
    func toggleTorch() -> Bool {
        guard hasTorch else {
            isTorchOn = false
            return false
        }
        let targetState = !isTorchOn
        isTorchOn = targetState
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.currentCamera, camera.hasTorch else { return }
            do {
                try camera.lockForConfiguration()
                if targetState && camera.isTorchModeSupported(.on) {
                    try camera.setTorchModeOn(level: 1.0)
                } else {
                    camera.torchMode = .off
                }
                camera.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    self.isTorchOn = false
                }
            }
        }
        return targetState
    }

    func setTorch(_ on: Bool) {
        guard hasTorch else {
            isTorchOn = false
            return
        }
        isTorchOn = on
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.currentCamera, camera.hasTorch else { return }
            do {
                try camera.lockForConfiguration()
                if on && camera.isTorchModeSupported(.on) {
                    try camera.setTorchModeOn(level: 1.0)
                } else {
                    camera.torchMode = .off
                }
                camera.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    self.isTorchOn = false
                }
            }
        }
    }

}

// MARK: — AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if isSwitching { return }

        guard
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let cache = textureCache
        else { return }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)

        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else { return }

        textureLock.withLock { _cameraTexture = texture }
    }
}
