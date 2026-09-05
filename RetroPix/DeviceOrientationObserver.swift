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

    init() {
        start()
    }

    func start() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.15
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let x = data.acceleration.x
            let y = data.acceleration.y

            let newOrientation: DeviceOrientation
            if abs(x) > abs(y) {
                if x < -0.45 {
                    newOrientation = .landscapeLeft   // Rotated 90° CCW (charging port on right)
                } else if x > 0.45 {
                    newOrientation = .landscapeRight  // Rotated 90° CW (charging port on left)
                } else {
                    return
                }
            } else {
                if y < -0.45 {
                    newOrientation = .portrait        // Normal upright
                } else if y > 0.45 {
                    newOrientation = .portraitUpsideDown
                } else {
                    return
                }
            }

            if newOrientation != self.orientation {
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

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
