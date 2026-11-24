# AirSlide

AirDrop-style file sharing between a Mac and an iPhone. Drag a file toward any screen edge and it slides in from the opposite edge of the other device.

- `Mac/` macOS receiver and edge portal (macOS 15+)
- `iOS/` iPhone app (iOS 18+)
- `Shared/` wire protocol, encrypted transport, sessions, shared UI
- `project.yml` XcodeGen spec. Run `xcodegen generate` to rebuild `AirSlide.xcodeproj`.

Set your own `DEVELOPMENT_TEAM` in `project.yml` before running on a device.
Pairing: open the iPhone app, tap your Mac, confirm the 4-digit code on the Mac (or scan the QR fallback).
