# Roadmap

This document describes the current state of AudioIO and what we expect to work on next. Dates are deliberately omitted — order is meaningful, calendar weeks are not.

## Current state

AudioIO 1.0 requires Swift 6.4, Xcode 27, and iOS 27 or macOS 27.
The release removes pre-27 platform paths and uses cancellation shields for
recording drain, session release, and other mandatory asynchronous cleanup.
Public APIs follow SemVer starting with 1.0.0.

## Milestones

### M1 — Surface narrowing (complete)

Goal: reduce the public API to a single curated module.

- [x] Rename `AIOEngine` → `AudioIO`. Single public product.
- [x] Replace `@_exported import` re-exports with explicit `public import` / typealias facade where the import-visibility rules permit (3 modules moved to `public import`, 5 retained `@_exported` because consumers call instance methods / static members that `MemberImportVisibility` can't reach through a typealias).
- [x] Audit every `public` symbol; the curated `Exports.swift` typealias list is the canonical surface fixture.
- [x] Strip `import SwiftUI` and `import Combine` from the entire library, enforced by `bin/check-no-swiftui-combine-in-aio.sh`.
- [x] Add `Tests/AIOTests/PublicAPISnapshot.swift` as the API-stability fixture (6 `@Test` functions, one per source module).

Completed during the 0.x release series.

Not done in M1 (deferred / out of scope):
- Absorbing `Tools` and `AudioSignals` as `@_spi(Internal)` / `@_spi(Visualization)` SPIs — both remain as separate public products. The narrowing argument turned out weaker than expected: `AudioSignals` is independently useful to consumers building waveform UI without the recording stack, and `Tools` already exposes only typed-throws / async primitives that AudioIO itself depends on transitively.

### M2 — API ergonomics (complete)

Goal: one obvious way to do each thing.

- [x] **M2.5** — Replace `SampleRate.Common.sr44100`-style enum API with `ExpressibleByIntegerLiteral` + named statics (`.cd`, `.dvd`, `.hiRes96`, `.hiRes192`) and a `static let common: [SampleRate]` array for UI selectors.
- [x] **M2.4** — Replace dual `avAudio` / `platform` accessors on input types with `@_spi(AVFoundation)` escape hatches. Same gating on AV-taking initializers and the `EncodingQuality.avAudio` bridge.
- [x] **M2.2** — Split `AIOError` into per-domain enums (`RecordingError`, `PlaybackError`, `SessionError`) under the `AudioIOError` marker protocol. Cross-domain wrapping via `.session(_:)` cases.
- [x] **M2.3** — Use one canonical `startRecording(configuration:) async throws(RecordingError) -> URL`; it owns bounded readiness retry, while callers own intent through the awaiting task. Remove the former desired-state/reconciliation and public partial-warm entry points.
- [x] **M2.1** — Replace `errors: AsyncBroadcaster<any Error>` with the typed `events: AsyncBroadcaster<AudioIOEvent>` stream. `AudioIOEvent.error(_:)` is the initial case; lifecycle cases for `recordingStarted/Completed/Failed/Interruption/Segment` and `playbackStateChanged/Updated` are tracked for M3 because the closure callbacks they replace need a separate host-app migration pass.

Completed before 1.0. SemVer commitment begins at `1.0.0`.

### M3 — Polish (complete)

Goal: outsiders can adopt without reading the source.

- [x] Migrate the remaining `on*` closure callbacks (recordingStarted/Completed/Failed/Interruption/playbackStateChanged/Updated) into the `events: AsyncBroadcaster<AudioIOEvent>` stream as additional cases. Rework `RecordingCrashTracking.attachRecordingCrashTracking`'s chained-observer dance to consume the events stream via a subscriber task with cancellation. (`onSegmentCompleted` deleted as dead surface — never fired.)
- [x] Flatten visualization configuration type homes and naming. (Redundant `Visualization/` subdirectory lifted; duplicate `VisualizationTypes.swift` filenames resolved by splitting into role-based files; `VisualizationWork`/`LODWork`/`AnalysisWork`/`FrequencyDomainWork` moved from `AudioSignals` to `AIOVisualization` to clarify the signal-domain vs engine-coordination boundary.)
- [x] Rewrite DocC catalog with externally-focused topics (Getting Started, Platform Matrix, Threading Model, Error Handling, Events) plus API-surface reference docs for Recording, Playback, Audio Session, and Visualization. Inside-baseball architecture/spec/development docs dropped.
- [x] Ship the `Examples/AudioIODemo` sample app (iOS + macOS). Minimum-viable single-screen demo (record / play / live waveform / events log); SwiftUI codebase shared across iOS and macOS targets; XcodeGen-generated shell.
- [x] Set up GitHub Actions on `xcode-27` (macOS 27, Xcode 27.0). Runs the full macOS suite, compiles all iOS tests, runs the hardware-independent iOS lifecycle/cancellation suites, and builds DocC. Swift Package Index publishes the catalogue.

- [x] Execute the `git filter-repo` extraction into the standalone `swift-audio-io` repository.

Exit criteria: `1.0.0` general availability.

## Known follow-ups

- **Broader iOS test execution in CI** — the migration suites run on iOS 27; other iOS tests remain compile-checked. Hardware-dependent tests need a suitable device or audio environment.
- **Physical-device audio-session validation** — verify activation/refusal semantics, resumption of other apps after deactivation, and recovery during phone calls, Siri, other-app claims, and route disconnects. Simulator tests cannot establish those hardware behaviors.
- **`actions/checkout` runtime update** — update the action independently of this platform migration.

## Stability commitments

### Historical pre-1.0 (`0.x`)

- The public API can change between minor versions. Pin to an exact version (`exact: "0.1.0"`) if that worries you.
- We will not knowingly break the public API in a patch release.
- The deprecation cycle is "one minor version" — a symbol marked deprecated in `0.2.0` may be removed in `0.3.0`.

### Version 1.0 and later

- Source compatibility is preserved across minor and patch versions. Breaking the public API requires a SemVer-major release.
- Deprecations get at least one minor version of warning before removal in the next major.
- SPI surfaces (`@_spi(Internal)`, `@_spi(Visualization)`, `@_spi(AVFoundation)`) are explicitly **not** covered by the SemVer commitment. They exist for power users who accept tighter coupling.

### Platforms

- We commit to iOS 27+ and macOS 27+ at 1.0. Raising the floor requires a SemVer-major.
- We will not lower the floor below the 1.0 commitment without strong demand and a contributor willing to maintain compatibility.

## Now → Next → Later → Not on the roadmap

### Now

- Ship 1.0 with the OS 27 platform floor and cancellation-safe cleanup.

### Next

- Expand iOS runtime coverage and complete the physical-device checks above.

### Later (candidates for post-1.0)

These are real candidates but uncommitted. Subscribe to the linked Discussions for updates.

- **`swift-audio-io-views`** — a sibling repository for standalone, opt-in waveform views. Likely SwiftUI-only at first.
- **Plugin AudioUnit hosting** — support for loading and chaining `AUv3` plugins into recording / playback. Significant scope; would require a champion.
- **Sample-accurate sync across multiple AudioIO engines** — a real ask from people building DAW-shaped products. Requires careful thought about session ownership.
- **Linux / non-Apple platform support** — only meaningful with a non-AVFoundation backend; effectively a parallel implementation.
- **Hardware route preferences API** — finer-grained control over `AVAudioSession` route selection beyond the current input-picking environment.

### Not on the roadmap

The following are explicitly *not* planned. See [NOT_AUDIO_IO.md](NOT_AUDIO_IO.md) for the full reasoning.

- General DSP / effects.
- Multi-track editing.
- Network streaming (HLS, WebRTC, AirPlay).
- Cloud sync.
- UI components of any kind.
- Other Apple platforms beyond iOS and macOS.

## How decisions are made

Roadmap items move forward when:

1. A clear use case exists outside a single host app.
2. The API addition fits the spirit-of-the-rules test in [NOT_AUDIO_IO.md](NOT_AUDIO_IO.md).
3. A contributor (often a maintainer) commits to seeing it through, including tests and docs.

If you want to propose moving something from "Later" to "Next," open a Discussion. We respond, but slowly.
