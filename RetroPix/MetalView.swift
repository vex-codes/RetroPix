// MetalView.swift
// RetroPix — UIViewRepresentable wrapping MTKView.
// MTKView is configured for continuous 60fps rendering with no auto-clear,
// driven entirely by MetalRenderer.

import MetalKit
import SwiftUI

struct MetalView: UIViewRepresentable {
    let renderer: MetalRenderer
    var isPaused: Bool = false

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate                    = renderer
        view.contentScaleFactor          = 1.0   // 1x scale: avoids 9x Retina fillrate overdraw for retro pixels
        view.preferredFramesPerSecond    = 30
        view.isPaused                    = isPaused
        view.enableSetNeedsDisplay       = false
        view.framebufferOnly             = true   // drawable is render-target only
        view.colorPixelFormat            = .bgra8Unorm
        view.clearColor                  = MTLClearColorMake(0, 0, 0, 1)
        view.backgroundColor             = .black
        view.autoResizeDrawable          = true
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if uiView.isPaused != isPaused {
            uiView.isPaused = isPaused
        }
    }
}
