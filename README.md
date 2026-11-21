# LaptopVR

Use your Mac in VR with an iPhone and a Cardboard-style viewer. The Mac streams its screen to the phone, which shows it as a large virtual display that stays put as you turn your head.

## Features

- **Low latency:** ScreenCaptureKit capture, hardware H.264 or HEVC, and a Metal stereo renderer at up to 120 fps.
- **USB or Wi-Fi:** the cable is used when the iPhone is plugged in, Wi-Fi otherwise.
- **Extra monitors:** add up to four virtual displays that macOS treats as real ones.
- **View modes:** Anchored keeps the screens fixed in space; Follow brings them along when you look away. Cinema shows one screen in a dark room.
- **Surroundings:** a colour, a gradient, your own image, or the iPhone camera as passthrough.
- **Recording and screenshots:** save what you see in the headset as a flat video or picture on the Mac, showing every screen and where you are looking.
- **Privacy screen:** covers the Mac's display, or turns its backlight off, while you work in the headset.
- **Viewer setup:** scan your viewer's Cardboard QR code, or pick a preset.

## Requirements

- macOS 26 and iOS 26 or later
- Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A Cardboard-compatible viewer

## Build and run

1. Set `DEVELOPMENT_TEAM` in `project.yml` to your own team and run `xcodegen generate`.
2. Open `LaptopVR.xcodeproj`, then run `LaptopVR-Mac` on the Mac and `LaptopVR-iOS` on the iPhone.
3. Connect the iPhone with a cable, or put both devices on the same Wi-Fi network.
4. Tap Enter Headset on the iPhone, or choose Start in the Mac's menu bar. macOS asks for Screen Recording permission the first time.

The project is generated from `project.yml`, so run `xcodegen generate` again after adding or removing files.

## Shortcuts

All use ⌃⌥⌘ and can be changed in Settings.

| Key | Action |
| --- | --- |
| V | Start or stop |
| Space | Recenter |
| = and - | Zoom in and out |
| M | Anchored or Follow |
| P | Passthrough |
| C | Cinema |
| R | Show or hide the Mac's own screen |
| ← and → | Look at the previous or next display |
| N and ⌫ | Add or remove a monitor |
| S | Stats |
| 5 | Start or stop recording the view |
| 3 | Screenshot of the view |

## Notes

Extra monitors use a private macOS API (`CGVirtualDisplay`), so the Mac app cannot be distributed on the Mac App Store.

## About

LaptopVR began as a project for Cal Hacks 8.0. The submission is on [Devpost](https://devpost.com/software/laptopvr).
