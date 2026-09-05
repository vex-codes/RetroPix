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
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            // Minimal processing — continuous AF/AE, no torch, no smoothing
            try? camera.lockForConfiguration()
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
