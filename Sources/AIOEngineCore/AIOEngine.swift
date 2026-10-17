// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AsyncAlgorithms
  package import Atomics
  package import AVFoundation
  import Dispatch
  import Foundation
  import Observation
  import os
  import Tools

  private let log = SystemLog.make()
  #if DEBUG
    package let rtLoggingEnabled: Bool = ProcessInfo.processInfo.environment["AIO_RT_LOGS"] == "1"
  #else
    package let rtLoggingEnabled = false
  #endif

  /// The core audio recording and playback engine.
  ///
  /// `AIOEngine` provides a high-level interface for capturing and playing back audio, built on top of `AVFoundation`.
  /// It manages the audio engine, session, and I/O, providing real-time audio data through a `BufferReceiver` protocol.
  ///
  /// ## Topics
  ///
  /// ### Creating an Engine
  ///
  /// - ``init()``
  ///
  /// ### Recording Audio
  ///
  /// - ``startRecording(configuration:)``
  /// - ``stopRecording()``
  /// - ``isRecording``
  ///
  /// ### Playing Audio
  ///
  /// - ``play(url:)``
  /// - ``stopPlayback()``
  /// - ``scrubPlay(to:)``
  /// - ``isPlayback``
  /// - ``isPlaying``
  /// - ``playback``
  ///
  /// ### Handling Events
  ///
  /// - ``events``
  /// - ``AudioIOEvent``
  ///
  /// ### Attaching Receivers
  ///
  /// - ``attachBufferReceiver(_:)``
  /// - ``detachBufferReceivers()``
  ///
  /// ### Managing Audio system events
  ///
  /// - ``handleAudioSystemEvent(_:)``
  ///
  @Observable
  public final class AIOEngine: Sendable {
    /// An event representing a change in audio quality.
    public struct AudioQualityChange: Sendable {
      public init(
        reason: String,
        previousChannels: UInt32,
        currentChannels: UInt32,
        previousSampleRate: Double,
        currentSampleRate: Double,
      ) {
        self.reason = reason
        self.previousChannels = previousChannels
        self.currentChannels = currentChannels
        self.previousSampleRate = previousSampleRate
        self.currentSampleRate = currentSampleRate
      }

      /// The reason for the quality change.
      public let reason: String
      /// The previous number of channels.
      public let previousChannels: UInt32
      /// The current number of channels.
      public let currentChannels: UInt32
      /// The previous sample rate.
      public let previousSampleRate: Double
      /// The current sample rate.
      public let currentSampleRate: Double

      public var description: String {
        "Format changed: \(previousChannels)ch@\(Int(previousSampleRate))Hz → \(currentChannels)ch@\(Int(currentSampleRate))Hz"
      }
    }

    /// Something the environment did to a running recording — and what the
    /// recording did about it. None of these is a stop: a recording ends only
    /// when its caller stops it.
    public enum RecordingInterruption: Sendable {
      /// The audio route changed, but recording is continuing.
      case routeChangeContinuing(event: AudioRouteChange, qualityChange: AudioQualityChange?)
      /// The input node's format changed without a route change (a same-device
      /// sample-rate change, say); recording is continuing at the new format.
      case captureFormatChanged(qualityChange: AudioQualityChange?)
      /// Capture is paused: no frames are being written, the file is open,
      /// and the recording resumes into it when the cause lifts.
      case paused(RecordingPause)
      /// Capture resumed into the same file after a pause.
      case resumed(RecordingPause, qualityChange: AudioQualityChange?)

      public var description: String {
        switch self {
        case .routeChangeContinuing(let event, let qualityChange):
          if let change = qualityChange {
            "\(event.userMessage), continuing with: \(change.description)"
          } else {
            "\(event.userMessage), continuing with same quality"
          }
        case .captureFormatChanged(let qualityChange):
          if let change = qualityChange {
            "Input format changed, continuing with: \(change.description)"
          } else {
            "Input format changed, continuing with same quality"
          }
        case .paused(let pause):
          "Recording paused: \(pause.reason)"
        case .resumed(let pause, let qualityChange):
          if let change = qualityChange {
            "Recording resumed after \(pause.reason), continuing with: \(change.description)"
          } else {
            "Recording resumed after \(pause.reason)"
          }
        }
      }
    }

    /// What playback does when a personal-listening output — headphones, a
    /// Bluetooth headset, a USB device — disconnects while playing.
    public enum PlaybackRouteDisconnectBehavior: Sendable, Hashable {
      /// Pause, the platform convention: a private listen should not continue
      /// out loud on the built-in speaker.
      case pause
      /// Keep playing on whatever route the system picks next.
      case `continue`
    }

    /// A struct representing the current playback state.
    public struct Playback: Sendable, Hashable, Identifiable, Codable {
      public init(
        id: UUID, file: URL, isPlaying: Bool, time: TimeInterval? = nil, duration: TimeInterval,
      ) {
        self.id = id
        self.file = file
        self.isPlaying = isPlaying
        self.time = time
        self.duration = duration
      }

      /// The unique identifier of the playback instance.
      public let id: UUID
      /// The URL of the file being played.
      public let file: URL
      /// A Boolean value that indicates whether the audio is currently playing.
      public let isPlaying: Bool
      /// The current playback time in seconds.
      ///
      /// Segment playback reports time relative to the segment start; whole-file playback
      /// reports time relative to the file start.
      public let time: TimeInterval?
      /// The duration of the active playback item in seconds.
      ///
      /// Segment playback reports segment duration; whole-file playback reports file duration.
      public let duration: TimeInterval
    }

    // MARK: - Thread Domains

    //
    // AIOEngine uses five distinct thread domains. Each property and method
    // belongs to exactly one domain. Cross-domain communication uses only
    // lock-free primitives (ManagedAtomic, SPSCRingBuffer) or non-blocking
    // snapshot reads.
    //
    // ┌─────────────────────────────────────────────────────────────────┐
    // │                   MainActor (UI / State)                       │
    // │  isRecording, playback, lifecycle state, event publication,    │
    // │  AVAudioSession configuration, lifecycle coordination          │
    // └──────────────────┬──────────────────────┬──────────────────────┘
    //                    │                      │
    //           sync dispatch              async dispatch
    //                    │                      │
    // ┌──────────────────▼──────────────────┐   │
    // │     engineControlQueue (serial)     │   │
    // │  attach, connect, start, stop,      │   │
    // │  prepare, reset, installTap         │   │
    // └──────────────────┬──────────────────┘   │
    //                    │                      │
    //             [AVAudioEngine                │
    //              manages internally]          │
    //                    │                      │
    // ┌──────────────────▼──────────────────┐   │
    // │       Tap Thread (semi-RT)          │   │
    // │  processAudio() — convert, enqueue  │   │
    // │  to SPSC ring buffers               │   │
    // │  Lock-free reads via TapSnapshot    │   │
    // └────┬──────────────────────┬─────────┘   │
    //      │ SPSC                 │ SPSC        │
    //      ▼                      ▼             │
    // ┌────────────┐    ┌──────────────────┐    │
    // │ writerQueue│    │  receiverQueue   │◄───┘
    // │ (file I/O) │    │ (visualization)  │
    // └────────────┘    └──────────────────┘
    //
    // Synchronization mechanisms:
    // - MainActor ↔ engineControlQueue: sync/async dispatch
    // - engineControlQueue ↔ tapThread: TapSnapshot (lock-free), ManagedAtomic
    // - tapThread ↔ writerQueue: SPSCRingBuffer, ManagedAtomic
    // - tapThread ↔ receiverQueue: SPSCRingBuffer, ManagedAtomic

    // MARK: - Stored Properties

    // These SDK types are Sendable. Graph mutations still require the serial
    // engineControlQueue; real-time callbacks exchange data through the rings
    // and atomics described above.
    package let engine = AVAudioEngine()
    package let player = AVAudioPlayerNode()
    // SAFETY: Same queue invariant as `engine` above. The jog source/time-pitch
    // nodes are attached, connected, disconnected, and detached only on
    // engineControlQueue; the source render block communicates with control
    // state via ManagedAtomic fields.
    @ObservationIgnored package nonisolated(unsafe) var jogSourceNode: AVAudioSourceNode?
    @ObservationIgnored package nonisolated(unsafe) var jogTimePitchNode: AVAudioUnitTimePitch?
    package let engineControlQueue = DispatchQueue(label: "AIOEngine.engine-control", qos: .default)

    /// The recording lifecycle, which owns all recording state.
    ///
    /// Held once for the engine's lifetime rather than re-materialised per
    /// call, so `isRecording`, the ring buffers, the writer session and the
    /// capture backend all have exactly one owner.
    package let recording = RecordingLifecycle()

    package var recordingInfrastructure: RecordingInfrastructure { recording.infrastructure }
    @MainActor package var recordingLifecycleState: RecordingLifecycleState {
      recording.lifecycleState
    }
    @MainActor package let audioRecoveryState: AudioRecoveryState
    /// The playback runtime, which owns all playback state. Held once for the
    /// engine's lifetime, like ``recording``.
    package let playbackRuntime = PlaybackRuntime()

    @MainActor package var playbackRuntimeContext: AIOEngine.PlaybackRuntimeContext {
      get { playbackRuntime.context }
      set { playbackRuntime.context = newValue }
    }

    package var playbackState: Synchronized<PlaybackRuntimeState> { playbackRuntime.state }

    // MARK: - Tap Snapshot Lock

    /// Cached snapshot of tap-relevant state for low-contention reads in `processAudio()`.
    ///
    /// Thread Domain: tapCallback (read via `withLockIfAvailable`),
    /// MainActor + engineControl + writerQueue (write via `withLock`).
    ///
    /// This is a separate, lightweight lock dedicated to the tap snapshot. Unlike the
    /// main `state` lock (which protects all of `RecordingState` and can be held during
    /// complex operations), this lock is only held for trivial struct copies —
    /// nanosecond-scale. The tap thread uses `withLockIfAvailable` so it never blocks
    /// if a writer is to be updating concurrently.
    ///
    /// The brief staleness window (one or two tap callbacks using the previous snapshot
    /// if the lock is contended during a write) is safe because the old converter
    /// remains valid until the engine is stopped and restarted.
    package var writerQueue: DispatchQueue {
      recordingInfrastructure.writerQueue
    }

    package var receiverQueue: DispatchQueue {
      recordingInfrastructure.receiverQueue
    }

    package var recordingSampleTimeAtomic: ManagedAtomic<Int64> {
      recordingInfrastructure.recordingSampleTimeAtomic
    }

    package var recordingFirstHostTimeAtomic: ManagedAtomic<UInt64> {
      recordingInfrastructure.recordingFirstHostTimeAtomic
    }

    package var recordingFirstSourceSampleTimeAtomic: ManagedAtomic<Int64> {
      recordingInfrastructure.recordingFirstSourceSampleTimeAtomic
    }

    package var recordingLastHostTimeAtomic: ManagedAtomic<UInt64> {
      recordingInfrastructure.recordingLastHostTimeAtomic
    }

    package var recordingCapturedFrameCountAtomic: ManagedAtomic<UInt64> {
      recordingInfrastructure.recordingCapturedFrameCountAtomic
    }

    package var recordingFirstHostFramePositionAtomic: ManagedAtomic<UInt64> {
      recordingInfrastructure.recordingFirstHostFramePositionAtomic
    }

    package var recordingHostTimeSpanFrameCountAtomic: ManagedAtomic<UInt64> {
      recordingInfrastructure.recordingHostTimeSpanFrameCountAtomic
    }

    /// Reset every value in the segment timing snapshot before a fresh capture starts.
    package nonisolated func resetRecordingTiming() {
      recordingSampleTimeAtomic.store(0, ordering: .relaxed)
      recordingFirstSourceSampleTimeAtomic.store(Int64.min, ordering: .relaxed)
      recordingLastHostTimeAtomic.store(0, ordering: .relaxed)
      recordingCapturedFrameCountAtomic.store(0, ordering: .relaxed)
      recordingFirstHostFramePositionAtomic.store(0, ordering: .relaxed)
      recordingHostTimeSpanFrameCountAtomic.store(0, ordering: .relaxed)
      // Publish the reset last: readers use this as the snapshot's availability sentinel.
      recordingFirstHostTimeAtomic.store(0, ordering: .releasing)
    }

    /// Record one buffer accepted by the file-writer path.
    ///
    /// The capture callback is the sole writer. Keeping this bookkeeping in one lock-free helper
    /// lets microphone capture, system-audio capture, and the deterministic test seam share the
    /// exact same persisted-frame semantics.
    package nonisolated func recordPersistedBufferTiming(
      frameCount: Int,
      hostTime: UInt64?,
      sourceSampleTime: Int64?,
    ) {
      guard frameCount > 0 else { return }
      let capturedBefore = recordingCapturedFrameCountAtomic.load(ordering: .relaxed)
      recordingCapturedFrameCountAtomic.store(
        capturedBefore &+ UInt64(frameCount),
        ordering: .relaxed,
      )
      guard let hostTime else { return }

      let firstHostTime = recordingFirstHostTimeAtomic.load(ordering: .acquiring)
      if firstHostTime == 0 {
        recordingFirstSourceSampleTimeAtomic.store(
          sourceSampleTime ?? Int64.min,
          ordering: .relaxed,
        )
        recordingFirstHostFramePositionAtomic.store(capturedBefore, ordering: .relaxed)
        recordingHostTimeSpanFrameCountAtomic.store(0, ordering: .relaxed)
        recordingLastHostTimeAtomic.store(hostTime, ordering: .releasing)
        recordingFirstHostTimeAtomic.store(hostTime, ordering: .releasing)
      } else {
        let firstPosition = recordingFirstHostFramePositionAtomic.load(ordering: .relaxed)
        recordingHostTimeSpanFrameCountAtomic.store(
          capturedBefore &- firstPosition,
          ordering: .relaxed,
        )
        recordingLastHostTimeAtomic.store(hostTime, ordering: .releasing)
      }
    }

    package var writerDrainTimeout: Duration {
      recordingInfrastructure.writerDrainTimeout
    }

    package var stopDrainTimeout: Duration {
      recordingInfrastructure.stopDrainTimeout
    }

    package var receiverPollingInterval: Duration {
      recordingInfrastructure.receiverPollingInterval
    }

    package var maxBufferSeconds: Double {
      recordingInfrastructure.maxBufferSeconds
    }

    package var tapErrorCode: ManagedAtomic<Int> {
      recordingInfrastructure.tapErrorCode
    }

    package var tapResizeRequestedFrames: ManagedAtomic<Int> {
      recordingInfrastructure.tapResizeRequestedFrames
    }

    /// Engine-teardown serialization sentinel. See
    /// ``RecordingInfrastructure/engineTearingDown`` for the full contract.
    package var engineTearingDown: ManagedAtomic<Bool> {
      recordingInfrastructure.engineTearingDown
    }

    package var metrics: EngineMetrics {
      recordingInfrastructure.metrics
    }

    package var state: Synchronized<RecordingState> {
      recordingInfrastructure.state
    }

    /// A Boolean value that indicates whether the recording lifecycle has
    /// published an active capture.
    @MainActor public package(set) var isRecording: Bool {
      get { recordingLifecycleState.isRecording }
      set { recordingLifecycleState.isRecording = newValue }
    }

    /// How the active recording's format request is being satisfied against
    /// live hardware, or `nil` while nothing is recording.
    ///
    /// This is the observable face of the recording's provenance: the tap's
    /// installed hardware format vs the processing/file format, updated at
    /// start and after every route-change reinstall. A 48 kHz file fed by a
    /// 16 kHz Bluetooth mic is visible here — drive quality indicators off
    /// ``ResolvedCaptureFormat/effectiveSampleRate``, not the file's rate.
    @MainActor public package(set) var activeCaptureFormat: ResolvedCaptureFormat?

    /// Why the active recording is paused, or `nil` while it is capturing (or
    /// nothing is recording). A paused recording still reports
    /// ``isRecording``: the file is open and the contract holds; only frames
    /// are not arriving. See ``RecordingPause``.
    @MainActor public package(set) var recordingPause: RecordingPause?

    /// The `AVAudioEngineConfigurationChange` watch, started at the first
    /// recording bring-up.
    @MainActor @ObservationIgnored package var engineConfigurationObserver: MainActorOwnedWork?

    /// What playback does when the route the listener was using disconnects.
    /// Defaults to the platform convention.
    @MainActor public var playbackRouteDisconnectBehavior: PlaybackRouteDisconnectBehavior = .pause

    /// The immutable authority for shared platform audio-session activation.
    ///
    /// When `nil`, the engine manages the platform session directly.
    public let audioSessionAuthority: (any AudioSessionAuthority)?

    /// The immutable set of collaborators this engine reaches through to touch
    /// real audio hardware. Every field defaults to `nil`, meaning "use the
    /// built-in production path"; tests supply fakes at initialization.
    package let recordingEnvironment: RecordingEnvironment

    #if os(iOS)
      /// The engine's own activation path, used only when
      /// ``audioSessionAuthority`` is `nil`. Tests can inject an activator.
      package let sessionActivator: any AudioSessionActivating
    #endif

    /// Maximum wall-clock time allowed for transient recording readiness to settle.
    public let recordingStartTimeout: Duration

    /// Preferred audio session category/mode/options for this engine.
    @MainActor public var recordingSessionConfiguration: AudioSessionConfiguration {
      get { recordingLifecycleState.recordingSessionConfiguration }
      set { recordingLifecycleState.recordingSessionConfiguration = newValue }
    }
    /// The current playback state, or `nil` if no audio is playing.
    @MainActor public internal(set) var playback: Playback?
    /// The current gesture-scoped jog preview state, or `nil` when no jog is active.
    @MainActor public internal(set) var playbackJog: PlaybackJogSnapshot?
    /// The default interval used to refresh `playback.time` while playback is active.
    ///
    /// This is intentionally coarse by default to avoid excessive observation churn in UI.
    ///
    /// Per-playback overrides can be provided via `play(url:playbackPollingInterval:)`
    /// and `playSegment(..., playbackPollingInterval:)`.
    ///
    /// Values `<= .zero` are treated as `.seconds(0.5)`.
    @MainActor public var defaultPlaybackPollingInterval: Duration {
      get { playbackRuntimeContext.defaultPlaybackPollingInterval }
      set { playbackRuntimeContext.defaultPlaybackPollingInterval = newValue }
    }

    @MainActor var lastPlaybackStateSignature: PlaybackStateSignature? {
      get { playbackRuntimeContext.lastPlaybackStateSignature }
      set { playbackRuntimeContext.lastPlaybackStateSignature = newValue }
    }

    /// A Boolean value that indicates whether the engine is currently playing back audio.
    @MainActor public var isPlayback: Bool {
      playback != nil
    }

    /// A Boolean value that indicates whether the player is currently playing.
    @MainActor public var isPlaying: Bool {
      playback?.isPlaying == true
    }

    @MainActor package var playbackTask: MainActorOwnedWork? {
      get { playbackRuntimeContext.playbackTask }
      set {
        playbackRuntimeContext.playbackTask?.cancelNow()
        playbackRuntimeContext.playbackTask = newValue
      }
    }

    @MainActor package var scrubTask: MainActorOwnedWork? {
      get { playbackRuntimeContext.scrubTask }
      set {
        playbackRuntimeContext.scrubTask?.cancelNow()
        playbackRuntimeContext.scrubTask = newValue
      }
    }

    @MainActor package var jogPreparationTask: MainActorOwnedWork? {
      get { playbackRuntimeContext.jogPreparationTask }
      set {
        playbackRuntimeContext.jogPreparationTask?.cancelNow()
        playbackRuntimeContext.jogPreparationTask = newValue
      }
    }

    @MainActor package var jogPollingTask: MainActorOwnedWork? {
      get { playbackRuntimeContext.jogPollingTask }
      set {
        playbackRuntimeContext.jogPollingTask?.cancelNow()
        playbackRuntimeContext.jogPollingTask = newValue
      }
    }

    package let bufferReceivers: Synchronized<[any BufferReceiver<Float>]> = .init([])
    package let playbackCallbackTasks = AsyncTaskRunner()
    package let recordingCallbackTasks = AsyncTaskRunner()

    package let clock = ContinuousClock()

    package let eventSubject: Subject<AudioIOEvent> = .init()

    /// The unified event stream for the audio engine.
    ///
    /// Subscribe via `for await event in engine.events { ... }` and
    /// pattern-match on the case. The stream is the canonical surface for
    /// engine notifications — engine-level errors, recording lifecycle
    /// (started / completed / failed / interrupted), and playback lifecycle
    /// (state changes and per-tick updates). See ``AudioIOEvent`` for the full
    /// case list.
    public var events: AsyncBroadcaster<AudioIOEvent> {
      eventSubject.broadcaster
    }

    // MARK: - Initialization

    /// Creates a new audio engine.
    ///
    /// - Parameters:
    ///   - audioSessionAuthority: An immutable owner for shared platform
    ///     audio-session activation. Pass `nil` for engine-managed lifecycle.
    ///   - recordingStartTimeout: Maximum time transient recording readiness may
    ///     take to settle. Defaults to two seconds.
    public convenience init(
      audioSessionAuthority: (any AudioSessionAuthority)? = nil,
      recordingStartTimeout: Duration = .seconds(2),
    ) {
      self.init(
        audioSessionAuthority: audioSessionAuthority,
        recordingStartTimeout: recordingStartTimeout,
        recordingEnvironment: .live,
      )
    }

    /// Creates an engine with replaceable audio collaborators.
    ///
    /// Tests use this to drive the real recording lifecycle without a live
    /// audio graph. See ``RecordingEnvironment``.
    package init(
      audioSessionAuthority: (any AudioSessionAuthority)? = nil,
      recordingStartTimeout: Duration = .seconds(2),
      recordingEnvironment: RecordingEnvironment,
    ) {
      self.audioSessionAuthority = audioSessionAuthority
      self.recordingStartTimeout = max(.zero, recordingStartTimeout)
      self.recordingEnvironment = recordingEnvironment
      #if os(iOS)
        sessionActivator =
          recordingEnvironment.sessionActivator ?? NativeAudioSessionActivator()
      #endif
      audioRecoveryState = AudioRecoveryState()
      // Every stored property is initialized, so `self` can be handed over.
      recording.owner = self
      playbackRuntime.owner = self
      runOnEngineControlQueue("engine init player attach") { [engine, player] in
        engine.attach(player)
      }
    }

    // MARK: - Engine Control Queue Helpers

    /// Thread Domain: engineControl
    /// All AVAudioEngine graph mutations must go through these helpers.
    ///
    /// `T` leaves no room for a `throws`, so a raise cannot be handed back to
    /// the caller. It is reported instead — logged and published on
    /// ``AudioIOEvent/error(_:)``, the channel this package documents for
    /// engine-level errors that no `throws` signature can carry — and `work`'s
    /// answer degrades to `fallback`.
    ///
    /// `stage` is the attribution: it is the only thing in the report that says
    /// *which* graph operation raised, so name the operation, not the file.
    ///
    /// Prefer ``runOnEngineControlQueueResult(_:)`` wherever the caller has an
    /// error path. Reach for this one only where it genuinely does not — a
    /// teardown, a state read, an initializer.
    package nonisolated func runOnEngineControlQueue<T>(
      _ stage: String,
      fallingBackTo fallback: T,
      _ work: () -> T,
    ) -> T {
      let (outcome, raised) = engineControlQueue.sync { () -> (T?, ObjCExceptionError?) in
        var value: T?
        let exception = ObjCException.raised { value = work() }
        return (value, exception.map(ObjCExceptionError.init))
      }
      // Reported after leaving the queue, so no subscriber's handler runs while
      // the serial queue is held.
      if let raised {
        reportGraphException(raised, stage: stage)
      }
      return outcome ?? fallback
    }

    /// The `Void` form of ``runOnEngineControlQueue(_:fallingBackTo:_:)``,
    /// where "degrade to a fallback" is just "carry on".
    ///
    /// Every caller of this overload is doing something whose failure it could
    /// not have acted on anyway: attaching a node at init, resetting a graph it
    /// is about to rebuild, or removing a tap during teardown. Continuing past
    /// a reported raise is strictly better than aborting the process, but it is
    /// not error *handling* — a caller that can do something about the failure
    /// belongs on the `Result` form.
    package nonisolated func runOnEngineControlQueue(
      _ stage: String,
      _ work: () -> Void,
    ) {
      runOnEngineControlQueue(stage, fallingBackTo: ()) { work() }
    }

    /// The throwing form, and the package's Objective-C exception boundary for
    /// graph work.
    package nonisolated func runOnEngineControlQueueResult<T>(
      _ work: () throws -> T,
    ) -> Result<T, any Error> {
      engineControlQueue.sync { Self.catchingGraphExceptions(work) }
    }

    /// `Result { try work() }`, extended to the one failure mode Swift cannot
    /// express.
    ///
    /// `AVAudioEngine` reports graph precondition violations by raising an
    /// `NSException`, which travels straight through `Result { try work() }`:
    /// no Swift `catch` sees it, and the process aborts. Catching it here means
    /// every caller that already classifies a `.failure` handles a raise too,
    /// without any call site knowing Objective-C was involved.
    ///
    /// Callers on the recording bring-up path want the finer classification in
    /// ``AIOEngine/prepareGraph(_:)`` and ``AIOEngine/startGraph(_:)``, which
    /// separate a graph that is not ready from an engine that declined to
    /// start. This is the floor under everything else.
    ///
    /// - Important: A raise leaves the graph in an undefined state, so the
    ///   `.failure` is a reason to tear it down and rebuild — which is what
    ///   every caller's failure path already does.
    private nonisolated static func catchingGraphExceptions<T>(
      _ work: () throws -> T,
    ) -> Result<T, any Error> {
      var outcome: Result<T, any Error>?
      let exception = ObjCException.raised {
        outcome = Result { try work() }
      }
      if let exception {
        return .failure(ObjCExceptionError(exception))
      }
      guard let outcome else {
        // Unreachable: `raised(by:)` runs the block synchronously, and it
        // reported no exception, so the assignment above happened.
        return .failure(
          ObjCExceptionError(
            name: ObjCExceptionError.errorDomain,
            reason: "engine-control work neither completed nor raised",
          ),
        )
      }
      return outcome
    }

    /// The asynchronous form of
    /// ``runOnEngineControlQueue(_:fallingBackTo:_:)``, with the same
    /// report-and-degrade contract.
    ///
    /// The continuation is resumed by a single unconditional statement, with
    /// the raise carried out as a value rather than short-circuiting. That
    /// ordering is the point: a `resume` inside the success branch would, once
    /// the exception is caught rather than fatal, leave the awaiting task
    /// suspended forever. Trading a crash for a hang is not an improvement.
    package nonisolated func withEngineControlQueue<T: Sendable>(
      _ stage: String,
      fallingBackTo fallback: T,
      _ work: @escaping @Sendable () -> T,
    ) async -> T {
      let (outcome, raised): (T?, ObjCExceptionError?) = await withCheckedContinuation {
        continuation in
        engineControlQueue.async {
          var value: T?
          let exception = ObjCException.raised { value = work() }
          continuation.resume(returning: (value, exception.map(ObjCExceptionError.init)))
        }
      }
      if let raised {
        reportGraphException(raised, stage: stage)
      }
      return outcome ?? fallback
    }

    /// The `Void` form of ``withEngineControlQueue(_:fallingBackTo:_:)``.
    package nonisolated func withEngineControlQueue(
      _ stage: String,
      _ work: @escaping @Sendable () -> Void,
    ) async {
      await withEngineControlQueue(stage, fallingBackTo: ()) { work() }
    }

    /// Publishes a graph exception the queue helpers could not hand back.
    ///
    /// ``AudioIOEvent/error(_:)`` documents itself as the channel for "an
    /// engine-level error that the engine couldn't surface via a `throws`
    /// signature", which is exactly this. `SessionError` is the right shape for
    /// it too: it is the package's engine-bring-up error, orthogonal to whether
    /// the consumer was recording or playing back, and `.notReady` is transient
    /// — a graph mutation that raised did not happen, and the operation can be
    /// attempted again on a graph that has been rebuilt.
    private nonisolated func reportGraphException(
      _ raised: ObjCExceptionError,
      stage: String,
    ) {
      let details = "engine-control work raised during \(stage): \(raised)"
      log.error("\(details, privacy: .public)")
      eventSubject.send(AudioIOEvent.error(SessionError.notReady(details: details)))
    }

    package nonisolated func withEngineControlQueueResult<T>(
      _ work: @escaping @Sendable () throws -> T,
    ) async -> Result<T, any Error> {
      await withCheckedContinuation { continuation in
        engineControlQueue.async {
          continuation.resume(returning: Self.catchingGraphExceptions(work))
        }
      }
    }

    // MARK: - Atomic State Helpers

    package nonisolated func recordTapError(_ code: TapErrorCode) {
      tapErrorCode.store(code.rawValue, ordering: .relaxed)
    }

    package nonisolated func requestTapResize(frames: Int) {
      guard frames > 0 else { return }
      var current = tapResizeRequestedFrames.load(ordering: .relaxed)
      while frames > current {
        let result = tapResizeRequestedFrames.compareExchange(
          expected: current,
          desired: frames,
          ordering: .acquiringAndReleasing,
        )
        if result.exchanged { break }
        current = result.original
      }
    }

    package nonisolated func consumeTapError() -> TapErrorCode? {
      let raw = tapErrorCode.load(ordering: .relaxed)
      guard raw != 0, let code = TapErrorCode(rawValue: raw) else { return nil }
      tapErrorCode.store(0, ordering: .relaxed)
      return code
    }

    package nonisolated func consumeTapResizeRequest() -> Int {
      tapResizeRequestedFrames.exchange(0, ordering: .acquiringAndReleasing)
    }

    package nonisolated func isDrainSatisfiedByTarget(_ session: WriterSession) -> Bool {
      let target = session.control.targetSampleTime.load(ordering: .relaxed)
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      let stopRequested = session.control.stopRequested.load(ordering: .relaxed)
      return stopRequested && written >= target
    }

    package nonisolated func awaitWriterDrainOutcome(_ session: WriterSession) async
      -> WriterDrainOutcome
    {
      log.info(
        "🧹 awaitWriterDrain start for \(session.fileURL.lastPathComponent, privacy: .public)",
      )
      if Task.isCancelled {
        log.warning(
          "🧹 awaitWriterDrain cancelled for \(session.fileURL.lastPathComponent, privacy: .public)",
        )
        return .timedOut
      }
      if isDrainSatisfiedByTarget(session) {
        return .targetSatisfied
      }

      let timeout = writerDrainTimeout
      let timeoutPolicy = TimeoutPolicy(timeout)
      let outcome = await withTaskGroup(of: WriterDrainOutcome.self) { group in
        group.addTask {
          await session.control.drainSignal.wait()
          return .signaled
        }
        group.addTask {
          await session.control.targetSatisfiedSignal.wait()
          return .targetSatisfied
        }
        group.addTask {
          try? await timeoutPolicy.waitForTimeout()
          return .timedOut
        }

        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
      }

      if outcome == .timedOut, isDrainSatisfiedByTarget(session) {
        return .targetSatisfied
      }
      if outcome == .signaled {
        log.info(
          "🧹 awaitWriterDrain completed for \(session.fileURL.lastPathComponent, privacy: .public)",
        )
      }
      return outcome
    }

    // MARK: - Playback State Helpers

    package struct PlaybackStateSignature: Equatable {
      package let id: UUID?
      package let file: URL?
      package let isPlaying: Bool

      package init(playback: Playback?) {
        id = playback?.id
        file = playback?.file
        isPlaying = playback?.isPlaying ?? false
      }
    }

    @MainActor
    package func setPlayback(_ new: Playback?) {
      let previousSignature = PlaybackStateSignature(playback: playback)

      let updated: Playback? =
        if let playbackInstance = playbackState[locked: \.playbackInstance],
          new?.id == playbackInstance.id
        {
          new
        } else if new == nil {
          nil
        } else {
          // Ignore stale updates for a previous playback instance.
          playback
        }

      playback = updated

      let newSignature = PlaybackStateSignature(playback: playback)
      if previousSignature != newSignature, lastPlaybackStateSignature != newSignature {
        lastPlaybackStateSignature = newSignature
        eventSubject.send(AudioIOEvent.playbackStateChanged(playback))
      }
      eventSubject.send(AudioIOEvent.playbackUpdated(playback))
    }

    @MainActor
    package func setPlaybackJog(_ new: PlaybackJogSnapshot?) {
      playbackJog = new
      eventSubject.send(AudioIOEvent.playbackJogUpdated(new))
    }

    package nonisolated func detachPlaybackJogGraph() {
      if let sourceNode = unsafe jogSourceNode {
        engine.disconnectNodeOutput(sourceNode)
        engine.detach(sourceNode)
        unsafe jogSourceNode = nil
      }
      if let timePitchNode = unsafe jogTimePitchNode {
        engine.disconnectNodeInput(timePitchNode)
        engine.disconnectNodeOutput(timePitchNode)
        engine.detach(timePitchNode)
        unsafe jogTimePitchNode = nil
      }
    }

    package func getPlayback() -> Playback? {
      guard let playbackInstance = playbackState[locked: \.playbackInstance] else { return nil }
      return getPlayback(for: playbackInstance)
    }

    package func getPlayback(for instance: PlaybackInstance) -> Playback {
      guard let nodeTime = player.lastRenderTime,
        let playerTime = player.playerTime(forNodeTime: nodeTime)
      else {
        // The node can't report a live position (paused, or not yet
        // rendering). The node still holds the real position and resumes from
        // it, so report the last observed position rather than snapping back to
        // the segment start. Falls back to the start frame only when no live
        // position has been observed for this instance (fresh play / seek).
        let memo = playbackState[locked: \.lastObservedPlaybackTime]
        let fallbackTime =
          (memo?.instanceID == instance.id ? memo?.time : nil)
          ?? instance.playbackTime(forAbsoluteFrame: instance.startFrame)
        return Playback(
          id: instance.id,
          file: instance.file.url,
          isPlaying: player.isPlaying,
          time: fallbackTime,
          duration: instance.duration,
        )
      }

      let sampleRate = playerTime.sampleRate
      let timeInPlayer = Double(playerTime.sampleTime) / sampleRate
      let renderedFrames = AVAudioFramePosition(
        timeInPlayer * instance.file.processingFormat.sampleRate)
      let currentAbsoluteFrame = instance.startFrame + renderedFrames
      let liveTime = instance.playbackTime(forAbsoluteFrame: currentAbsoluteFrame)
      playbackState[locked: \.lastObservedPlaybackTime] = ObservedPlaybackTime(
        instanceID: instance.id,
        time: liveTime,
      )

      return Playback(
        id: instance.id,
        file: instance.file.url,
        isPlaying: player.isPlaying,
        time: liveTime,
        duration: instance.duration,
      )
    }

    // MARK: - Tap Error Handler Factory

    package func resizeTapConvertedBufferIfNeeded() {
      let requested = consumeTapResizeRequest()
      guard requested > 0 else { return }
      let (existingCapacity, processingFormat) = state.withLock { state in
        (state.tapConvertedBuffer?.frameCapacity, state.tapConverterOutputFormat)
      }
      guard let processingFormat else { return }
      let current = Int(existingCapacity ?? 0)
      guard requested > current else { return }
      let targetCapacity = AVAudioFrameCount(requested)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: targetCapacity,
        )
      else {
        log.error(
          "Failed to resize tap buffer to \(requested, privacy: .public) frames",
        )
        return
      }
      let wrapped = state.withLock { state -> Transferring<TapSnapshot> in
        state.tapConvertedBuffer = buffer
        return Transferring(
          TapSnapshot(
            audioBuffers: state.audioBuffers,
            receiverBuffers: state.receiverBuffers,
            receiverTiming: state.receiverTiming,
            converter: state.tapConverter,
            converterInputFormat: state.tapConverterInputFormat,
            converterOutputFormat: state.tapConverterOutputFormat,
            convertedBuffer: state.tapConvertedBuffer,
          ),
        )
      }
      recordingInfrastructure.tapSnapshotLock.withLock { $0 = wrapped.value }
      log.warning(
        "Resized tap buffer to \(requested, privacy: .public) frames",
      )
    }

    /// Creates a matched pair of tap-error poll/handler closures for writer and receiver loops.
    package func makeTapErrorHandlers() -> (
      poll: @Sendable () -> TapErrorCode?,
      handler: @Sendable (TapErrorCode) -> Void,
    ) {
      let poll: @Sendable () -> TapErrorCode? = { [weak self] in
        self?.consumeTapError()
      }
      let handler: @Sendable (TapErrorCode) -> Void = { [weak self] code in
        guard let self else { return }
        let error: RecordingError =
          switch code {
          case .converterMissing, .bufferTooSmall, .conversionFailed:
            .formatConversionFailed
          }
        resizeTapConvertedBufferIfNeeded()
        let description =
          switch code {
          case .converterMissing: "converterMissing"
          case .bufferTooSmall: "bufferTooSmall"
          case .conversionFailed: "conversionFailed"
          }
        log.error("Tap error: \(description, privacy: .public)")
        eventSubject.send(AudioIOEvent.error(error))
      }
      return (poll, handler)
    }
  }
#endif
