// CameraManager.swift
// RetroPix — AVFoundation capture pipeline.
//
// Captures at 720p (16:9) on the back wide camera, uploads each frame to a
// Metal texture via CVMetalTextureCache (zero-copy). Thread-safe texture access
// via NSLock since the delegate callback fires on a private queue.

import AVFoundation
import Metal

final class CameraManager: NSObject, @unchecked Sendable {

    // MARK: — State

    private var captureSession: AVCaptureSession?
    private var textureCache: CVMetalTextureCache?
    private var currentCamera: AVCaptureDevice?   // retained for EV bias updates

    private(set) var cameraPosition: AVCaptureDevice.Position = .back
    private(set) var isTorchOn: Bool = false

    var isFrontFacing: Bool { cameraPosition == .front }
    var hasTorch: Bool { currentCamera?.hasTorch ?? false }

    private let textureLock = NSLock()
    private var _cameraTexture: MTLTexture?

    /// Latest camera frame as a Metal texture. Safe to read from any thread.
    var cameraTexture: MTLTexture? {
        textureLock.withLock { _cameraTexture }
    }

    private let sessionQueue = DispatchQueue(label: "retropix.camera.session", qos: .userInteractive)

    // MARK: — Setup

    func setup(device: MTLDevice) {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        requestPermissionAndStart()
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
            session.sessionPreset = .hd1280x720  // 16:9 — compute shader crops to 2:1 center

            // --- Input ---
            guard
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.cameraPosition),
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

    // MARK: — Camera Flip & Torch

    /// Flips between back and front cameras asynchronously.
    func flipCamera(completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.captureSession else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            let newPosition: AVCaptureDevice.Position = (self.cameraPosition == .back) ? .front : .back
            guard
                let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                let newInput = try? AVCaptureDeviceInput(device: newCamera)
            else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            // Turn off torch if active
            if self.isTorchOn {
                self.setTorch(false)
            }

            session.beginConfiguration()

            // Remove existing inputs
            for input in session.inputs {
                session.removeInput(input)
            }

            if session.canAddInput(newInput) {
                session.addInput(newInput)
                self.cameraPosition = newPosition
                self.currentCamera = newCamera

                // Minimal processing — continuous AF/AE, 30 FPS cap
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
            }

            // Sensor native 0°
            if let output = session.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
               let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }

            session.commitConfiguration()
            let isFront = (self.cameraPosition == .front)
            DispatchQueue.main.async { completion?(isFront) }
        }
    }

    /// Toggles hardware torch on back camera. Returns new torch state.
    @discardableResult
    func toggleTorch() -> Bool {
        guard cameraPosition == .back, let camera = currentCamera, camera.hasTorch else {
            isTorchOn = false
            return false
        }

        do {
            try camera.lockForConfiguration()
            if isTorchOn {
                camera.torchMode = .off
                isTorchOn = false
            } else {
                if camera.isTorchModeSupported(.on) {
                    try camera.setTorchModeOn(level: 1.0)
                    isTorchOn = true
                }
            }
            camera.unlockForConfiguration()
            return isTorchOn
        } catch {
            return false
        }
    }

    func setTorch(_ on: Bool) {
        guard cameraPosition == .back, let camera = currentCamera, camera.hasTorch else {
            isTorchOn = false
            return
        }
        try? camera.lockForConfiguration()
        if on && camera.isTorchModeSupported(.on) {
            try? camera.setTorchModeOn(level: 1.0)
            isTorchOn = true
        } else {
            camera.torchMode = .off
            isTorchOn = false
        }
        camera.unlockForConfiguration()
    }

}

// MARK: — AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
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
