# 📼 RetroPix

> **Authentic Real-Time 8-Bit & Retro Digital Camera Engine for iOS**  
> Powered by Metal compute shaders, dynamic 8×8 Bayer ordered dithering, procedural color harmonies, and zero-dependency low-level AVFoundation capture.

[![Platform](https://img.shields.io/badge/Platform-iOS%2017.0+-black?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?style=flat-square&logo=swift)](https://swift.org)
[![Metal](https://img.shields.io/badge/Graphics-Metal%203-blue?style=flat-square&logo=apple)](https://developer.apple.com/metal/)
[![Architecture](https://img.shields.io/badge/Architecture-SwiftUI%20%2B%20Metal-00C7B7?style=flat-square)](https://developer.apple.com/metal/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](#license)

---

## 🎯 What is RetroPix?

**RetroPix** transforms your modern iPhone sensor into a dedicated 1990s hardware camera.

Unlike typical social media filters that overlay static blur or color lookup tables (LUTs) onto an already-processed computational HDR photo, **RetroPix intercepts the camera's raw video stream in real-time**. Using custom **Apple Metal GPU compute shaders**, every incoming frame is directly quantized against a custom color palette using **Bayer 8×8 ordered spatial dithering** at 60 frames per second.

What you see in the live viewfinder is exactly what is captured: pure, hard-edged, quantized pixel art with zero post-capture smoothing.

```
       [ Modern Camera Sensor ] (1280×720 Raw YUV Feed)
                  │
                  ▼
       [ Metal Compute Shader ]
       ├── Aspect Crop & Coordinate Transform
       ├── 8×8 Bayer Ordered Spatial Dithering
       └── Euclidean Distance Palette Quantization
                  │
                  ▼
       [ Real-Time Viewfinder ] (Nearest-Neighbor Blit @ 60 FPS)
                  │  (Shutter Pressed)
                  ▼
       [ Capture & Composition Engine ]
       ├── Accelerometer Physical Device Orientation Mapping
       ├── 8× Nearest-Neighbor Upscale (Zero Interpolation)
       ├── Vintage Physical Photo-Paper Frame & Keyline Brackets
       └── '90s Quartz Date/Time Stamp (Orange/Green LCD Font)
                  │
                  ▼
       [ Saved to Photos ] (Crisp Uncompressed Pixel Art)
```

---

## ✨ Key Features

### ⚡ 1. Real-Time GPU Metal Compute Pipeline
* **60 FPS Live Viewfinder**: Powered by `MTKView` and a customized `MTLComputePipelineState`.
* **8×8 Bayer Ordered Dithering**: Classic spatial crosshatch distribution derived from historical ordered dither matrices (`bayer8[64]`).
* **Hardware Dither Intensity**: Seamlessly cycle between `OFF`, `50%`, `75%`, and `100%` dither spread directly from the control deck or settings slider.
* **Nearest-Neighbor Rendering**: Strict zero-interpolation sampling (`filter::linear` for downscale, `.none` for upscale) preserves hard pixel boundaries with no anti-aliasing blur.

### 🎨 2. Palette Studio & Color Harmony Engine
* **Iconic Curated Palettes**:
  * `ORIGINAL_GB`: Classic 4-color Game Boy DMG-01 olive monochrome.
  * `7MDNIGHT`: High-contrast 8-color Synthwave purple-and-cyan palette.
  * `8AMMO`: Military olive drab, ammo casing tan, and field shadow tones.
  * `8ANCIENT`: Terracotta, parchment, and aged stone hues.
  * `8AUTUMN`: Crimson, amber, and gold fall foliage.
  * `8BRKFST`: Warm espresso, toast, and cream breakfast palette.
  * `8DREAM`: Dreamwave cosmic violets and icy pastels.
  * `DEFAULT`: 4-color balanced grayscale.
* **Palette Studio**: Dedicated brutalist editor to inspect, customize, rename, and craft 4-to-8 color palettes.
* **Luminance Sorting**: Automatic Rec. 709 relative luminance sort (`0.2126R + 0.7152G + 0.0722B`) ensures seamless dark-to-light dithering gradations.
* **Procedural Color Harmony Generator**: Algorithmic generation based on classical color theory:
  * Monochromatic
  * Analogous
  * Complementary
  * Split-Complementary
  * Triadic

### 📅 3. '90s Quartz Date & Time Stamp
* **Vintage LCD Aesthetic**: Modeled after late-90s compact film and digicam quartz date backs (`'yy MM dd  HH:mm`).
* **Selectable Phosphors**:
  * **Orange ('98)**: Authentic amber quartz glow with drop shadow.
  * **Green ('98)**: Classic retro terminal phosphor green.
  * **Off**: Clean output without timestamp.
* Embedded directly into the final image canvas with high-resolution monospaced digital typography.

### 🖼️ 4. Vintage Frame Borders
* **Warm Photo-Paper Margin**: Subtle off-white matte border (`#F5F2EA`) wrapping the pixel art.
* **Technical Corner Brackets**: Dark slate hairline keyline with four corner registration ticks, mimicking vintage exposure masks.
* **Smart Orientation Handling**: Border geometry, inner photo viewport, and date stamps automatically rotate to match physical landscape or portrait holding orientation.

### ⏱️ 5. Self-Timer & Procedural 8-Bit Audio
* **Timer Intervals**: Selectable `OFF`, `3 SEC`, or `10 SEC` self-timer.
* **Retro Countdown OSD**: High-visibility blinking phosphor countdown overlay centered in the viewfinder.
* **Zero-Asset Audio Synthesis**: 100% procedural PCM audio generation in memory—no bundled `.wav` or `.mp3` assets:
  * **1200 Hz Square/Sine Tone**: Standard rhythm cadence beep.
  * **2400 Hz Urgent Tone**: High-pitch rapid alert during the final countdown second.
  * **Mechanical Shutter Sound**: Algorithmic transient click paired with rigid haptic engine triggers.

### 🎛️ 6. Tactile Industrial Camera Deck
* **Hardware Flash / Torch Control**: Instant toggle for low-light pixelation.
* **Exposure Value (EV) Stepper**: On-the-fly EV compensation from `-2.0 EV` to `+2.0 EV` in `0.5 EV` increments.
* **Pinch-to-Zoom**: Smooth hardware zoom scaling from `1.0×` to `6.0×`.
* **Hardware Accelerometer Tracking**: Uses `CMMotionManager` to detect true physical device rotation, allowing UI icons to rotate gracefully even when system portrait-orientation lock is enabled.
* **Selectable Aspect Ratios**:
  * `4:3` (180 × 240) — Classic CRT & digicam proportion.
  * `1:1` (192 × 192) — Square profile.
  * `2:1` (128 × 256) — Narrow retro banner.
  * `16:9` (144 × 256) — Full widescreen.

---

## 🏗️ Architecture & Technical Implementation

```
RetroPix/
├── App & State
│   ├── RetroPixApp.swift              # App entry point
│   ├── CameraViewModel.swift          # Central @Observable reactive state hub
│   └── DeviceOrientationObserver.swift # CoreMotion accelerometer tracking
│
├── Camera & Capture Pipeline
│   ├── CameraManager.swift            # AVFoundation session & pixel buffer delivery
│   ├── CaptureService.swift           # Readback, 8× nearest upscale, stamps & save
│   └── AspectRatios.swift             # Ratio UV coordinates & resolution mappings
│
├── Metal GPU Engine
│   ├── PixelShader.metal              # Bayer 8×8 dither compute kernel & blit shader
│   ├── MetalRenderer.swift            # MTKViewDelegate render loop & uniform buffers
│   └── MetalView.swift                # SwiftUI wrapper for MTKView
│
├── Palettes & Color Theory
│   ├── Palettes.swift                 # Palette models, built-in themes & persistence
│   ├── HarmonicPaletteGenerator.swift # Procedural HSL color harmony generator
│   └── CustomPaletteEditorView.swift  # In-app Palette Studio
│
└── UI & Audio
    ├── ContentView.swift              # Main camera shell & procedural audio service
    ├── CameraSettingsView.swift       # 90s-industrial configuration sheet
    └── RetroUIComponents.swift        # Brutalist buttons, dials, badges & theme tokens
```

### 1. Metal Dithering Compute Kernel (`PixelShader.metal`)

The core engine maps incoming camera frames into retro pixel art in a single compute pass:

1. **UV Coordinate Remapping**: Normalizes coordinates and samples the raw camera texture with edge clamping.
2. **Bayer Spatial Thresholding**: Computes a continuous spatial threshold $[-0.5, +0.5]$ using an unrolled 64-element matrix:
   $$\text{threshold} = \frac{\text{bayer8}[(y \pmod 8) \times 8 + (x \pmod 8)]}{63.0} - 0.5$$
3. **RGB Channel Dithering**: Offsets the input color by the threshold scaled by `ditherSpread`:
   $$\vec{C}_{\text{dithered}} = \text{clamp}(\vec{C}_{\text{input}} + \text{threshold} \times S_{\text{dither}}, 0.0, 1.0)$$
4. **Euclidean Color Quantization**: Computes squared Euclidean distance in RGB color space against all active palette colors:
   $$\text{dist}^2 = (\vec{C}_{\text{dithered}} - \vec{P}_i) \cdot (\vec{C}_{\text{dithered}} - \vec{P}_i)$$
   Writes the closest color $\vec{P}_{\text{best}}$ directly into the shared pixel texture.

### 2. Zero-Copy Capture & Upscaling (`CaptureService.swift`)

When the shutter triggers:
1. The CPU reads back the active low-resolution texture directly from Metal shared memory via `getBytes`.
2. A `CGContext` is initialized at **8× the native rendering resolution** with:
   ```swift
   ctx.interpolationQuality = .none // Critical: prevents edge blur / interpolation
   ```
3. The accelerometer's physical angle is applied via coordinate translation and rotation.
4. Optional frame borders and vector registration corner marks are stroked.
5. The '90s quartz date stamp is drawn using CoreGraphics with heavy monospaced digital typography and shadow blur.
6. The resulting `CGImage` is committed to the user's Camera Roll via `PHPhotoLibrary`.

### 3. Procedural Audio Engine (`ShutterAudioService`)

To eliminate bundled audio file dependencies and guarantee zero latency:
* Constructs complete in-memory **RIFF/WAVE** binary buffers on startup.
* Generates pure sine tones with linear attack and decay envelopes:
  ```swift
  let attack = min(1.0, t / 0.005)
  let decay = min(1.0, (duration - t) / 0.005)
  let envelope = attack * decay
  let sample = sin(2.0 * .pi * freq * t) * envelope * 0.75
  ```
* Initialized in `AVAudioPlayer` with zero disk I/O, accompanied by `AudioServicesPlaySystemSound(1108)` for mechanical tactile feedback.

---

## 🛠️ Build & Installation

### Requirements
* **macOS**: Sonoma 14.0 or newer
* **Xcode**: 15.0 or newer
* **Device**: Physical iPhone running **iOS 17.0+** (Camera and Metal compute require physical hardware; simulator does not provide live camera feed)
* **Signing**: Active Apple Developer account or Personal Team provisioning profile

### Setup Instructions

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-username/RetroPix.git
   cd RetroPix
   ```

2. **Open the project in Xcode**:
   ```bash
   open RetroPix.xcodeproj
   ```

3. **Configure Code Signing**:
   * Select the **RetroPix** target in the Xcode project navigator.
   * Under **Signing & Capabilities**, select your **Development Team**.
   * Update the **Bundle Identifier** if necessary.

4. **Run on Physical Device**:
   * Connect your iPhone via USB or Wi-Fi.
   * Select your device in the Xcode scheme target dropdown.
   * Press `Cmd + R` to build and deploy.

---

## 🔒 Permissions & Privacy

RetroPix is built with an uncompromising commitment to privacy:

* **Camera Permission (`NSCameraUsageDescription`)**: Required strictly to display the live viewfinder and capture photos.
* **Photo Library Access (`NSPhotoLibraryAddUsageDescription`)**: Requests **Add Only** permission to save captured pixel art directly to your Photos app.
* **Zero Telemetry**: No analytics, no tracking SDKs, no external network requests, and no third-party dependencies.
* **Local Processing**: 100% of image rendering, audio synthesis, and palette storage occurs strictly on-device.

---

## 📄 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for complete details.

---

<p align="center">
  Crafted with 🖤 for the love of 8-bit digital artifacts and analog constraints.
</p>
