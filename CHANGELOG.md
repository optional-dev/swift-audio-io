# Changelog

All notable changes to AudioIO are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com) categories, and
releases follow the versioning policy in `README.md` and `ROADMAP.md`.

## 0.18.4 - 2026-09-13

### Fixed

- Live LOD snapshots now expose `committedLODCount`, the absolute bucket count
  for the published data. Renderers can anchor geometry to that publication
  instead of the independently advancing raw-audio cursor, preventing old
  waveform peaks from moving as the publication lag changes. The count stays
  monotonic across ring wraps and resets with the processor.

## 0.18.3 - 2026-09-13

### Fixed

- Repeated Raw/Processed changes prepare the audio-session mode before
  discovering and resolving microphone sources and channels. A choice that
  disappears in Raw can no longer prevent switching back to Processed.
  Requested input choices remain intact when a mode cannot provide them.
- Processing preparation remains serialized with reconciliation, skips
  unchanged session writes, and bounds retries after platform errors. Inactive
  sessions still defer preparation until activation.

## 0.18.2 - 2026-08-27

### Changed

- The non-`Result` engine-control helpers catch graph exceptions too, closing
  the last path on which a raise could abort the process. They return `T` and so
  cannot hand a failure back, so their contract is instead to degrade to a
  caller-supplied fallback and report: logged, and published on
  `AudioIOEvent.error` as a transient `SessionError.notReady`.
- Both helpers now take a `stage` label, which is the attribution — the only
  thing in the report that says which graph operation raised. Every call site
  names its operation.
- `withEngineControlQueue` resumes its continuation from a single unconditional
  statement, carrying the raise out as a value. A resume reachable only on the
  success path would, once the exception is caught rather than fatal, leave the
  awaiting task suspended forever.

### Fixed

- The two reads of `inputNode.inputFormat(forBus:)` behind
  `withEngineControlQueue` return `AVAudioFormat?`. There is no honest fallback
  format, so a graph that raised reports none: the pause path joins its existing
  invalid-format branch, and a route change with no observed "before" format
  reports no quality change rather than a fabricated one.

## 0.18.1 - 2026-08-27

### Fixed

- A first `.hardware` sample-rate recording no longer crashes the process.
  `readHardwareInputSampleRate()` called `AVAudioEngine.prepare()` before
  anything had read an I/O node. `AVAudioEngine` creates `inputNode` and
  `outputNode` lazily, so on a freshly built graph — which holds only the
  attached player node — `AVAudioEngineGraph::Initialize` failed its
  `inputNode != nullptr || outputNode != nullptr` condition and raised an
  Objective-C exception that no Swift `catch` can intercept. The input node is
  now materialized before the prepare, as the `reinstallTap` prepares already
  did incidentally.

### Changed

- Objective-C exceptions raised by the audio graph are caught rather than left
  to abort the process. `AVAudioEngine` reports precondition violations by
  raising `NSException` from C++, which no Swift `catch` intercepts;
  `runOnEngineControlQueueResult` and `withEngineControlQueueResult` — the
  helpers every graph mutation already goes through — now surface a raise as a
  `.failure`, so the playback and capture starts classify it with the error
  handling they already had. On the recording bring-up path, `prepare()` and
  `start()` go through guarded helpers that separate a graph which is not ready
  (`.notReady`, retried by the start deadline loop) from an engine that
  declined to start (`.engineStartFailed`).

## 0.18.0 - 2026-08-26

### Added

- Per-input capability evidence on
  `AudioInputConfigurationCapabilities.endpointCapabilities`. iOS reports
  Bluetooth high-quality-recording and far-field support/enabled state from
  the port's Bluetooth microphone extension. macOS reports Core Audio's native
  nominal sample-rate ranges for each input device.
- `AudioInputEndpointCapabilities`, `AudioInputFeatureCapability`,
  `BluetoothMicrophoneCapabilities`, and `AudioSampleRateRange`, including a
  tri-state native-rate query that preserves “unknown” on platforms such as
  iOS instead of treating missing enumeration as unsupported.

## 0.17.1 - 2026-08-25

### Changed

- `AudioSessionHold.init(release:)` is public so consumers can build test
  doubles for `AudioEnvironmentDriving`.

## 0.17.0 - 2026-08-25

Recording start and continuity are unconditional (Recorder‽ ADR-0003). The
request is a contract on the *output*; the route is a *source* adapted to it.

### Added

- **`AIOEngine.recordingPause` and pause/resume events.** An OS interruption,
  media-services loss, or a route with no usable input now *pauses* a
  running recording — the tap is removed, the file and writer stay open,
  `isRecording` stays `true` — and the engine resumes into the same file when
  the cause lifts, with a backoff retry behind every signal.
  `RecordingInterruption` gains `.paused(RecordingPause)`,
  `.resumed(RecordingPause, qualityChange:)`, and
  `.captureFormatChanged(qualityChange:)`. A recording resumes after an
  interruption whether or not the system advises resuming; `shouldResume`
  still governs playback.
- **Channel adaptation instead of refusal.** `RecordingInputChannelContract`
  is a classification: a route narrower than the requested layout is
  replicated into it through an explicit converter channel map (mono is
  duplicated into both channels of a stereo file), a wider one downmixed. The
  same rule applies at bring-up and on every reinstall.
  `ResolvedCaptureFormat.isReplicatingChannels` / `isDownmixingChannels`
  report it.
- **`CaptureSubstitution` and `ResolvedCaptureFormat.substitutions`.** What
  bring-up changed about the request in order to start: an unavailable
  preferred input (capture proceeds on the current input), a preferred input
  the route had not switched to by the deadline (one lenient attempt), a
  container that yielded to the requested rate, or a rate clamped for a
  caller-named file. `RecordingConfiguration.reducedToEncodable()` applies
  the fixed precedence channel layout › sample rate › bit depth › container.
- **`CaptureInputContract` and
  `AudioEnvironmentManager.resolveCaptureInputContract()`.** The contract a
  capture starts with, derived from the request against the live
  environment; never refuses.
- **`AudioSessionHold` and `acquireAudioSessionHold()`.** Keeps the session
  engaged for a configuration surface; the engine's post-stop release is
  deferred until the last hold goes.
- **`refreshInputConfiguration()`** on `AudioEnvironmentConfiguring`: a
  read-only capability refresh that does not persist a request.
- **`AVAudioEngineConfigurationChange` is observed.** A same-device format
  change (which posts no route change on macOS) reinstalls the tap at the new
  format instead of silently dropping frames.
- **macOS route facts.** Route events carry the default input's nominal rate
  and channel count, so the route-change no-op path is reachable, and the
  route signature includes the rate so a same-device rate change is an event.
- **`AIOEngine.playbackRouteDisconnectBehavior`.** Playback pauses when a
  personal-listening output (headphones, Bluetooth, USB) disconnects — the
  platform convention, now explicit and opt-out.
- `PendingTrackEventKind.recordingPaused` / `.captureSubstitution` and
  `PendingTrackEvent.note`.
- `ChannelCount(count:)`; `AudioInput.channelCount` reports the real count.

### Changed

- The coordinator's write barrier keys on route identity and re-classifies
  each refresh against the current readback. A readback taken right after a
  preference write often has no applied configuration; the next discovery's
  `nil → value` transition used to authorise another write (and republish a
  stale "not applied"). It now classifies as satisfied without writing.
- A request submitted while the session is inactive re-discovers
  capabilities, and no `activeSampleRate` is claimed while inactive.
- `CaptureSubstitution.sampleRateClamped` replaces the silent AAC clamp for
  `.hardware` requests into caller-named files; for other destinations the
  container yields to the rate.

### Removed

- `SessionError.preferredInputUnavailable` (no longer thrown).
- `RecordingInterruption.stoppedByInterruption` (nothing stops a running
  recording but its caller).
- `AudioRecoveryState.pendingRecording` (a paused recording is not restarted;
  it resumes).
- `settleInputConfiguration()` from the `AudioEnvironmentDriving` protocol
  (still available on `AudioEnvironmentManager`).

## 0.16.0 - 2026-08-20

### Added

- **Sample rate as intent.** Recording inputs now carry a `CaptureFormat` —
  a `RecordingSampleRate` intent (`.hardware` or `.exact(SampleRate)`) plus a
  `ChannelCount`. `.hardware` records at whatever rate the active route
  actually runs, resolved once at bring-up (input node on the microphone path,
  process-tap stream format for system audio) with no resampling and no
  `setPreferredSampleRate` write; `.exact` keeps today's convert-to-target
  behavior. Rates the output encoder cannot write clamp to the nearest
  encodable value (AAC tops out at 48 kHz). Interruption restarts re-resolve
  against the route that exists at restart. See the new "Sample Rates" DocC
  article.
- **Capture provenance.** `ResolvedCaptureFormat` reports the hardware format
  feeding the file vs the file's own format, with `isResampling` and
  `effectiveSampleRate` (the honest bandwidth ceiling — a 48 kHz file fed by a
  16 kHz Bluetooth mic reports 16 kHz). Carried on every
  `recordingStarted(url:format:capture:)` event, observable as
  `AIOEngine.activeCaptureFormat`, and refreshed on route-change reinstalls.
- **`BluetoothMicrophonePolicy`.** The recording session's Bluetooth decision
  is a named policy — `.handsFree` (default, today's behavior), `.never`
  (built-in mic at full rate, A2DP output), or `.highQualityWhenAvailable`
  (iOS 26 high-quality Bluetooth recording, 48 kHz on H2 AirPods, HFP
  fallback) — on `recordingConfiguration(useMeasurement:bluetoothMicrophone:)`
  and `AudioEnvironmentManager.recordingBluetoothMicrophonePolicy`.
- **Honest capabilities.** `AudioInputConfigurationCapabilities.activeSampleRate`
  is the platform's actual rate (from the applied configuration);
  `likelySampleRates` is documented as the picker guess-list it always was.
  An `.automatic` sample-rate request writes no preference and can no longer
  land in `.unsatisfied(.rejectedSampleRate)`.
- **OS 27 tap API.** The input tap installs through
  `installAudioTap(onBus:bufferSize:format:tapProvider:)` on OS 27 hosts
  (bridging `AVReadOnlyAudioPCMBuffer` into the existing capture path
  zero-copy — the capture path reads the tap's samples in place, with no
  per-callback copy) and macOS device selection uses `withAUAudioUnit`, both
  behind the project's compiler + availability double gate; earlier systems
  keep the legacy calls.
- `SampleRate.speech` (16 kHz), the standard speech-to-text target.

### Changed

- **Breaking:** `RecordingConfiguration.format` is now
  `requestedFormat: CaptureFormat`, with `exactFormat: InputConfiguration?` as
  the resolved accessor; `MicrophoneRecordingInput.format` and
  `SystemAudioRecordingInput.format` changed type from `InputConfiguration` to
  `CaptureFormat` (wrap an existing value in `CaptureFormat(_:)`).
- **Breaking:** `recordingStarted(url:format:)` is now
  `recordingStarted(url:format:capture:)`.
- **Breaking:** `AudioInputConfigurationCapabilities`' memberwise initializer
  gains `activeSampleRate:`.

## 0.15.0 - 2026-08-13

The 0.15.0 tag was cut with this content still under "Unreleased"; the section
heading is recorded here retroactively.

### Fixed

- The iOS input-configuration feedback loop. An exact sample rate the route
  refused left reconciliation stably `.unsatisfied`, and the only guard against
  reissuing platform preferences tested for `.satisfied` — so every 15-second
  poll and every route notification re-ran the platform apply, whose
  `setCategory` write posted another `.categoryChange` route notification, which
  reconciled again. With a recording live, each turn of the loop also stopped
  the engine and reinstalled the tap.

  Three independent gaps closed:

  - **Reconciliation is single-flight and coalesced.** `reconcile` suspends at
    the platform apply and is driven from several tasks (route notifications,
    input-availability notifications, the periodic poll), so main-actor
    isolation alone did not serialize it. At most one run is now in flight, and
    every request arriving during one is merged into a single follow-up run.
    That follow-up still re-discovers, so a genuine route change arriving
    mid-apply is not lost.
  - **A platform write barrier replaces the `.satisfied`-only guard.** A
    reconciliation writes to the platform only when something nameable changed:
    a new requested generation, a different resolved plan, different observed
    platform facts, a deliberate forced apply (activation, orientation,
    media-services recovery), or remaining budget after a *thrown* write. A
    settled rejection is not a reason to write again. Requested and applied
    state stay distinct — exact intent is never rewritten to the platform's
    fallback.
  - **Platform writes are idempotent where readback permits.** `setCategory`,
    `setPreferredInput`, `setPreferredSampleRate`,
    `setPreferredInputNumberOfChannels`, `setPreferredInputOrientation`,
    `setPreferredIOBufferDuration`, and the data-source and polar-pattern
    setters now compare against the session's own readback first, on both the
    input-configuration and recording-bring-up paths.

- Route recovery no longer tears down a live recording tap for a self-induced
  route notification. The decision is made on ``AudioInputFacts`` — input
  endpoints, availability, sample rate, channel count, and session mode — rather
  than on the existence of a notification. The tap survives only when the
  reported facts match the last observed ones *and* the installed tap already
  runs at those facts; unknown facts, a changed route, or a graph that needs
  rebuilding all still reconfigure.

### Changed

- **Source-breaking.** `OutputConfiguration.bitDepth` is now `BitDepth?`, and
  `FileFormat.supportedBitDepths` is empty for `aac` and `adts`. AAC is a lossy
  transform codec with no PCM sample width to choose: its file settings carry no
  bit-depth key and the capture pipeline is Float32 regardless, so the previous
  `[.pcmFloat32, .pcmInt16]` put a control in front of users that changed
  nothing. Pass `nil` for the AAC family; `FileFormat.usesBitDepth` and
  `FileFormat.defaultBitDepth` report which formats need a value.
- **Source-breaking.** `FileFormat.requiresQuality` is renamed
  `FileFormat.usesEncodingQuality`, and `EncodingQuality` is documented as what
  it is: an `AVAudioQuality` *level* written as `AVEncoderAudioQualityKey`, not
  a bitrate. AudioIO does not set `AVEncoderBitRateKey`, so two recordings at
  the same level are not promised the same bitrate.
- `RecordingConfiguration.fileSettings` and its output format now share one
  validation gate instead of re-deriving sample-rate and channel checks per
  format arm — the AAC arm ran the same sample-rate check twice, and the PCM and
  FLAC arms carried hard-coded bounds that could drift from
  `FileFormat.supportsEncodedSampleRate(_:)`.
- Media-services recovery performs its reconciliation as an explicit forced
  apply, which the write barrier then absorbs so the resulting notification does
  not recur.

### Added

- `RecordingConfiguration.validate()` and `OutputConfiguration.validate(against:)`,
  returning `CaptureConfigurationValidation` — a side-effect-free check of the
  complete capture configuration (input format plus file format, channel count,
  and bit depth) that needs no audio session, route, or activation. Input and
  output are selected through independent APIs, so combinations such as a 96 kHz
  capture written to `m4a` were only discoverable when the writer refused.
  `CaptureConfigurationIssue` names each defect.
- `OutputConfigurationManager.validate(against:)` and
  `availableOutputFormats(for:)`, plus `usesBitDepth` and `usesEncodingQuality`,
  for building pickers that only offer writable combinations. The output
  selection is remembered per input device while the requested input sample rate
  is a single global intent, so the two can drift apart across a route change.
- `AudioInputFacts`, the capture-relevant subset of a route transition, and
  `AudioRouteChange.inputFacts`.
- `AudioInputReconciliationPolicy`, which bounds retries after a thrown platform
  write.

## 0.14.0 - 2026-08-01

### Added

- Progressive offline LOD extraction for long files. The new progress
  overloads publish ordered, throttled snapshots with static timeline metadata,
  an available-prefix boundary, a guaranteed terminal snapshot, and typed task
  cancellation.
- A complete requested/applied microphone input model. Durable
  `AudioInputConfigurationRequest` values cover input, source and polar
  pattern, channels, sample rate, and processing mode;
  `AudioInputConfigurationState` reports that request separately from exact
  active-route readback, capabilities, and reconciliation disposition.
- `requestInputConfiguration(_:)` for accepting input intent while inactive,
  and `settleInputConfiguration()` as the generation-aware capture barrier.
  Automatic channel policy prefers Stereo when a valid Stereo option exists;
  exact requests never fall back.
- A package-internal platform adapter and pure resolver with deterministic
  tests for deferral, rejection, no-op readback, partial application, route
  churn, persistence, and superseding requests.
- `bin/check-input-configuration-api.sh`, run by CI, prevents the deleted
  scalar and apply-method surface from returning.
- `FileFormat.toleratesTruncation` and `FileFormat.preservesExactFrameCount`.
  Two orthogonal facts about the writer and the container, in the style of
  `requiresQuality`: whether a file cut off mid-write is still readable up to
  the truncation point, and whether decoding returns exactly the frames that
  were written. Only `adts` tolerates truncation — every AAC frame carries its
  own header — while the PCM containers and `m4a` declare a length or an index
  finalized at close. FLAC is reported conservatively as `false`: its frames
  carry sync codes, but `STREAMINFO`'s total-samples field and the seektable
  are written at close, so a truncated stream is decoder-dependent. Everything
  except the AAC family is frame-exact; AAC adds encoder priming and tail
  padding. A consumer composes its own policy from the two — "rotate for
  crash-safety" wants `!toleratesTruncation`, "reassemble losslessly" wants
  `preservesExactFrameCount`.

### Changed

- **Source-breaking.** `AudioEnvironmentDriving` and
  `AudioEnvironmentConfiguring` now expose one requested/applied state and one
  settle barrier. Session activation, route changes, media-services recovery,
  and orientation changes reconcile the latest request through the same
  serialized path and publish success only after readback.
- **Source-breaking.** `stopRecording()` returns `RecordingCompletion` and
  `rotateRecordingFile()` returns `RecordingRotation`, each carrying the
  `completedURL` that used to be the whole return value plus a
  `boundaryFramePosition`: the cumulative persisted-frame position at which
  that file ends. Consecutive rotations produce a strictly increasing
  sequence, so a consumer reassembling a rotated capture can derive each
  file's exact frame length as the difference between adjacent boundaries, and
  the final boundary — the capture's total frame count — closes the
  arithmetic.

  The engine already computed this number on both paths and discarded it. A
  consumer could only approximate it by reading `recordingTimingSnapshot()`
  after the call, which is unsound during a rotation for three independent
  reasons: the capture counter is cumulative and never resets at a rotation,
  the read races the capture callback, and frames awaiting drain into the
  completed file have already been counted. Returning the value from the call
  that produces it removes all three — it is sampled where the split is
  decided.

  Migration is mechanical and the compiler finds every site:

  ```swift
  let url = try await engine.stopRecording()
  let url = try await engine.rotateRecordingFile()
  // become
  let url = try await engine.stopRecording().completedURL
  let url = try await engine.rotateRecordingFile().completedURL
  ```

- Recording tests now drive the real `startRecording(configuration:)` path.
  Previously the two most-used test entry points reimplemented recording start
  and capture, so the production `RecordingLifecycle.attemptRecordingStart` —
  the deadline loop, retry classification, validation, ring-buffer and writer
  construction, event emission, and abort reconciliation — had no test
  exercising it. A new `RecordingEnvironment`, supplied immutably at
  initialization, replaces only the three collaborators that need real audio
  hardware: the tap installer, the capture backend, and engine teardown.
  Because that removes the `AVAudioEngine` dependency, 31 tests that were
  compiled-but-never-run on iOS now execute on macOS in CI.

### Removed

- **Source-breaking.** The independent `AudioEnvironmentManager` configuration
  scalars, `applyMono()`, `applyStereo()`, `applySourceConfiguration()`,
  `AudioChannelConfigurationAvailability`, and
  `AudioInputPickingEnvironment`.
- The prerelease preference controller, restorer, per-property store, and
  duplicated automatic-Stereo/Mono-fallback policy. Old preference keys are
  intentionally ignored; the new request uses one encoded schema.
- `Sources/AudioIO/AIOEngine+Testing.swift` and its 16 `@_spi(TESTING)`
  methods on `AIOEngine`, along with the `#if DEBUG` override properties
  (`testReinstallTapOverride`, `testEngineTeardownOverride`,
  `recordingStartReadinessOverride`). Test-support code is no longer compiled
  into the shipping `AudioIO` library, which drops from 1091 to 632 lines.
  `@_spi(TESTING)` no longer appears anywhere in the package. Symbols behind
  `@_spi` are explicitly outside the stability promise (see CONTRIBUTING);
  equivalents live in the new, unvended `AIOTestSupport` target.

### Fixed

- A `stopRecording()` that lands while a rotation's drain is still in flight no
  longer stalls for the full five-second writer drain timeout. The stop set one
  target — the capture's end — on *every* writer session, including ones a
  rotation had already drained to the boundary its file ends at. The frames
  between that boundary and the capture's end went into the next file's ring,
  so the completed writer could never reach the raised target: its drain waited
  out `writerDrainTimeout`, force-closed, and recorded a write failure for a
  file that was already complete. A session that already has a target now keeps
  it, and the stop joins its in-flight drain instead of re-aiming it. The
  pre-existing `rotate recording file emits two files` test had been paying
  this five-second cost on every run while still passing.

- A rotation no longer hands the capture tap fresh ring buffers, which makes
  the reported boundary exact rather than approximate. Rotation used to sample
  the boundary, replace the tap's rings, and refresh the snapshot the tap falls
  back to when `state` is contended as three separate steps, so a capture
  callback could take its rings from one side of the split and its frame
  position from the other — writing into the completed file's ring while being
  counted past that file's boundary. That cannot be fixed by locking on the
  rotation side: the tap must never block, so it reads its rings under
  `withLockIfAvailable` and accounts for its frames afterwards, and no lock
  held here orders those two events. Combining the steps into one critical
  section only converts the error into a dropped buffer, because a callback
  arriving inside it misses both locks.

  Rotation is now a change of consumer rather than of transport. The tap keeps
  writing into the same rings across the boundary; the completed writer stops
  reading at exactly `boundaryFramePosition`, leaving the frames past it in the
  ring for the writer that takes over, and the two loops share a serial queue
  so they can never read it at the same time. The split is enforced where it is
  observed instead of being raced for, so no callback can be on the wrong side
  of it, no buffer is dropped, and a file is exactly as long as the boundary
  reported for it. `receiverBuffers` already survived rotation this way.

  The writer loop reading no further than its target also removes an older
  hazard on the same path: a loop could previously still be writing when the
  satisfied drain closed the file underneath it. One visible consequence at
  stop: frames the capture path delivers *after* `stopRecording()` samples its
  target are no longer appended to the file. Whether they landed there used to
  depend on how quickly the drain cancelled the loop; now the final file is
  exactly `boundaryFramePosition` frames long, every time.

- Every recording-file rotation after the first no longer stalls for the full
  five-second writer drain timeout. Drain targets are sampled from the
  capture-wide frame counter, but each writer loop reported its progress from
  zero, so the comparison `written >= target` was between two different
  domains. They coincide for the first file, which is why a single rotation —
  all the tests exercised — looked healthy. From the second rotation on the
  target was unreachable: the drain waited out `writerDrainTimeout`,
  force-closed the file, and recorded a write failure that the next
  `stopRecording()` then had to explain away. A writer session now carries the
  frame position its file starts at and reports progress in the capture's
  domain. The audio was never affected — the writer keeps flushing until its
  ring empties — but a three-rotation capture now settles in milliseconds
  instead of fifteen seconds.

- Two documentation claims about rotation that the code does not support.
  `RecordingTimingSnapshot.capturedFrameCount` said it counted frames "for this
  segment"; it is cumulative for the capture and is not reset by a rotation, so
  reading it as a segment length after one is wrong by the length of the entire
  preceding session. (The counter's behaviour is the useful one — resetting it
  at a rotation would destroy `firstBufferHostTime` for the capture, which
  multi-device alignment depends on — so the documentation follows the code.)
  The `Recording` article said "the previous file is fully drained before the
  rotation returns"; the drain is handed to a background task, and rotation
  returns without waiting for it.

- The DocC catalogue is now actually built. It lived at `Sources/AIO.docc`,
  outside any target, so SwiftPM never associated it with a module and nothing
  ever compiled it; its landing page also declared `# ``AIO``` for a module of
  that name that does not exist. It now sits at
  `Sources/AudioIO/AudioIO.docc` and documents the `AudioIO` module, and CI
  builds it. Three latent defects the first real build surfaced are fixed: a
  broken ``OrientationObserver`` link (iOS-only, so absent from the macOS
  documentation build), a `Recording` ↔ `SystemAudioCapture` curation cycle,
  and a malformed task-group item in `ErrorHandling`.

### Removed

- **Source-breaking.** `AIOEngine.RecordingInterruption.stoppedGracefully`. No
  code path ever constructed it: every caller of the interruption stop reports
  a genuine failure (lost input, failed tap reinstall after a route change, an
  audio-session interruption, or a media-services reset), and all four emit
  `.stoppedByInterruption`. A user-initiated stop is — and always was —
  reported by `recordingCompleted`. Consumers switching exhaustively over
  `RecordingInterruption` should delete the `.stoppedGracefully` branch; it was
  unreachable.

- **Source-breaking.** `VerboseError`. It was never constructed anywhere in the
  package, and mapped `AVAudioSession`, AudioFile, AudioCodec, AUGraph,
  AudioUnit — and MIDI — status codes into a description string that nothing
  read.
- **Source-breaking.** `VisualizationSink` and
  `AudioVisualizationEngine.subscribe(request:sink:)`. The protocol had no
  conformers and the sink-based overload had no callers; it was a thin wrapper
  over `subscribe(request:handler:)`, which remains.
- `AIOEngine.sessionConfiguration`, a public forward to
  `recordingSessionConfiguration` with no callers. Use
  `recordingSessionConfiguration` directly.
- `IOSPlatformAudioBackend`. It was unreachable — the only call to
  `PlatformAudioBackendFactory.makeDefault()` is inside `#if os(macOS)`. Its
  capabilities are already covered by `AudioEnvironment.notifications` and
  `AudioRouteObserver`, which carry the route-change reason and previous route
  that `PlatformAudioRouteEvent` cannot express.
- `AudioEnvironmentManager._InputConfigError`, which was unreferenced.

## 0.13.0 - 2026-07-28

Adopts the iOS 27 asynchronous `AVAudioSession` lifecycle. The deployment floor
is unchanged at iOS 26 / macOS 26 — every iOS 27 API sits behind an
availability check with the iOS 26 path preserved.

### Added

- One activation seam, `AudioSessionActivating`, with two package-internal
  implementations selected once per owner: `NativeAudioSessionActivator`
  (iOS 27, `activate(options:)` / `deactivate(options:)`) and
  `LegacyAudioSessionActivator` (iOS 26, the synchronous `setActive` serialized
  behind the session-access gate). Deactivation passes
  `.notifyOthersOnDeactivation` on both paths, so other apps are still told
  they may resume.
- Three `AudioSystemEvent` cases fed by the iOS 27 session-state channel:
  `sessionActivated`, `sessionDeactivated(_:)` carrying an
  `AudioSessionDeactivation` (`AudioSessionDeactivationSource` plus an optional
  `AudioInterruptionReason`), and `resumptionRecommended(_:)`. On iOS 26 the
  backing notification streams degrade to logged no-ops and the events are
  never emitted.
- `FakeAudioSessionActivator` in the test-support target: records ordered
  activation calls and takes scriptable per-call failures and gates, which is
  what makes activation ordering assertable at all.

### Changed

- Activation is serialized and supersession-aware. A request duplicating the
  newest intent returns immediately; a queued request the platform has already
  satisfied makes no platform call; and `isAudioSessionActive` is written only
  from a completed platform transition, so it mirrors the platform rather than
  the request. A superseded request drops its follow-on input reconciliation
  and lets the newer request perform it.
- Both engine-managed fallback sites now use the shared activator, so exactly
  one code path in the package touches activation. This closes a latent
  overlap: `AIOEngine.setAudioSessionDemand` previously called
  `AVAudioSession.setActive` raw — no options, and outside the session-access
  gate — where it could interleave with controller-driven activation.
- `RecordingLifecycle.configureAudioSession(for:sessionConfiguration:)` and the
  graph preparation that calls it are now `async`, because activation is.
  Engine-managed activation keeps its position in the configuration sequence:
  after category, mode, sample rate, and buffer duration, before preferred
  input and channel count.
- `InterruptionPolicy` deduplicates the two channels an iOS 27 interruption can
  arrive on. Interruption events remain the recovery trigger; a system
  deactivation stages recovery only when nothing is staged, and an
  app-requested deactivation never stages any. A resumption recommendation is
  advice about playback only: a positive one may resume pending playback and
  never restarts a recording, and a negative one suppresses the automatic
  playback restart that `interruptionEnded(shouldResume: true)` would perform.

## 0.12.1 - 2026-07-27

### Fixed

- Made satisfied microphone-input reconciliation read-only during route
  notifications and periodic capability refreshes. This prevents
  `AVAudioSession` preference writes from generating another route change and
  repeatedly stopping and reinstalling the recording tap, which produced
  regularly spaced bursts instead of continuous audio. Session activation and
  orientation changes still perform one explicit platform apply.

## 0.10.3 - 2026-07-24

### Removed

- **Source-breaking.** The `extension Reporter where E == any Error` overloads of
  `callAsFunction`. With `E == any Error`, `throws(E)` is spelled `throws`, so
  after substituting the constraint those overloads had signatures identical to
  the generic ones and could only be ranked against them by
  `@_disfavoredOverload`, which both sides carried. Swift 6.4 (Xcode 27 beta 4)
  no longer breaks that tie via constrained-extension specialization, so every
  call through `ErrorManaging.reporter(...)` — which always vends
  `Reporter<any Error>` — failed with `ambiguous use of 'callAsFunction'`. The
  generic overloads already cover `E == any Error`.

### Changed

- `Reporter<any Error>` rethrows the original error rather than flattening it
  into `ReportedError.error(description:)`, and propagates `CancellationError`
  as itself rather than as `ReportedError.cancelled`. Error reporting to
  receivers is unchanged, as is the `Reporter<E>` behaviour for every other `E`.
  Callers that only test for failure (`try?`) are unaffected; callers that
  matched on `ReportedError` must match the underlying error instead.
  `ReportedError` is otherwise unchanged and still usable as
  `Reporter<ReportedError>`.

## 0.10.1 - 2026-07-24

### Fixed

- `AIORecording` compiles under Swift 6.4 (Xcode 27 beta 4). The recording
  publish hop passed a typed-throws closure to `MainActor.run`, which crashed the
  frontend during IR emission (`constructing SILType with type that should have
  been eliminated by SIL lowering`) and made the whole package unbuildable. The
  hop now returns `Result<URL, RecordingError>` and the caller unwraps it with
  `Result.get()`, which is itself `throws(Failure)` — the thrown error type is
  unchanged and no behaviour changed.
- `AIOTests/PublicAPISnapshot` no longer fails to compile on ambiguity between
  `AudioIO.SourceLocation` and swift-testing's `SourceLocation`; the snapshot now
  names the `AudioIO` type explicitly.

## 0.10.0 - 2026-07-24

### Added

- `AIOEngine.startRecording(configuration:)` now performs bounded readiness
  retry for every capture source and reports timeout, cancellation, and
  competing starts as typed `RecordingError` cases.
- `AIOEngine` accepts an immutable `AudioSessionAuthority` and recording-start
  timeout at initialization.
- Added the platform-neutral `AudioSystemEvent`, `AudioRouteChange`, and route
  snapshot values.

### Changed

- Recording intent belongs to the caller: retaining or cancelling the task
  awaiting `startRecording` is the complete startup lifecycle.
- Startup failures throw from `startRecording`; `recordingFailed` is reserved
  for failures after capture has begun.
- Microphone and system-audio capture now share one internal source-lifecycle
  seam for start, graceful or immediate stop, and cleanup.
- Recording state and operations now have one internal `RecordingLifecycle`
  owner with focused capture, writer, receiver, and rotation helpers; the
  consumer-facing `AIOEngine` recording API is unchanged.
- `AudioEnvironmentManager` now emits one audio-system event surface, and
  `AIOEngine.handleAudioSystemEvent(_:)` applies shared recording and playback
  recovery policy on both platforms.

### Removed

- Removed the desired-state/reconciliation APIs, public partial `warm` surface,
  mutable audio-session delegate wiring, and `reconciliationFailed` event.
- Removed the platform-specific engine interruption handlers, AVFoundation
  interruption aliases, and four separate environment event subscriptions.

## 0.9.0 - 2026-07-21

### Added

- `AsyncBroadcaster.subscribe()` synchronously registers an explicitly
  cancellable subscription so lifetime-owned consumers cannot miss events while
  their processing task is waiting to be scheduled.
- Audio route, port, and session snapshots can be constructed from captured
  values, allowing route-change behavior to be replayed and tested without
  consulting the process-global audio session.

### Changed

- Recording measurement mode is now owned and persisted by each
  `AudioEnvironmentManager`. `AudioSessionConfiguration` is a pure value factory,
  and the recording engine derives the active mode through its injected audio
  session delegate instead of reading or mutating global preferences.
- File and output configuration helpers use owned `FileManager` and
  `UserDefaults` instances, and shared formatter state has been removed.

## 0.8.1 - 2026-07-20

### Fixed

- iOS microphone activation now awaits persisted input/channel restoration, and
  stereo selection explicitly requests two input channels before publishing its
  state. Recording bring-up rejects and retries a route or input tap that exposes
  fewer channels than requested instead of silently producing duplicated mono in
  a stereo processing format.

## 0.8.0 - 2026-07-17

### Added

- `RecordingTimingSnapshot` now reports the last persisted-buffer host time,
  exact persisted frame count, and exact frame count spanning the measured host
  interval. Multi-device clients can use the interval to measure effective
  capture rate without estimating from file duration or counting dropped tap
  callbacks.

## 0.7.0 - 2026-07-16

### Changed

- Audio-session activation and deactivation now use async AudioIO APIs and run
  the blocking iOS `AVAudioSession.setActive` operation on AudioIO's serialized
  off-main session queue. `AudioEnvironmentManager.setAudioSessionActive`,
  `AudioSessionDelegate.setAudioSessionActive`, and `AIOEngine.warm` are now
  async so callers can suspend without blocking the main thread.

## 0.6.0 - 2026-07-14

### Added

- Added `AudioChannelConfigurationAvailability` and
  `AudioEnvironmentConfiguring.channelConfigurationAvailability` so clients can
  distinguish an unresolved input from a fixed mono/stereo input or an input
  whose channel configuration is user-selectable. The capability follows the
  system-default input without pinning it as a preferred device.

## 0.5.4 - 2026-07-08

### Fixed

- macOS: an input-route change (device added/removed, default input changed)
  during a system-audio recording no longer reinstalls the AVAudioEngine input
  tap. Previously the route-change handler treated every active recording as a
  microphone recording: it started the microphone and overwrote the shared tap
  converter, so the system-audio file silently captured microphone audio (or
  went silent). `reinstallTap` now also refuses system-audio configurations
  outright.
- macOS: `AudioEnvironmentManager` no longer pins a concrete input device when
  the selection is "system default" (`selectedInput == nil`). Refreshes keep
  `nil` selections so recordings follow default-input changes, a disappeared
  explicit selection falls back to the system default instead of an arbitrary
  remaining device, and the explicit selection re-attaches when its device
  returns.

### Added

- macOS: a diagnostic warning is logged when system-audio self-exclusion cannot
  resolve the host's HAL process object and falls back to bundle-identifier
  exclusion.

## 0.4.0 - 2026-07-03

### Added

- Added `PlaybackScrubMode` and `AIOEngine.scrub(to:mode:)` so callers can
  express interactive drag scrubs separately from committed seeks without
  reaching for playback-polling internals.

## 0.1.1 - 2026-05-28

### Fixed

- Paused playback now reports the current position instead of resetting
  `AIOEngine.Playback.time` to the segment start frame. While an
  `AVAudioPlayerNode` is paused it cannot report `lastRenderTime`, so
  `getPlayback(for:)` previously fell back to the start frame on every poll;
  it now returns the last observed position for the active playback instance.
  Consumers driving a playhead from `Playback.time` no longer see it jump to
  the start of the track on pause.

## 0.1.0 - 2026-05-28

Initial public release. This is the start of the
`0.x` line — the public API may change between minor versions until `1.0.0`.

### Added

- **`AudioIO`** umbrella product: recording, playback, audio-session coordination,
  real-time visualization, and microphone-health monitoring, driven through a single
  `AIOEngine`.
- **`AudioSignals`** product: signal-domain data types (`TimeDomainData`,
  `FrequencyDomainData`, `BeatInfo`) and multi-band LOD waveform extraction
  (`MultiBandLODProcessor`, `OfflineLODExtractor`), usable without the recording stack.
- **`Tools`** product: async/concurrency primitives (`AsyncBroadcaster`, `Subject`,
  `SPSCRingBuffer`) surfaced because they appear in AudioIO's public contracts.
- Unified `AIOEngine.events: AsyncBroadcaster<AudioIOEvent>` stream carrying every
  engine-level error and recording/playback lifecycle transition.
- Per-domain typed errors (`RecordingError`, `PlaybackError`, `SessionError`) under
  the `AudioIOError` marker protocol.
- Canonical `startRecording(configuration:) async throws(RecordingError) -> URL`
  entry point; reconciliation-mode recording behind `@_spi(Advanced)`.
- DocC catalog with externally-focused topics (Getting Started, Platform Matrix,
  Threading Model, Error Handling, Events) and per-surface reference docs.
- `Examples/AudioIODemo`: a minimum-viable iOS + macOS sample app.
- Apache-2.0 license.

### Platforms

- iOS 26+, macOS 26+. Swift 6.2 with strict concurrency.
