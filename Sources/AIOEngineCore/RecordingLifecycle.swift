// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import Atomics
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
    var recordingLifecycle: RecordingLifecycle { recording }
  }

  /// The ordered transition from recording intent through readiness, active
  /// capture, file rotation, and either graceful or immediate stop.
  ///
  /// This is the sole owner of recording state. Callers observe and control it
  /// through ``AIOEngine``, which holds exactly one of these for its lifetime.
  ///
  /// The lifecycle keeps a back-reference to the engine for the things that are
  /// genuinely engine-level rather than recording-level: the `AVAudioEngine`
  /// graph and its control queue, the player node, the event subject, and the
  /// immutable configuration (clock, start timeout, session authority,
  /// recording environment).
  ///
  // SAFETY: the individual stores carry their own synchronization —
  // `infrastructure` is `@unchecked Sendable` with atomics and a lock, and
  // `lifecycleState` is `@MainActor`. This type adds no unsynchronized state
  // of its own beyond the immutable `owner` reference.
  package final class RecordingLifecycle: @unchecked Sendable {
    /// The engine that owns this lifecycle. `unowned` is safe because the
    /// engine holds the lifecycle as a stored `let`, so it always outlives it.
    /// Implicitly unwrapped because the engine must finish initializing its own
    /// stored properties before it can hand `self` over.
    package unowned var owner: AIOEngine!

    /// Queues, atomics, timeouts and the locked ``RecordingState``.
    package let infrastructure = RecordingInfrastructure()

    /// Main-actor-isolated, observable lifecycle state.
    @MainActor package let lifecycleState = RecordingLifecycleState()

    package init() {}

    @MainActor
    package func gracefulStop() async {
      await capture.gracefulStop()
    }

    /// Brings a recording to readiness within the engine's immutable deadline.
    ///
    /// Transient source/session failures are retried behind the internal
    /// readiness port. Terminal failures, timeout, and cancellation are surfaced
    /// only through this typed throw.
    @concurrent
    nonisolated func startRecording(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      let operationID = UUID()
      try await claimStartOperation(operationID)
      var didStart = false
      defer { await finishStartOperation(operationID, didStart: didStart) }
      // A self-contradictory request is reduced, not refused: the container
      // yields to the rate (or, for a caller-named file, the rate to the
      // container), and the change is reported in the capture provenance.
      let (configuration, reduction) = configuration.reducedToEncodable()
      owner.state.withLock {
        $0.captureSubstitutions = reduction.map { [$0] } ?? []
        $0.toleratesPreferredInputMismatch = false
      }

      let readiness: any RecordingStartReadiness =
        if let injected = owner.recordingEnvironment.attemptRecordingStart {
          ClosureRecordingStartReadiness(operation: injected)
        } else {
          PlatformRecordingStartReadiness(owner: owner)
        }

      let startedAt = owner.clock.now
      let timeout = owner.recordingStartTimeout
      let retryPolicy = RetryPolicy(
        maxAttempts: .max,
        delay: .constant(.milliseconds(100)),
      )
      var lastTransientSessionFailure: SessionError?
      // One attempt past the deadline is allowed when the only thing still
      // unsettled is the route switching to the preferred input: that attempt
      // starts on the current input and reports the substitution, because a
      // recording the user asked for is never contingent on a route change.
      var lenientAttemptTaken = false
      let allowsLenientAttempt = { (failure: SessionError) -> Bool in
        if case .preferredInputRouteMismatch = failure, !lenientAttemptTaken {
          return true
        }
        return false
      }

      do {
        while true {
          guard !Task.isCancelled else {
            throw RecordingError.cancelled
          }
          if let lastTransientSessionFailure {
            let elapsed = startedAt.duration(to: owner.clock.now)
            if elapsed >= timeout {
              guard allowsLenientAttempt(lastTransientSessionFailure) else {
                throw RecordingError.startTimedOut(
                  timeout: timeout,
                  lastFailure: lastTransientSessionFailure,
                )
              }
              lenientAttemptTaken = true
              owner.state[locked: \.toleratesPreferredInputMismatch] = true
              log.info(
                "Preferred input has not become the route before the start deadline; starting on the current input",
              )
            }
          }

          do {
            let url = try await readiness.attempt(configuration: configuration)
            guard !Task.isCancelled else {
              await cleanUpCancelledSuccessfulStart()
              throw RecordingError.cancelled
            }
            didStart = true
            return url
          } catch {
            let recordingError = error as? RecordingError ?? .engineError
            if Task.isCancelled || recordingError == .cancelled {
              throw RecordingError.cancelled
            }
            guard case .session(let sessionError) = recordingError, sessionError.isTransient else {
              throw recordingError
            }
            lastTransientSessionFailure = sessionError

            let elapsed = startedAt.duration(to: owner.clock.now)
            guard elapsed < timeout else {
              // Past the deadline: either the lenient attempt is still owed
              // (loop back without sleeping) or the start has failed.
              guard allowsLenientAttempt(sessionError) else {
                throw RecordingError.startTimedOut(
                  timeout: timeout,
                  lastFailure: lastTransientSessionFailure,
                )
              }
              continue
            }

            log.info(
              "Recording readiness unsettled after \(elapsed, privacy: .public): \(sessionError, privacy: .public)",
            )
            do {
              try await retryPolicy.wait(afterFailureCount: 1)
            } catch {
              throw RecordingError.cancelled
            }
          }
        }
      } catch {
        let recordingError = error as? RecordingError ?? .engineError
        throw recordingError
      }
    }

    @MainActor
    private func claimStartOperation(_ operationID: UUID) throws(RecordingError) {
      guard !owner.isRecording else {
        throw RecordingError.alreadyRecording
      }
      guard owner.recordingLifecycleState.startOperationID == nil else {
        throw RecordingError.startInProgress
      }
      owner.recordingLifecycleState.startOperationID = operationID
    }

    @MainActor
    private func finishStartOperation(_ operationID: UUID, didStart: Bool) async {
      guard owner.recordingLifecycleState.startOperationID == operationID else { return }
      owner.recordingLifecycleState.startOperationID = nil
      if !didStart {
        await owner.deactivateAudioSessionIfNeeded(reason: "recording start failed")
      }
    }

    @MainActor
    private func cleanUpCancelledSuccessfulStart() async {
      guard owner.isRecording else { return }
      let outputToRemove = owner.newStartOutputToRemove()
      await capture.gracefulStop()
      if let outputToRemove {
        try? FileManager().removeItem(at: outputToRemove)
      }
    }

    /// Performs one recording bring-up attempt **off the main actor**.
    ///
    /// `@concurrent` is load-bearing: this package enables
    /// `NonisolatedNonsendingByDefault` (SE-0461), under which a plain
    /// `nonisolated async` inherits the caller's actor. This function is awaited
    /// from public and internal lifecycle paths, so without `@concurrent` its
    /// body — including the off-main `prepareRecordingGraph` (audio-session IPC, file open,
    /// ring-buffer allocation) — would run ON the main actor, reintroducing the
    /// recording-start main-thread hang this design exists to prevent. The
    /// genuinely main-isolated work is hopped explicitly via `MainActor.run`
    /// (PREP / PUBLISH / failure) and `withEngineControlQueue*`.
    @concurrent
    nonisolated func attemptRecordingStart(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      #if DEBUG
        // Prove the bring-up runs off the main actor (see the doc comment). The
        // `prepareRecordingGraph` path below cannot assert this itself because it is a
        // synchronous core that cannot perform an actor precondition itself.
        dispatchPrecondition(condition: .notOnQueue(.main))
      #endif
      do {
        // (a) Stop any active player on the engine-control queue (unchanged).
        let shouldStopPlayer = await owner.withEngineControlQueue(
          "player state read before bring-up",
          fallingBackTo: false,
        ) { [weak owner] in
          guard let owner else { return false }
          return owner.player.isPlaying
        }
        if shouldStopPlayer {
          await owner.withEngineControlQueue("player stop before bring-up") { [weak owner] in
            guard let owner, owner.player.isPlaying else { return }
            owner.player.stop()
          }
        }

        // (b) MainActor PREP hop: claim the bring-up window, publish
        // main-isolated teardown/state changes, activate the session, and capture
        // the values off-main graph preparation needs.
        let inputs = try await prepareStart(
          configuration: configuration,
          shouldStopPlayer: shouldStopPlayer,
        )

        do {
          // (c) OFF-MAIN: blocking bring-up + engine/backend start, never on main.
          try await owner.recording.capture.prepareRecordingGraph(
            configuration: configuration,
            inputs: inputs,
          )

          guard !Task.isCancelled else {
            throw RecordingError.cancelled
          }

          guard let backend = owner.state[locked: \.captureBackend] else {
            throw RecordingError.engineError
          }
          try backend.start()
        } catch {
          // (d) Any bring-up/start failure: perform `@MainActor` cleanup, rethrow.
          let outputToRemove = await MainActor.run {
            // Close the bring-up window before tearing down so handlers stop
            // deferring; the failed engine is being torn down here regardless.
            owner.recordingLifecycleState.isStartingRecording = false
            let outputToRemove = owner.newStartOutputToRemove()
            capture.hardStop()
            return outputToRemove
          }
          if let outputToRemove {
            try? FileManager().removeItem(at: outputToRemove)
          }
          throw error
        }

        // (e) MainActor PUBLISH hop: read staged state, validate, emit events,
        // start the writer/receiver loops, and flip `isRecording`.
        //
        // This hop returns a `Result` rather than throwing out of the closure.
        // `MainActor.run` is `rethrows`, and handing it a typed-throws
        // (`throws(RecordingError)`) closure crashes the Swift 6.4 frontend
        // (swiftlang-6.4.0.27.1) in IRGen: "constructing SILType with type that
        // should have been eliminated by SIL lowering". A non-throwing closure plus
        // `Result.get()` is behaviour-identical — `get()` is itself
        // `throws(Failure)`, so the error stays exactly `RecordingError` with no
        // widening — and it compiles.
        let publishOutcome: Result<URL, RecordingError> = await MainActor.run {
          // Close the bring-up window: from here on, teardown/stop paths act
          // inline again (the engine is being published this turn).
          owner.recordingLifecycleState.isStartingRecording = false

          guard !Task.isCancelled else {
            let outputToRemove = owner.newStartOutputToRemove()
            capture.hardStop()
            if let outputToRemove {
              try? FileManager().removeItem(at: outputToRemove)
            }
            return .failure(.cancelled)
          }

          let (
            buffers, recordingWriter, url, receiverBuffers, receiverTiming, stagedConfiguration,
            captureResolution
          ) =
            owner.state {
              (
                $0.audioBuffers, $0.recordingWriter, $0.recordingURL, $0.receiverBuffers,
                $0.receiverTiming, $0.recordingConfiguration, $0.captureResolution
              )
            }
          // The staged configuration is the resolved one — a `.hardware`
          // request has a concrete rate only there, never on the request.
          guard let buffers,
            let processingFormat = (stagedConfiguration ?? configuration).processingFormat,
            let writeWriter = recordingWriter,
            let url
          else {
            let outputToRemove = owner.newStartOutputToRemove()
            capture.hardStop()
            if let outputToRemove {
              try? FileManager().removeItem(at: outputToRemove)
            }
            return .failure(
              .invalidConfiguration(
                details: "state after recording graph preparation was invalid",
              )
            )
          }
          let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
          // Provenance always exists once a tap or system-audio backend is
          // staged; the fallback covers only a hypothetical gap and reports a
          // native (no-conversion) capture at the processing format.
          let capture =
            captureResolution
            ?? ResolvedCaptureFormat(
              hardware: InputConfiguration(
                sampleRate: SampleRate(processingFormat.sampleRate),
                channels: ChannelCount(platform: processingFormat.channelCount),
              ),
              processing: InputConfiguration(
                sampleRate: SampleRate(processingFormat.sampleRate),
                channels: ChannelCount(platform: processingFormat.channelCount),
              ),
            )
          // If a teardown/stop already aborted this bring-up while we were
          // off-main, suppress `recordingStarted` — the reconcile below tears the
          // engine down, so emitting "started" then "failed" would be spurious.
          if !owner.recordingLifecycleState.startAbortRequested {
            owner.eventSubject.send(
              AudioIOEvent.recordingStarted(url: url, format: fileFormat, capture: capture),
            )
          }
          owner.activeCaptureFormat = capture
          // The first file of a capture starts at the origin of the frame
          // domain, which `resetRecordingTiming()` established during graph
          // preparation.
          writer.start(
            flushing: buffers,
            format: processingFormat,
            to: writeWriter,
            startingAt: 0,
          )
          if let receiverBuffers, let receiverTiming {
            receiver.start(
              buffers: receiverBuffers,
              timing: receiverTiming,
              format: processingFormat,
            )
          }
          owner.isRecording = true
          return .success(url)
        }
        let url = try publishOutcome.get()

        // Reconcile an interruption that arrived mid-bring-up. The handler
        // could not tear down the half-built graph, so this attempt owns cleanup
        // and reports a transient readiness failure to the outer deadline.
        let wasAborted = await MainActor.run {
          guard owner.recordingLifecycleState.startAbortRequested else { return false }
          owner.recordingLifecycleState.startAbortRequested = false
          return true
        }
        if wasAborted {
          let outputToRemove = await MainActor.run {
            owner.newStartOutputToRemove()
          }
          await capture.gracefulStop()
          if let outputToRemove {
            try? FileManager().removeItem(at: outputToRemove)
          }
          throw RecordingError.session(
            .notReady(details: "The audio environment changed during recording startup"),
          )
        }
        return url
      } catch let error as RecordingError {
        throw error
      } catch {
        throw .session(.engineStartFailed(error: ErrorContext(error)))
      }
    }

    @MainActor
    private func prepareStart(
      configuration: RecordingConfiguration,
      shouldStopPlayer: Bool,
    ) async throws(RecordingError) -> RecordingLifecycle.Capture.PreparationInputs {
      guard !owner.recordingLifecycleState.isStartingRecording else {
        throw RecordingError.startInProgress
      }
      owner.recordingLifecycleState.isStartingRecording = true
      owner.recordingLifecycleState.startAbortRequested = false
      owner.startObservingEngineConfigurationChanges()

      if shouldStopPlayer || owner.playback != nil {
        owner.playbackState[locked: \.playbackInstance] = nil
        owner.setPlayback(nil)
      }
      owner.recordingLifecycleState.lastWriteFailure = nil
      owner.recordingLifecycleState.lastRecordingConfiguration = configuration

      guard owner.audioRecoveryState.mediaServicesAreAvailable else {
        owner.recordingLifecycleState.isStartingRecording = false
        throw RecordingError.session(
          .notReady(details: "Media services are unavailable"),
        )
      }

      // If a *different* configuration is already prepared, tear it down here on
      // the main actor so nonisolated graph preparation never needs `hardStop()`.
      // Identity is the *request*: the staged resolved copy of a `.hardware`
      // request never equals the request itself, and comparing it would tear
      // down a graph the same request should reuse.
      if let existing = owner.state.withLock({
        $0.requestedRecordingConfiguration ?? $0.recordingConfiguration
      }),
        existing != configuration
      {
        capture.hardStop()
      }

      do throws(RecordingError) {
        try owner.recording.capture.validateRecordingConfiguration(configuration)
        let alreadyActive = owner.isRecording || owner.isPlaying
        if !alreadyActive {
          do throws(SessionError) {
            try await owner.recording.activateAudioSessionAuthority()
          } catch {
            throw RecordingError.session(error)
          }
        }
        guard !Task.isCancelled, !owner.recordingLifecycleState.startAbortRequested else {
          throw RecordingError.cancelled
        }

        return owner.recording.capture.makePreparationInputs(
          configuration: configuration,
          alreadyActive: alreadyActive,
        )
      } catch {
        owner.recordingLifecycleState.isStartingRecording = false
        owner.recordingLifecycleState.startAbortRequested = false
        throw error
      }
    }

    @MainActor
    func updateRecordingTapInterval(_ interval: Duration) {
      guard interval > .zero else { return }

      // Tap interval is a microphone-only concept. Rebuild the configuration with
      // the new interval nested in `MicrophoneRecordingInput`; system-audio
      // configurations have no tap interval, so this is a no-op for them.
      func withUpdatedInterval(_ config: RecordingConfiguration) -> RecordingConfiguration? {
        guard case .microphone(let microphone) = config.input,
          microphone.tapInterval != interval
        else {
          return nil
        }
        return RecordingConfiguration(
          input: .microphone(
            MicrophoneRecordingInput(
              format: microphone.format,
              tapInterval: interval,
              preferredInput: microphone.preferredInput,
            ),
          ),
          outputConfiguration: config.outputConfiguration,
          outputDestination: config.outputDestination,
        )
      }

      guard let currentConfig = owner.state.withLock({ $0.recordingConfiguration }) else {
        // Not yet prepared: fold the interval into the pending configuration if it
        // is a microphone source, otherwise leave it untouched.
        if let pending = owner.recordingLifecycleState.lastRecordingConfiguration,
          let updated = withUpdatedInterval(pending)
        {
          owner.recordingLifecycleState.lastRecordingConfiguration = updated
        }
        return
      }

      guard let updated = withUpdatedInterval(currentConfig) else { return }

      // Both staged configurations carry the interval: the resolved one feeds
      // the reinstall below, and the request must keep matching future
      // identity checks for the same caller intent.
      let updatedRequest = owner.state.withLock { state -> RecordingConfiguration? in
        state.recordingConfiguration = updated
        guard let requested = state.requestedRecordingConfiguration else { return nil }
        let newRequest = withUpdatedInterval(requested) ?? requested
        state.requestedRecordingConfiguration = newRequest
        return newRequest
      }
      owner.recordingLifecycleState.lastRecordingConfiguration = updatedRequest ?? updated

      guard owner.isRecording else { return }

      // Schedule the reinstall off the main thread (it dispatches the graph
      // mutation to the engine-control queue via `reinstallTapAsync`). This API
      // stays synchronous (public signature preserved); the handle is stored in
      // `tapIntervalReconfigureTask` so a stop/teardown cancels a pending
      // reinstall. Scheduling a fresh one cancels any prior in-flight change.
      owner.recordingLifecycleState.tapIntervalReconfigureTask = MainActorOwnedWork {
        [weak owner] in
        guard let owner else { return }
        do {
          try await owner.recording.capture.reconfigureTapForIntervalChange(
            configuration: updated,
          )
        } catch {
          log.warning(
            "Failed to update tap interval to \(interval, privacy: .public): \(error, privacy: .public)",
          )
        }
      }
    }

    @MainActor
    func stopRecording() async throws(RecordingError) -> RecordingCompletion {
      // Pending startup belongs to the caller's start task. The caller withdraws
      // that intent by cancelling the task; stop is valid only after success.
      if owner.recordingLifecycleState.isStartingRecording {
        throw RecordingError.notRecording
      }
      guard let url = owner.state[locked: \.recordingURL], owner.isRecording else {
        throw RecordingError.notRecording
      }
      // Held across the stop: `gracefulStop` clears the lifecycle's reference to
      // the session, but the session is where the drain target — this file's
      // boundary — is recorded.
      let stoppingSession = owner.recordingLifecycleState.writerSession
      await capture.gracefulStop()
      let boundaryFramePosition = drainBoundary(of: stoppingSession)
      let fileExists = FileManager().fileExists(atPath: url.path)
      let fileSize = owner.fileSizeValue(for: url)
      let failure = writer.consumeFailure()
      if !fileExists {
        throw RecordingError.fileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(MissingAudioFileError(url: url)),
        )
      }
      if let size = fileSize, size == 0 {
        throw RecordingError.fileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(EmptyAudioFileError(url: url)),
        )
      }
      if let failure {
        if writer.isDrainTimeout(failure), fileExists, (fileSize ?? 0) > 0 {
          log.warning(
            "⚠️ Writer drain timed out but file exists with data; continuing stop for \(url.lastPathComponent, privacy: .public)",
          )
        } else {
          throw RecordingError.fileFailed(
            operation: .write,
            url: failure.url,
            error: failure.error,
          )
        }
      }
      let finalSize = owner.fileSizeDescription(for: url)
      log.info(
        "✅ Recording stopped: \(url.lastPathComponent, privacy: .public) size=\(finalSize, privacy: .public) frames=\(boundaryFramePosition, privacy: .public)",
      )
      owner.eventSubject.send(AudioIOEvent.recordingCompleted)
      return RecordingCompletion(
        completedURL: url,
        boundaryFramePosition: boundaryFramePosition,
      )
    }

    /// The persisted-frame position the just-completed file was drained to.
    ///
    /// Prefers the target recorded on the writer session, because that is the
    /// value sampled on the path that decided the stop. Falls back to the live
    /// counter only for a session that never reached `prepareDrain` — sound
    /// there because capture has already ended, which is precisely the
    /// condition a rotation cannot rely on.
    @MainActor
    private func drainBoundary(of session: WriterSession?) -> Int64 {
      guard let session, session.control.stopRequested.load(ordering: .relaxed) else {
        return owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
      }
      return session.control.targetSampleTime.load(ordering: .relaxed)
    }

    @MainActor
    func rotateRecordingFile() async throws(RecordingError) -> RecordingRotation {
      try await rotation.rotate()
    }
  }
#endif
