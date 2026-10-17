# AudioIODemo

A minimum-viable sample app for the AudioIO Swift package. One screen, one record button, one waveform, one play button. iOS + macOS from a single SwiftUI codebase.

Requires Xcode 27 / Swift 6.4 and iOS 27 or macOS 27.

## What it demonstrates

- **The unified events stream** — `AudioIODemoViewModel.init` subscribes to `engine.events` *before* the caller can drive the engine. This is load-bearing: `AsyncBroadcaster` does not replay events for late subscribers.
- **Typed-throws recording** — `engine.startRecording(configuration:)` and `engine.stopRecording()` as the canonical entry points. No reconciliation-mode SPI, no manual reconciliation timer.
- **Token-scoped buffer receivers** — `engine.attachBufferReceiver(visualization)` attaches the visualization engine to the realtime tap. The returned `BufferReceiverToken` is invalidated on cleanup.
- **Subscriber-demand visualization** — `visualization.subscribe(request:)` declares what work is needed (`LODWork`); the engine only computes work that at least one subscriber requested.
- **Frame-scoped zero-copy LOD reads** — `WaveformView` uses `visualization.withCurrentLODSnapshotRef { ... }` inside a `TimelineView` so each draw reads the most-recent snapshot without allocation.
- **Microphone permission across iOS and macOS** — `PermissionGate.swift` handles both `AVAudioApplication.requestRecordPermission` (iOS) and `AVCaptureDevice.requestAccess(for: .audio)` (macOS).
- **System-audio capture (macOS)** — a `Source` picker switches between the microphone and a Core Audio process tap. `SystemAudioControls.swift` drives the public process-discovery API (`SystemAudioProcessCatalog.capturableProcesses()`) and builds a `RecordingConfiguration` with a `.systemAudio` input — either a global tap that excludes the demo itself, or an include-only mixdown of selected apps. The same `startRecording`/`stopRecording`, waveform, and playback path is reused; only the configuration's `input` differs.

## What it intentionally does NOT demonstrate

- Recording-list persistence, audio-session category negotiation, segmented recording, frequency-domain analysis, beat detection. The library supports all of these; the sample stays small so the canonical idioms are easy to read.

## Run it

```bash
cd Examples/AudioIODemo
xcodegen generate
open AudioIODemo.xcodeproj
```

Or from the command line:

```bash
xcodebuild build -project AudioIODemo.xcodeproj -scheme AudioIODemo -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'
xcodebuild build -project AudioIODemo.xcodeproj -scheme AudioIODemo -destination 'platform=macOS'
```

The Xcode project is generated from `project.yml`; it is gitignored, regenerate after pulling.

## Verifying system-audio capture (macOS)

System audio uses a Core Audio process tap and is **macOS only**. It is the
hands-on way to verify the `.systemAudio` recording path end to end.

1. Build and run on macOS (run from Xcode, or `open` the generated project — the
   app must launch as a real macOS app, not a simulator).
2. Pick **System Audio** in the Source picker.
3. Leave the mode on **All system audio (exclude this app)**, or choose **Only
   the selected apps** and check one or more apps from the discovered list
   (click **Refresh** if the list is empty — a process appears once it has
   produced audio).
4. Play audio in another app (a browser tab, Music, etc.).
5. Press **Record**. The first capture triggers the macOS audio-recording
   permission prompt (backed by `NSAudioCaptureUsageDescription`) — approve it.
   The waveform should move with the captured system audio.
6. Press **Stop**, then **Play** to hear the recording, and **Show** to reveal
   the file in Finder and confirm it is non-empty.

What to confirm during validation:

- The permission prompt is the **audio-recording** prompt, not ScreenCaptureKit.
- The demo never records its own output (self-exclusion prevents a feedback loop).
- After stopping, no leftover private aggregate devices/taps remain (check
  *Audio MIDI Setup*; the private aggregate device should be gone).
- The output file plays back and is non-empty.

The microphone source does not require any of this — it uses the standard
microphone permission and is available on iOS and macOS.

## Code signing

The sample is configured for ad-hoc "Sign to Run Locally" signing so it builds without a development team. To distribute the sample, override `CODE_SIGN_STYLE` and set `DEVELOPMENT_TEAM` in `project.yml` (or in the Xcode UI after generation).

## File map

| File | Lines | Role |
|---|---|---|
| `AudioIODemoApp.swift` | ~30 | `@main` App scene. |
| `ContentView.swift` | ~140 | The whole UI: source picker, waveform, controls, status. |
| `AudioIODemoViewModel.swift` | ~280 | `@Observable @MainActor` engine adapter; source selection + system-audio config + process discovery; subscribes to `events`. |
| `SystemAudioControls.swift` | ~80 | macOS system-audio mode + process-selection UI (process discovery API). |
| `WaveformView.swift` | ~50 | `TimelineView` + `Canvas` reading the multi-band LOD snapshot. |
| `PermissionGate.swift` | ~50 | iOS / macOS microphone permission. |
| `project.yml` | ~65 | XcodeGen manifest (incl. `NSAudioCaptureUsageDescription` on macOS). |
