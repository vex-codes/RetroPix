// DeviceOrientationObserver.swift
// RetroPix — Accelerometer-based device orientation tracking for camera UI rotation.

import CoreMotion
import SwiftUI

enum DeviceOrientation: Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case portraitUpsideDown
}

@Observable
final class DeviceOrientationObserver {
    var orientation: DeviceOrientation = .portrait
    var uiRotationAngle: Double = 0.0

    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "retropix.accelerometer.queue"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()

    init() {}

    func start() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            let x = data.acceleration.x
            let y = data.acceleration.y
            let z = data.acceleration.z

            // Ignore orientation changes when device is laying flat
            if abs(z) > 0.80 { return }

            let newOrientation: DeviceOrientation
            // Decisive threshold (>0.72g along X and >1.6x Y) ensures orientation only flips in full landscape
            if abs(x) > 0.72 && abs(x) > 1.6 * abs(y) {
                if x < -0.72 {
                    newOrientation = .landscapeLeft   // Rotated 90° CCW (charging port on right)
                } else {
                    newOrientation = .landscapeRight  // Rotated 90° CW (charging port on left)
                }
            } else if y < -0.50 && abs(y) > 1.2 * abs(x) {
                newOrientation = .portrait        // Normal upright
            } else if y > 0.70 && abs(y) > 1.6 * abs(x) {
                newOrientation = .portraitUpsideDown
            } else {
                return  // Deadband zone: maintain current orientation
            }

            if newOrientation != self.orientation {
                DispatchQueue.main.async { [weak self] in
                    guard let self, newOrientation != self.orientation else { return }
                    self.orientation = newOrientation
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        switch newOrientation {
                        case .portrait:
                            self.uiRotationAngle = 0
                        case .landscapeLeft:
                            self.uiRotationAngle = 90
                        case .landscapeRight:
                            self.uiRotationAngle = -90
                        case .portraitUpsideDown:
                            self.uiRotationAngle = 180
                        }
                    }
                }
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
