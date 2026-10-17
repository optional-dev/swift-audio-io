# Getting Started

Make a recording, observe playback, and subscribe to engine events in under thirty lines.

## Add the package

```swift
.package(url: "https://github.com/GoodHatsLLC/swift-audio-io", from: "1.0.0"),
```

Add `AudioIO` as a target dependency:

```swift
.product(name: "AudioIO", package: "swift-audio-io"),
```

## Record, play, observe

```swift
import AudioIO

@MainActor
func runRecording() async throws {
  let engine = AIOEngine()

  // Subscribe to engine events before driving the engine so you don't
  // miss the first lifecycle event after start.
  let subscriber = Task { @MainActor in
    for await event in engine.events {
      switch event {
      case .recordingStarted(let url, let format, let capture):
        print("started \(url.lastPathComponent) in \(format) at \(capture.processing.sampleRate)")
      case .recordingCompleted:
        print("completed cleanly")
      case .recordingFailed:
        print("engine reported a failure")
      case .error(let error):
        print("engine error: \(error.localizedDescription)")
      default:
        break
      }
    }
  }
  defer { subscriber.cancel() }

  // `.hardware` records at whatever rate the route actually runs — the
  // recommended default. See <doc:SampleRates> for why an exact rate is a
  // conversion target on iOS, never a hardware setting.
  let configuration = RecordingConfiguration(
    input: .microphone(
      MicrophoneRecordingInput(format: CaptureFormat(sampleRate: .hardware, channels: .mono)),
    ),
    outputConfiguration: OutputConfiguration(
      fileFormat: .caf,
      bitDepth: .pcmFloat32,
      quality: .maximum,
    ),
  )

  let recordingURL = try await engine.startRecording(configuration: configuration)
  // …record for some duration…
  let savedURL = try await engine.stopRecording().completedURL

  _ = try await engine.play(url: savedURL)
  await engine.stopPlayback()
}
```

## Required reading

The five concept topics describe the package's shape and the contracts you'll bump into:

- <doc:PlatformMatrix> — iOS 27+ and macOS 27+, and what's iOS-only.
- <doc:ThreadingModel> — which APIs are `@MainActor`, which are `nonisolated`, and where the realtime callback runs.
- <doc:ErrorHandling> — typed-throws domain errors and the events stream's `.error(_)` case.
- <doc:Events> — the unified ``AudioIOEvent`` lifecycle stream.
- <doc:SampleRates> — why sample rates are intents on Apple platforms, and how AudioIO resolves them.

When you need depth on a specific API:

- <doc:Recording>
- <doc:Playback>
- <doc:AudioSession>
- <doc:Visualization>

## Topics

### Quick orientation

- <doc:PlatformMatrix>
- <doc:ThreadingModel>
- <doc:ErrorHandling>
- <doc:Events>
