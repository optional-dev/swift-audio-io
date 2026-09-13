// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import Atomics
  package import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
    /// Why and since when a recording is paused.
    ///
    /// A pause is never a stop: the file stays open, the contract holds, and
    /// the engine resumes into the same file when the cause lifts. `since`
    /// is wall-clock time so a caller can represent the gap honestly instead
    /// of fabricating audio for it.
    public struct RecordingPause: Sendable, Hashable {
      public enum Reason: Sendable, Hashable, CustomStringConvertible {
        /// The system took the audio session (a call, Siri, another app).
        case interruption
        /// Media services were lost; capture resumes after they reset.
        case mediaServicesLost
        /// No route can feed the tap, or the tap could not be rebuilt on the
        /// route that exists. Capture resumes when a route can.
        case sourceUnavailable(String)

        public var description: String {
          switch self {
          case .interruption: "Audio session interrupted"
          case .mediaServicesLost: "Media services lost"
          case .sourceUnavailable(let detail): "No usable audio input: \(detail)"
          }
        }
      }

      public let reason: Reason
      public let since: Date

      public init(reason: Reason, since: Date) {
        self.reason = reason
        self.since = since
      }
    }

    /// Pauses the running recording: the tap is removed and the engine
    /// stopped, while the writer, the file, and every staged format stay
    /// exactly as they are. No-op unless recording and not already paused.
    @MainActor
    package func pauseRecording(reason: RecordingPause.Reason) async {
      guard isRecording, recordingPause == nil else { return }
      let pause = RecordingPause(reason: reason, since: Date())
      recordingPause = pause
      cancelRecordingResumeRetry()
      await recording.capture.suspendCapture()
      log.info("Recording paused: \(pause.reason, privacy: .public)")
      eventSubject.send(.recordingInterruption(.paused(pause)))
      // Every cause has a signal that lifts it, and a cadence behind the
      // signal: an `interruptionEnded` that never arrives, or a route that
      // comes back without a notification, must not leave a recording paused
      // forever. Media services are the exception — nothing works until the
      // reset, which is its own signal.
      if case .mediaServicesLost = reason { return }
      scheduleRecordingResumeRetry()
    }

    /// Resumes a paused recording into the same file. A failure keeps the
    /// pause and leaves the retry cadence to try again.
    @MainActor
    package func resumeRecording() async {
      guard isRecording, let pause = recordingPause else { return }
      guard audioRecoveryState.mediaServicesAreAvailable else { return }
      do {
        let change = try await recording.capture.resumeCapture()
        guard isRecording, recordingPause != nil else { return }
        recordingPause = nil
        cancelRecordingResumeRetry()
        activeCaptureFormat = state[locked: \.captureResolution]
        log.info("Recording resumed after: \(pause.reason, privacy: .public)")
        eventSubject.send(.recordingInterruption(.resumed(pause, qualityChange: change)))
      } catch {
        log.info(
          "Recording resume not yet possible (\(pause.reason, privacy: .public)): \(error, privacy: .public)",
        )
        scheduleRecordingResumeRetry()
      }
    }

    @MainActor
    private func scheduleRecordingResumeRetry() {
      guard audioRecoveryState.resumeRetryTask == nil else { return }
      audioRecoveryState.resumeRetryTask = MainActorOwnedWork { [weak self] in
        let sleeper = TaskSleeper()
        var attempt = 0
        while !Task.isCancelled {
          guard let self, self.isRecording, self.recordingPause != nil else { return }
          let backoff = Duration.milliseconds(min(500 << min(attempt, 4), 8_000))
          try? await sleeper.sleep(for: backoff)
          guard !Task.isCancelled, self.isRecording, self.recordingPause != nil else { return }
          attempt += 1
          await self.resumeRecording()
        }
      }
    }

    @MainActor
    package func cancelRecordingResumeRetry() {
      audioRecoveryState.resumeRetryTask?.cancelNow()
      audioRecoveryState.resumeRetryTask = nil
    }

    // MARK: - Engine configuration changes

    /// Watches `AVAudioEngineConfigurationChange`: the input node's format
    /// changed under a running graph — a sample-rate change on the same
    /// device, which posts no route change on macOS, or a device that went
    /// away. A running recording reinstalls its tap at the new format (the
    /// contract holds, the source is re-adapted) or pauses if no input is
    /// left. Paused recordings ignore it: the resume path rebuilds anyway.
    @MainActor
    package func startObservingEngineConfigurationChanges() {
      guard engineConfigurationObserver == nil else { return }
      let changes = AsyncSignalStream<Void>(
        source: NotificationCenter.default.notifications(
          named: .AVAudioEngineConfigurationChange,
          object: engine,
        ),
        compactMap: { _ in () },
      )
      engineConfigurationObserver = MainActorOwnedWork { [weak self] in
        for await _ in changes {
          guard let self else { return }
          await self.handleEngineConfigurationChange()
        }
      }
    }

    @MainActor
    private func handleEngineConfigurationChange() async {
      guard isRecording, recordingPause == nil else { return }
      guard
        let (configuration, processingFormat): (RecordingConfiguration, AVAudioFormat) =
          state({
            guard let configuration = $0.recordingConfiguration,
              let processingFormat = configuration.processingFormat
            else {
              return nil
            }
            return (configuration, processingFormat)
          })
      else {
        return
      }
      #if os(macOS)
        if case .systemAudio = configuration.input {
          return
        }
      #endif

      // There is no honest fallback `AVAudioFormat` — a zero-channel one cannot
      // even be constructed — so a graph that raised reports no format at all,
      // and joins the invalid-format branch this read already had.
      let liveFormat = await withEngineControlQueue(
        "live input format read",
        fallingBackTo: nil,
      ) { [self] () -> AVAudioFormat? in
        self.engine.inputNode.inputFormat(forBus: 0)
      }
      guard let liveFormat, liveFormat.channelCount > 0, liveFormat.sampleRate > 0 else {
        await pauseRecording(reason: .sourceUnavailable("Input format became invalid"))
        return
      }
      let tapFormat = state.withLock { $0.tapConverterInputFormat }
      if let tapFormat, tapFormat.isEqual(liveFormat) {
        return
      }
      do {
        let installed = try await reinstallTapAsync(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: true,
          overrideResult: reinstallTapOverrideResult(
            configuration: configuration,
            processingFormat: processingFormat,
          ),
        )
        guard isRecording, recordingPause == nil,
          !engineTearingDown.load(ordering: .sequentiallyConsistent),
          let result = installed
        else {
          return
        }
        applyTapInstallResult(result, processingFormat: processingFormat)
        activeCaptureFormat = state[locked: \.captureResolution]
        let qualityChange = tapFormat.flatMap {
          AudioQualityChange.between($0, result.tapFormat, reason: "Input format changed")
        }
        eventSubject.send(.recordingInterruption(.captureFormatChanged(qualityChange: qualityChange)))
      } catch {
        await pauseRecording(reason: .sourceUnavailable("Reconfiguration failed: \(error)"))
      }
    }
  }

  extension AIOEngine.AudioQualityChange {
    /// The change between two tap formats, or `nil` when neither the channel
    /// count nor the sample rate moved.
    package static func between(
      _ old: AVAudioFormat,
      _ new: AVAudioFormat,
      reason: String,
    ) -> AIOEngine.AudioQualityChange? {
      let channelsChanged = old.channelCount != new.channelCount
      let sampleRateChanged = abs(old.sampleRate - new.sampleRate) > 1
      guard channelsChanged || sampleRateChanged else { return nil }
      return AIOEngine.AudioQualityChange(
        reason: reason,
        previousChannels: old.channelCount,
        currentChannels: new.channelCount,
        previousSampleRate: old.sampleRate,
        currentSampleRate: new.sampleRate,
      )
    }
  }
#endif
