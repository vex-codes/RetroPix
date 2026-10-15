# 📼 RetroPix

> **Authentic Real-Time 8-Bit & Vintage Film Camera Engine for iOS**  
> Powered by Metal compute shaders, dynamic 8×8 Bayer ordered dithering, analog film simulations, procedural color harmonies, and zero-dependency AVFoundation capture.

[![Platform](https://img.shields.io/badge/Platform-iOS%2017.0+-black?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?style=flat-square&logo=swift)](https://swift.org)
[![Metal](https://img.shields.io/badge/Graphics-Metal%203-blue?style=flat-square&logo=apple)](https://developer.apple.com/metal/)
[![Architecture](https://img.shields.io/badge/Architecture-SwiftUI%20%2B%20Metal-00C7B7?style=flat-square)](https://developer.apple.com/metal/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

---

## 🎯 What is RetroPix?

**RetroPix** transforms your modern iPhone sensor into a dedicated analog film and 1990s digital camera.

Unlike typical filters that apply static overlays or color lookup tables (LUTs) onto already processed computational HDR photos, **RetroPix intercepts the camera's raw video stream in real time**. Using custom **Apple Metal GPU compute shaders**, every incoming frame is directly processed at 60 frames per second through:
1. **Bayer 8×8 ordered spatial dithering** and Euclidean distance palette quantization for authentic 8-bit pixel art.
2. **Physics-based analog film simulation** featuring 8-band HSL color remapping, spline tone curves, grain synthesis, halation, and optical vignetting.

What you see in the live viewfinder is exactly what is captured: pure, tactile, quantized visual artifacts with zero post-capture algorithmic smoothing.

```
       [ Modern Camera Sensor ] (1280×720 Raw YUV Feed)
                  │
                  ▼
       [ Metal Compute Shaders ]
       ├── 8×8 Bayer Ordered Spatial Dithering & Palette Quantization
       └── Analog Film Simulation: Tone Curves, Halation, HSL & Grain
                  │
                  ▼
       [ Real-Time Viewfinder ] (Nearest-Neighbor Blit @ 60 FPS)
                  │  (Shutter Pressed / Volume Trigger)
                  ▼
       [ Capture & Composition Engine ]
       ├── CoreMotion Accelerometer Orientation Mapping
       ├── Tap-to-Focus Reticle & EV Bias
       ├── Vintage Photo-Paper Frame & Keyline Brackets
       ├── Chancery Script & Quartz LCD Date Stamps
       └── Authentic Camera EXIF Metadata Injection
                  │
                  ▼
       [ Saved to Camera Roll ] (Uncompressed High-Res Output)
```

---

## ✨ Key Features

### ⚡ 1. Real-Time GPU Metal Compute Pipeline
* **60 FPS Live Viewfinder**: Powered by `MTKView` and dual optimized `MTLComputePipelineState` kernels.
* **8×8 Bayer Ordered Dithering**: Classic spatial crosshatch distribution derived from historical ordered dither matrices (`bayer8[64]`).
* **Adjustable Dither Spread**: Cycle through `OFF`, `50%`, `75%`, and `100%` dither intensities directly from the control deck.
* **Nearest-Neighbor Rendering**: Strict zero-interpolation sampling (`filter::linear` for downscale, `.none` for upscale) preserves hard pixel boundaries with no anti-aliasing blur.

### 🎞️ 2. Analog Film & Digicam Simulation Profiles
* **Curated Legendary Camera Presets**:
  * **Fujichrome Velvia 50**: High-saturation reversal slide film with vivid greens and deep blues.
  * **Ricoh GR High-Contrast B&W**: Hard-edge monochrome street photography tone curve.
  * **Olympus Stylus Epic [mju:]-II**: Sharp 35mm point-and-shoot snapshot aesthetic with rich flash falloff.
  * **Fujicolor Superia X-TRA 400**: Everyday analog 35mm film stock with signature color rendering.
  * **Dazz CPM35**: Disposable single-element plastic lens character.
  * **Polaroid 600**: Classic instant photo color temperature and contrast dynamics.
  * **Contax T2 Titanium**: Premium compact camera rendering with Carl Zeiss Sonnar contrast.
  * **Sony Digital Mavica**: Iconic late-90s floppy-disk CCD digicam look.
* **Emulsion & Optical Flaws**: Real-time procedural grain synthesis, halation bloom, optical vignetting, and chromatic aberration.

### 🎨 3. Palette Studio & Color Harmony Engine
* **Iconic 8-Bit Palettes**:
  * `ORIGINAL_GB`: Classic 4-color Game Boy DMG-01 olive monochrome.
  * `7MDNIGHT`: High-contrast 8-color Synthwave purple-and-cyan palette.
  * `8AMMO`: Military olive drab, ammo casing tan, and field shadow tones.
  * `8ANCIENT`: Terracotta, parchment, and aged stone hues.
  * `8AUTUMN`: Crimson, amber, and gold fall foliage.
  * `8BRKFST`: Warm espresso, toast, and cream breakfast palette.
  * `8DREAM`: Dreamwave cosmic violets and icy pastels.
  * `DEFAULT`: 4-color balanced grayscale.
* **Built-in Palette Studio**: In-app brutalist editor to inspect, customize, rename, and craft 4-to-8 color palettes.
* **Rec. 709 Luminance Sorting**: Automatic relative luminance sort (`0.2126R + 0.7152G + 0.0722B`) ensures seamless dark-to-light dithering gradations.
* **Procedural Color Harmonies**: Algorithmic generation based on classical color theory (Monochromatic, Analogous, Complementary, Split-Complementary, Triadic).

### 📅 4. Authentic Date & Time Stamp
* **Vintage Typography**:
  * **Chancery Script**: Elegant cursive film date overlay rendered using bundled `Apple Chancery` typography.
  * **'90s Quartz LCD**: Amber or green terminal phosphor glow with drop shadow (`'yy MM dd  HH:mm`).
  * **Off**: Clean output without timestamp.
* **Orientation-Aware**: Automatically repositions and rotates with device orientation to guarantee correct placement on every capture.

### 📷 5. Hardware Controls & Composition Tools
* **Tap-to-Focus**: Interactive touch-to-focus reticle with real-time lens adjustment.
* **Hardware Volume Shutter**: Capture photos using physical iPhone volume buttons (`Volume Up` / `Volume Down`).
* **Dual Flash Modes**: Physical torch on rear camera and warm-white **Retina Screen Flash** with display brightness boost on front camera.
* **Composition Grids**: Toggleable Rule of Thirds crosshairs and Golden Spiral overlay.
* **Exposure Value (EV) Stepper**: On-the-fly EV compensation from `-2.0 EV` to `+2.0 EV` in `0.5 EV` increments.
* **Pinch-to-Zoom**: Hardware zoom scaling from `1.0×` to `6.0×`.
* **Hardware Accelerometer Tracking**: Uses `CoreMotion` accelerometer to detect true physical device rotation, keeping HUD indicators upright even with system portrait lock enabled.
* **Selectable Aspect Ratios**:
  * `4:3` (180 × 240) — Classic CRT & digicam proportion.
  * `1:1` (192 × 192) — Square profile.
  * `2:1` (128 × 256) — Retro banner.
  * `16:9` (144 × 256) — Full widescreen.

### 🖼️ 6. Vintage Frames & EXIF Injection
* **Vintage Borders**: Warm photo-paper margins (`#F5F2EA`) and technical corner registration ticks.
* **Authentic EXIF Metadata**: Automatically tags captured photos with accurate vintage camera metadata (Make, Model, Lens Model, ISO, Exposure Time, F-Number, Software tag).

### ⏱️ 7. Self-Timer, Audio & Haptics
* **Self-Timer**: Selectable `OFF`, `3 SEC`, or `10 SEC` timer with blinking viewfinder countdown OSD.
* **Acoustics & Synthesis**:
  * Authentic mechanical camera shutter audio samples dispatched to a background queue.
  * In-memory procedural PCM sine synthesizer for self-timer rhythm cadence (1200 Hz standard, 2400 Hz urgent).
  * Tactile haptic feedback triggers on shutter release and timer ticks.

---

## 🏗️ Architecture & Project Structure

```
RetroPix/
├── App & State
│   ├── RetroPixApp.swift               # App entry point
│   ├── CameraViewModel.swift           # Central @Observable reactive state hub
│   └── DeviceOrientationObserver.swift  # CoreMotion accelerometer tracking
│
├── Camera & Capture Pipeline
│   ├── CameraManager.swift             # AVFoundation session & pixel buffer delivery
│   ├── CaptureService.swift            # 8× nearest upscale, EXIF injection & photo save
│   └── AspectRatios.swift              # Ratio UV coordinates & resolution mappings
│
├── Metal GPU Engine
│   ├── PixelShader.metal               # Bayer 8×8 dither compute kernel & blit shader
│   ├── AestheticShader.metal           # Film simulation, tone curves & grain kernel
│   ├── MetalRenderer.swift             # MTKViewDelegate render loop & uniform buffers
│   └── MetalView.swift                 # SwiftUI wrapper for MTKView
│
├── Film & Palette Systems
│   ├── AestheticProfile.swift          # Digicam & analog film simulation profiles
│   ├── Palettes.swift                  # 8-bit palette models, themes & persistence
│   ├── HarmonicPaletteGenerator.swift  # Procedural HSL color harmony generator
│   └── CustomPaletteEditorView.swift   # In-app Palette Studio
│
├── UI & Audio
│   ├── ContentView.swift               # Main camera viewfinder, HUD overlays & audio
│   ├── CameraSettingsView.swift        # Industrial configuration sheet
│   └── RetroUIComponents.swift         # Brutalist buttons, dials, badges & theme tokens
│
└── Assets & Resources
    ├── Apple Chancery.ttf              # Vintage film date stamp typography
    ├── Assets.xcassets                 # App icon & accent colors
    ├── shutter_1.mp3 / shutter_2.mp3   # Authentic mechanical camera shutter acoustics
    └── PrivacyInfo.xcprivacy           # Apple App Store privacy manifest
```

---

## 🛠️ Build & Installation

### Requirements
* **macOS**: Sonoma 14.0 or newer
* **Xcode**: 15.0 or newer (tested with Xcode 16)
* **Device**: Physical iPhone running **iOS 17.0+** (Camera and Metal compute require physical hardware; iOS Simulator does not provide live camera feed)
* **Signing**: Apple Developer account or Personal Team provisioning profile

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

4. **Deploy to Device**:
   * Connect your iPhone via USB or Wi-Fi.
   * Select your device in the Xcode run destination dropdown.
   * Press `Cmd + R` to build and run.

---

## 🔒 Permissions & Privacy

RetroPix is built with zero tracking and full on-device privacy:

* **Camera (`NSCameraUsageDescription`)**: Required strictly to display the live viewfinder and capture photos.
* **Photo Library (`NSPhotoLibraryAddUsageDescription`)**: Requests **Add Only** permission to save captured photos directly to your Photos app.
* **Zero Telemetry**: No third-party analytics, no tracking SDKs, and no network requests.
* **100% On-Device**: All Metal rendering, procedural synthesis, and palette storage execute strictly on-device.
* **Privacy Manifest**: Includes `PrivacyInfo.xcprivacy` compliant with Apple App Store submission standards.

---

## 📄 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for complete details.

---

<p align="center">
  Crafted with 🖤 for the love of 8-bit digital artifacts, analog constraints, and tactile photography.
</p>
