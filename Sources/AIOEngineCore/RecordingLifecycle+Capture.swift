// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import Atomics
  package import AVFoundation
  import Foundation
  import os
  package import Tools

  private let log = SystemLog.make()

  extension RecordingLifecycle {
    package var capture: Capture {
      Capture(owner: owner)
    }

    package struct Capture {
      static let currentMaximumRecordingChannelCount = 32

      let owner: AIOEngine

      #if os(macOS)
        /// Graph-preparation path for system audio: validate, create the Core Audio backend and
        /// converter artifacts, and stage state — without starting capture (that
        /// happens in `startRecording`). Keeps the shared file/writer/receiver
        /// machinery identical to the microphone path.
        ///
        /// Runs off the main actor; the caller performs `@MainActor` failure cleanup
        /// and returns the typed error when this throws.
        private nonisolated func prepareSystemAudioGraph(
          configuration: RecordingConfiguration,
          systemInput: SystemAudioRecordingInput,
          inputs: PreparationInputs,
        ) throws(RecordingError) {
          // System audio is mono/stereo only — reject early, before touching the HAL.
          let requestedChannels = systemInput.format.channels.count
          guard requestedChannels >= 1, requestedChannels <= 2 else {
            throw RecordingError.unsupportedChannelCount(requested: requestedChannels, maximum: 2)
          }
          try validateEncoderCompatibility(for: configuration)
          if configuration.requiresSampleRateResolution {
            try validateUnresolvedConfiguration(configuration)
          } else {
            guard configuration.processingFormat != nil else {
              throw RecordingError.invalidConfiguration(details: "(processing format)")
            }
          }

          owner.runOnEngineControlQueue("system audio bring-up reset") { [weak owner] in
            guard let owner else { return }
            // Clear the teardown sentinel from on the serial queue, mirroring the
            // microphone preparation path. System audio has no AVAudioEngine tap, but the
            // shared sentinel must be reset for any subsequent reinstall path.
            owner.engineTearingDown.store(false, ordering: .sequentiallyConsistent)
            unsafe owner.player.stop()
          }

          owner.resetRecordingTiming()

          let session: CoreAudioProcessTapSession
          do throws(RecordingError) {
            session = try CoreAudioProcessTapSession(
              input: systemInput,
              capacitySeconds: owner.maxBufferSeconds,
            )
          } catch {
            // The awaited start caller performs the remaining failure cleanup.
            throw error
          }

          do throws(RecordingError) {
            // Resolve a `.hardware` request against the process tap's stream
            // format — the system-audio equivalent of the input node's route
            // read. `.exact` requests resolve to themselves.
            let sourceSampleRate = session.sourceFormat.sampleRate
            guard sourceSampleRate > 0 else {
              throw RecordingError.session(
                .notReady(details: "System-audio tap reported no sample rate"),
              )
            }
            let (resolvedConfiguration, sampleRateSubstitution) =
              configuration.resolvedWithSubstitution(
                hardwareSampleRate: SampleRate(sourceSampleRate),
              )
            if let sampleRateSubstitution {
              owner.recordCaptureSubstitution(sampleRateSubstitution)
            }
            guard let processingFormat = resolvedConfiguration.processingFormat else {
              throw RecordingError.invalidConfiguration(details: "(processing format)")
            }

            let sampleRate = Int(processingFormat.sampleRate)
            let channelCount = Int(processingFormat.channelCount)
            let artifacts = try owner.makeTapConversionArtifacts(
              inputFormat: session.sourceFormat,
              processingFormat: processingFormat,
              tapBufferSize: AVAudioFrameCount(session.maxIOFrames),
            )

            let audioBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
            let receiverBuffers = makeAudioBuffers(
              sampleRate: sampleRate, channelCount: channelCount)
            let timingCapacity = max(
              64,
              Int(ceil(Double(sampleRate) / Double(max(1, session.maxIOFrames)))) * 4,
            )
            let receiverTiming = SPSCRingBuffer<TimingPacket>(capacity: timingCapacity)

            let (url, protection): (URL, OutputFileProtection?) = try owner.resolveOutputURL(
              for: configuration,
              allowExplicitFile: true,
            )
            let outputExistedBeforeStart = FileManager().fileExists(atPath: url.path)
            let writer: any RecordingFileWriter
            do throws(RecordingError) {
              writer = try owner.makeRecordingWriter(
                url: url,
                configuration: resolvedConfiguration,
                writerBackend: inputs.writerBackend,
              )
            } catch {
              if !outputExistedBeforeStart {
                try? FileManager().removeItem(at: url)
              }
              throw error
            }
            owner.applyFileProtectionIfNeeded(protection, to: url)

            // The sink runs on the non-realtime pump queue and feeds the shared
            // processAudio path; processingFormat is immutable here.
            let processingFormatBox = Transferring(processingFormat)
            let backend: CoreAudioSystemAudioBackend
            do {
              backend = try CoreAudioSystemAudioBackend(session: session) {
                [weak owner] buffer, time in
                guard let owner else { return }
                owner.recording.capture.processAudio(
                  buffer: buffer,
                  time: time,
                  to: processingFormatBox.value,
                )
              }
            } catch {
              writer.close()
              if !outputExistedBeforeStart {
                try? FileManager().removeItem(at: url)
              }
              throw error
            }

            let snapshot = owner.state { state -> Transferring<TapSnapshot> in
              state.recordingWriter = writer
              state.recordingURL = url
              state.recordingOutputWasCreatedByStart = !outputExistedBeforeStart
              state.audioBuffers = audioBuffers
              state.receiverBuffers = receiverBuffers
              state.receiverTiming = receiverTiming
              state.recordingConfiguration = resolvedConfiguration
              state.requestedRecordingConfiguration = configuration
              state.captureResolution = ResolvedCaptureFormat(
                hardware: InputConfiguration(
                  sampleRate: SampleRate(session.sourceFormat.sampleRate),
                  channels: ChannelCount(platform: session.sourceFormat.channelCount),
                ),
                processing: InputConfiguration(
                  sampleRate: SampleRate(processingFormat.sampleRate),
                  channels: ChannelCount(platform: processingFormat.channelCount),
                ),
                substitutions: state.captureSubstitutions,
              )
              state.tapConverter = artifacts.converter
              state.tapConverterInputFormat = artifacts.inputFormat
              state.tapConverterOutputFormat = processingFormat
              state.tapConvertedBuffer = artifacts.convertedBuffer
              state.captureBackend = backend
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
            owner.recordingInfrastructure.tapSnapshotLock.withLock { $0 = snapshot.value }
          } catch {
            // Free the locally-created capture session; the awaited start caller
            // performs the remaining engine-state cleanup.
            session.cleanup()
            throw error
          }
        }
      #endif

      /// The main-actor-isolated values the off-main preparation path needs, captured on
      /// the main actor by the caller and handed to ``prepareRecordingGraph(configuration:inputs:)``.
      ///
      /// `AudioSessionConfiguration` and `WriterBackend` are `Sendable`. The
      /// `@MainActor` audio-session authority is invoked before this value crosses
      /// to the off-main path.
      struct PreparationInputs: Sendable {
        let sessionConfiguration: AudioSessionConfiguration
        let writerBackend: WriterBackend
        let alreadyActive: Bool
        /// The result of an injected ``TapInstalling``, pre-resolved on the main
        /// actor so nonisolated graph preparation can honour the seam without
        /// invoking a `@MainActor` method off-main. `nil` whenever the engine
        /// uses the real `AVAudioEngine` graph, which is every production path.
        let reinstallTapOverrideResult: Transferring<Result<TapInstallResult, RecordingError>>?
        /// A `.hardware` request resolved against the injected installer's
        /// advertised format, pre-computed on the main actor for the same
        /// reason as `reinstallTapOverrideResult`. `nil` on every production
        /// path — bring-up then resolves against the live engine instead.
        let seamResolvedConfiguration: RecordingConfiguration?

        init(
          sessionConfiguration: AudioSessionConfiguration,
          writerBackend: WriterBackend,
          alreadyActive: Bool,
          reinstallTapOverrideResult: Transferring<Result<TapInstallResult, RecordingError>>? = nil,
          seamResolvedConfiguration: RecordingConfiguration? = nil,
        ) {
          self.sessionConfiguration = sessionConfiguration
          self.writerBackend = writerBackend
          self.alreadyActive = alreadyActive
          self.reinstallTapOverrideResult = reinstallTapOverrideResult
          self.seamResolvedConfiguration = seamResolvedConfiguration
        }
      }

      /// Captures the main-actor-isolated ``PreparationInputs`` (including any
      /// pre-resolved injected tap install) for the given configuration.
      @MainActor
      func makePreparationInputs(
        configuration: RecordingConfiguration,
        alreadyActive: Bool,
      ) -> PreparationInputs {
        // A `.hardware` request resolves against the injected installer when
        // one is present and knows its format, so the seam's install result —
        // which needs a concrete processing format — can be pre-computed
        // exactly like the exact-rate path.
        var effectiveConfiguration = configuration
        var seamResolvedConfiguration: RecordingConfiguration?
        if configuration.requiresSampleRateResolution,
          let installer = owner.recordingEnvironment.tapInstaller,
          let hardwareFormat = installer.hardwareInputFormat,
          hardwareFormat.sampleRate > 0
        {
          let (resolved, substitution) = configuration.resolvedWithSubstitution(
            hardwareSampleRate: SampleRate(hardwareFormat.sampleRate),
          )
          if let substitution {
            owner.recordCaptureSubstitution(substitution)
          }
          effectiveConfiguration = resolved
          seamResolvedConfiguration = resolved
        }
        let overrideResult = effectiveConfiguration.processingFormat.flatMap { processingFormat in
          owner.reinstallTapOverrideResult(
            configuration: effectiveConfiguration,
            processingFormat: processingFormat,
          )
        }
        var sessionConfiguration = owner.recordingSessionConfiguration
        if let audioSessionAuthority = owner.audioSessionAuthority {
          sessionConfiguration.mode =
            audioSessionAuthority.recordingUsesMeasurementMode ? .measurement : .default
        }
        return PreparationInputs(
          sessionConfiguration: sessionConfiguration,
          writerBackend: owner.recordingLifecycleState.writerBackend,
          alreadyActive: alreadyActive,
          reinstallTapOverrideResult: overrideResult,
          seamResolvedConfiguration: overrideResult != nil ? seamResolvedConfiguration : nil,
        )
      }

      /// Cheap, side-effect-free validation of a recording configuration.
      ///
      /// Runs *before* the audio-session authority is activated, so an invalid
      /// configuration never activates the session or emits `recordingFailed`.
      /// Mirrors the guards performed at the top of ``prepareRecordingGraph`` /
      /// ``prepareSystemAudioGraph``; those re-run cheaply and remain authoritative.
      /// Original error types are preserved.
      nonisolated func validateRecordingConfiguration(
        _ configuration: RecordingConfiguration,
      ) throws(RecordingError) {
        #if os(macOS)
          if case .systemAudio(let systemInput) = configuration.input {
            // System audio is mono/stereo only — reject early, before the HAL.
            let requestedChannels = systemInput.format.channels.count
            guard requestedChannels >= 1, requestedChannels <= 2 else {
              throw RecordingError.unsupportedChannelCount(requested: requestedChannels, maximum: 2)
            }
            try validateEncoderCompatibility(for: configuration)
            if configuration.requiresSampleRateResolution {
              try validateUnresolvedConfiguration(configuration)
              return
            }
            guard configuration.processingFormat != nil else {
              throw RecordingError.invalidConfiguration(details: "(processing format)")
            }
            return
          }
        #endif
        try validateRecordingChannelCapacity(for: configuration)
        try validateEncoderCompatibility(for: configuration)

        if configuration.requiresSampleRateResolution {
          // The rate arrives when bring-up observes the route; check
          // everything decidable without it. The resolved configuration
          // re-runs the full checks below inside `prepareRecordingGraph`.
          try validateUnresolvedConfiguration(configuration)
          return
        }

        guard let processingFormat = configuration.processingFormat else {
          throw RecordingError.invalidConfiguration(details: "(processing format)")
        }

        let sampleRate = Int(processingFormat.sampleRate)
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
          throw RecordingError.session(
            .notReady(details: "Invalid format: \(sampleRate)Hz, \(channelCount)ch"),
          )
        }
        guard sampleRate < Int.max / channelCount / 2 else {
          throw RecordingError.hardwareNotSupported
        }
        try validateRecordingChannelCapacity(channelCount: channelCount)
      }

      /// The static half of validating a `.hardware` request: output encoding
      /// and channel count, everything decidable before a route is observed.
      private nonisolated func validateUnresolvedConfiguration(
        _ configuration: RecordingConfiguration,
      ) throws(RecordingError) {
        let validation = configuration.validate()
        guard validation.isValid else {
          throw RecordingError.invalidConfiguration(details: validation.description)
        }
      }

      /// Materializes the exact configuration bring-up proceeds with.
      ///
      /// `.exact` requests return unchanged. `.hardware` resolves against the
      /// injected installer's pre-computed answer when the test seam is
      /// active, and otherwise against the input node's live format. A route
      /// that reports no rate is a transient readiness failure — the start
      /// deadline loop retries it like any other settling-route condition.
      private nonisolated func resolveConfiguration(
        _ configuration: RecordingConfiguration,
        inputs: PreparationInputs,
      ) throws(RecordingError) -> RecordingConfiguration {
        guard configuration.requiresSampleRateResolution else { return configuration }
        if let seamResolved = inputs.seamResolvedConfiguration {
          return seamResolved
        }
        guard let hardwareSampleRate = owner.readHardwareInputSampleRate() else {
          throw RecordingError.session(
            .notReady(details: "Input hardware reported no sample rate to resolve against"),
          )
        }
        let (resolved, substitution) = configuration.resolvedWithSubstitution(
          hardwareSampleRate: SampleRate(hardwareSampleRate),
        )
        if let substitution {
          owner.recordCaptureSubstitution(substitution)
        }
        log.info(
          "resolved .hardware request to \(resolved.requestedFormat.sampleRate, privacy: .public) (hardware: \(hardwareSampleRate, privacy: .public) Hz)",
        )
        return resolved
      }

      /// Nonisolated preparation core. Performs all blocking bring-up work — audio
      /// session configuration, engine-control-queue graph mutations, buffer
      /// allocation, and file open — without touching the main actor.
      ///
      /// The caller is responsible for `@MainActor` failure cleanup and typed
      /// error propagation; this function never publishes lifecycle events.
      /// `@concurrent` for the same reason ``RecordingLifecycle/attemptRecordingStart(configuration:)``
      /// carries it: under `NonisolatedNonsendingByDefault` a plain
      /// `nonisolated async` inherits the caller's actor, and this body must
      /// never run on the main actor.
      @concurrent
      nonisolated func prepareRecordingGraph(
        configuration: RecordingConfiguration,
        inputs: PreparationInputs,
      ) async throws(RecordingError) {
        guard !inputs.alreadyActive else {
          return
        }
        #if os(macOS)
          if case .systemAudio(let systemInput) = configuration.input {
            try prepareSystemAudioGraph(
              configuration: configuration,
              systemInput: systemInput,
              inputs: inputs,
            )
            return
          }
        #endif
        try validateRecordingChannelCapacity(for: configuration)
        try validateEncoderCompatibility(for: configuration)
        if configuration.requiresSampleRateResolution {
          try validateUnresolvedConfiguration(configuration)
        } else {
          guard configuration.processingFormat != nil else {
            throw RecordingError.invalidConfiguration(details: "(processing format)")
          }
        }

        // A reconfigure (different already-prepared config) is handled by the caller
        // on the main actor before offloading, so by the time we run here either no
        // config is staged or it matches `configuration`. Identity is the
        // *request*: a `.hardware` request that resolved to 48 kHz is still
        // "already prepared" when the same request arrives again.
        if let existing = owner.state.withLock({
          $0.requestedRecordingConfiguration ?? $0.recordingConfiguration
        }) {
          if configuration == existing {
            log.info("recording graph already prepared")
            owner.resetRecordingTiming()
            return
          }
        }

        owner.state[locked: \.captureBackend] =
          owner.recordingEnvironment.makeCaptureBackend?(configuration.input, owner)
          ?? MicrophoneCaptureBackend(owner: owner)

        owner.runOnEngineControlQueue("recording graph reset") { [weak owner] in
          guard let owner else { return }
          // Clear the teardown sentinel from *on* the serial queue. FIFO ordering
          // means any reinstall a prior teardown superseded was enqueued ahead of
          // this block and already observed `engineTearingDown == true`, so
          // clearing here cannot resurrect a stale reinstall onto this fresh
          // bring-up (the ABA window a main-actor clear would reopen).
          owner.engineTearingDown.store(false, ordering: .sequentiallyConsistent)
          owner.player.stop()
          owner.engine.stop()
          owner.engine.reset()
          if !owner.engine.attachedNodes.contains(owner.player) {
            owner.engine.attach(owner.player)
          }
        }

        log.info("preparing recording graph with config: \(configuration, privacy: .public)")
        do throws(SessionError) {
          try await owner.recording.configureAudioSession(
            for: configuration,
            sessionConfiguration: inputs.sessionConfiguration,
          )
        } catch let sessionError {
          throw RecordingError.session(sessionError)
        }

        // Resolve a `.hardware` request against the live route, now that the
        // session is configured and active. `.exact` requests resolve to
        // themselves, so this is one code path, not a fork. The resolved
        // configuration owns all format math from here on; the request is
        // stored alongside it for identity checks and restarts.
        let resolvedConfiguration = try resolveConfiguration(configuration, inputs: inputs)
        try validateEncoderCompatibility(for: resolvedConfiguration)

        guard let processingFormat = resolvedConfiguration.processingFormat else {
          throw RecordingError.invalidConfiguration(details: "(processing format)")
        }

        let sampleRate = Int(processingFormat.sampleRate)
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
          throw RecordingError.session(
            .notReady(details: "Invalid format: \(sampleRate)Hz, \(channelCount)ch"),
          )
        }
        guard sampleRate < Int.max / channelCount / 2 else {
          throw RecordingError.hardwareNotSupported
        }
        try validateRecordingChannelCapacity(channelCount: channelCount)

        owner.resetRecordingTiming()

        guard
          let tapResult = try owner.reinstallTap(
            configuration: resolvedConfiguration,
            processingFormat: processingFormat,
            stopEngine: false,
            overrideResult: inputs.reinstallTapOverrideResult,
          )
        else {
          // Defensive: the reset block above cleared `engineTearingDown` on the
          // same serial queue immediately before this reinstall, so a fresh preparation
          // can never actually be superseded. Throw rather than build a
          // half-tapped graph; this aborts preparation before any further state is
          // staged. The awaited start's off-main `do/catch` around `prepareRecordingGraph`
          // runs `hardStop()` and rethrows.
          log.error(
            "prepareRecordingGraph tap reinstall superseded by teardown; aborting preparation")
          throw RecordingError.engineError
        }

        // The contract is `channelCount`; the tap delivers whatever the route
        // has. A narrower route is replicated into the contract by the
        // converter's channel map, a wider one downmixed — neither is a
        // reason not to start. The mapping is visible in the provenance.
        let channelAdaptation = RecordingInputChannelContract.adaptation(
          requested: channelCount,
          actual: Int(tapResult.tapFormat.channelCount),
        )
        log.info("capture channel adaptation: \(channelAdaptation, privacy: .public)")

        let audioBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
        let receiverBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
        let timingCapacity = max(
          64,
          Int(ceil(Double(sampleRate) / Double(tapResult.tapConfiguration.bufferSize))) * 4,
        )
        let receiverTiming = SPSCRingBuffer<TimingPacket>(capacity: timingCapacity)

        let (url, protection): (URL, OutputFileProtection?) = try owner.resolveOutputURL(
          for: resolvedConfiguration,
          allowExplicitFile: true,
        )
        let outputExistedBeforeStart = FileManager().fileExists(atPath: url.path)
        let writer: any RecordingFileWriter
        do {
          writer = try owner.makeRecordingWriter(
            url: url,
            configuration: resolvedConfiguration,
            writerBackend: inputs.writerBackend,
          )
        } catch {
          if !outputExistedBeforeStart {
            try? FileManager().removeItem(at: url)
          }
          throw error
        }
        owner.applyFileProtectionIfNeeded(protection, to: url)

        owner.state {
          $0.recordingWriter = writer
          $0.recordingURL = url
          $0.recordingOutputWasCreatedByStart = !outputExistedBeforeStart
          $0.audioBuffers = audioBuffers
          $0.receiverBuffers = receiverBuffers
          $0.receiverTiming = receiverTiming
          $0.recordingConfiguration = resolvedConfiguration
          $0.requestedRecordingConfiguration = configuration
        }
        owner.applyTapInstallResult(tapResult, processingFormat: processingFormat)
      }

      package func makeAudioBuffers(
        sampleRate: Int,
        channelCount: Int,
      ) -> [SPSCRingBuffer<Float>] {
        precondition(
          channelCount <= Self.currentMaximumRecordingChannelCount,
          "Recording channel count \(channelCount) exceeds current runtime capacity \(Self.currentMaximumRecordingChannelCount). Validate before allocating buffers.",
        )
        let capacity = max(1, Int(Double(sampleRate) * owner.maxBufferSeconds))
        return (0..<channelCount).map { _ in
          SPSCRingBuffer<Float>(capacity: capacity)
        }
      }

      package func validateRecordingChannelCapacity(
        channelCount: Int,
      ) throws(RecordingError) {
        try validateRecordingChannelCapacity(
          channelCount: channelCount,
          maximum: Self.currentMaximumRecordingChannelCount,
        )
      }

      package func validateRecordingChannelCapacity(
        for configuration: RecordingConfiguration,
      ) throws(RecordingError) {
        try validateRecordingChannelCapacity(
          channelCount: configuration.requestedFormat.channels.count,
          maximum: min(
            Self.currentMaximumRecordingChannelCount,
            configuration.outputConfiguration.fileFormat.maximumRecordingChannelCount,
          ),
        )
      }

      private func validateRecordingChannelCapacity(
        channelCount: Int,
        maximum: Int,
      ) throws(RecordingError) {
        guard channelCount > 0 else {
          throw RecordingError.invalidConfiguration(
            details: "Channel count must be at least 1.",
          )
        }
        guard channelCount <= maximum else {
          throw RecordingError.unsupportedChannelCount(
            requested: channelCount,
            maximum: maximum,
          )
        }
      }

      nonisolated func validateEncoderCompatibility(
        for configuration: RecordingConfiguration,
      ) throws(RecordingError) {
        let fileFormat = configuration.outputConfiguration.fileFormat
        guard fileFormat == .aac || fileFormat == .adts else { return }

        // A .hardware request has no rate to check yet; resolution clamps to
        // an encodable rate by construction, and the resolved configuration
        // passes back through here.
        guard let sampleRate = configuration.requestedFormat.exactSampleRate?.hz else { return }
        guard fileFormat.supportsEncodedSampleRate(sampleRate) else {
          throw RecordingError.unsupportedEncodedSampleRate(
            fileFormat: fileFormat,
            sampleRate: sampleRate,
            supportedSampleRates: FileFormat.aacCompatibleSampleRates,
          )
        }
      }

      @MainActor
      func reconfigureTapForIntervalChange(
        configuration: RecordingConfiguration,
      ) async throws(RecordingError) {
        guard let processingFormat = owner.state.withLock({ $0.tapConverterOutputFormat }) else {
          return
        }

        let installed = try await owner.reinstallTapAsync(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: false,
          overrideResult: owner.reinstallTapOverrideResult(
            configuration: configuration,
            processingFormat: processingFormat,
          ),
        )

        // Post-await liveness re-check (same rationale as the route-change
        // handlers): a stop may have completed (`isRecording` false) or begun
        // (`engineTearingDown` true) while the reinstall was suspended on the
        // engine-control queue. `Task.isCancelled` short-circuits a body whose
        // scheduling `tapIntervalReconfigureTask` was cancelled by a stop/teardown
        // (`cleanUp`) — making that cancellation effective rather than advisory. A
        // `nil` result is the in-queue guard having bailed. In any of these, the
        // stop owns the graph — apply nothing.
        guard !Task.isCancelled,
          owner.isRecording,
          !owner.engineTearingDown.load(ordering: .sequentiallyConsistent),
          let result = installed
        else {
          log.info("Tap interval reconfigure superseded by teardown; skipping")
          return
        }
        owner.applyTapInstallResult(result, processingFormat: processingFormat)
        // The reinstall refreshed the staged provenance; mirror it into the
        // observable, exactly like the route-change handler — the live format
        // read can surface a hardware change this reinstall happened to catch.
        owner.activeCaptureFormat = owner.state[locked: \.captureResolution]

        log.info(
          "Updated tap interval to \(configuration.tapInterval, privacy: .public) (bufferSize: \(result.tapConfiguration.bufferSize, privacy: .public) frames)",
        )
      }

      /// Removes the input tap and stops the engine while keeping the writer,
      /// the file, and every staged format: the recording is paused, not
      /// stopped. `installedTapBus` is cleared so a later stop does not try
      /// to remove a tap that is already gone.
      @MainActor
      func suspendCapture() async {
        let tapBus = owner.state.consume(\.installedTapBus)
        if let teardown = owner.recordingEnvironment.engineTeardown {
          teardown()
          return
        }
        let buses = Array(Set([tapBus, 0].compactMap(\.self)))
        await owner.withEngineControlQueue("recording graph teardown") { [owner] in
          for bus in buses {
            owner.engine.inputNode.removeTap(onBus: bus)
          }
          if owner.engine.isRunning {
            owner.engine.stop()
          }
        }
      }

      /// Re-engages the session, reinstalls the tap at the route's current
      /// format, and restarts the engine into the same writer. Returns the
      /// quality change between the tap format before the pause and after.
      @MainActor
      func resumeCapture() async throws(RecordingError) -> AIOEngine.AudioQualityChange? {
        guard
          let (configuration, processingFormat): (RecordingConfiguration, AVAudioFormat) =
            owner.state({
              guard let configuration = $0.recordingConfiguration,
                let processingFormat = configuration.processingFormat
              else {
                return nil
              }
              return (configuration, processingFormat)
            })
        else {
          throw RecordingError.notRecording
        }
        let formatBefore = owner.state.withLock { $0.tapConverterInputFormat }
        do throws(SessionError) {
          try await owner.setAudioSessionDemand(active: true)
        } catch {
          throw RecordingError.session(error)
        }
        let installed = try await owner.reinstallTapAsync(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: true,
          overrideResult: owner.reinstallTapOverrideResult(
            configuration: configuration,
            processingFormat: processingFormat,
          ),
        )
        guard owner.isRecording,
          !owner.engineTearingDown.load(ordering: .sequentiallyConsistent),
          let result = installed
        else {
          throw RecordingError.notRecording
        }
        owner.applyTapInstallResult(result, processingFormat: processingFormat)
        return formatBefore.flatMap {
          AIOEngine.AudioQualityChange.between($0, result.tapFormat, reason: "Resumed")
        }
      }

      @MainActor
      func hardStop() {
        // Raise the teardown sentinel before enqueuing graph teardown so any
        // reinstall that reaches the serial queue after this point bails. Cleared
        // by the next `prepareRecordingGraph` from on the queue. See `engineTearingDown`.
        owner.engineTearingDown.store(true, ordering: .sequentiallyConsistent)
        stopCaptureBackend(mode: .immediate)
        let hasActiveWriter =
          owner.recordingLifecycleState.writerSession != nil
          || !owner.recordingLifecycleState.drainingWriterSessions.isEmpty
        if let current = owner.recordingLifecycleState.writerSession {
          owner.recording.writer.enqueueDrain(for: current)
          owner.recordingLifecycleState.writerSession = nil
        }
        cleanUp(closeFile: !hasActiveWriter)
      }

      @MainActor
      private func stopCaptureBackend(mode: RecordingCaptureStopMode) {
        guard let backend = owner.state[locked: \.captureBackend] else {
          assert(
            owner.state[locked: \.installedTapBus] == nil,
            "A prepared microphone tap must have a capture backend",
          )
          _ = owner.state.consume(\.installedTapBus)
          return
        }
        backend.stop(mode: mode)
      }

      @MainActor
      func gracefulStop() async {
        // Withdraw capture before the first suspension, so route-change or
        // tap-interval work cannot reinstall onto a graph being torn down.
        owner.engineTearingDown.store(true, ordering: .sequentiallyConsistent)
        stopCaptureBackend(mode: .graceful)
        // Apple Swift 6.4 / OS 27 can still propagate cancellation arriving
        // during a shield into task-group children. Keep this one awaited
        // task boundary so caller cancellation cannot end the drain/timeout
        // race early. The group's own cancelAll still stops losing children.
        let cleanup = ActorOwnedWork(inheriting: MainActor.shared) {
          await withTaskCancellationShield { await finishRecording() }
        }
        await cleanup.value
      }

      @MainActor
      private func finishRecording() async {
        log.info("gracefulStop requested")
        log.info("gracefulStop draining writer sessions")
        let stopDrainTimeout = owner.stopDrainTimeout
        let stopDrainTimeoutPolicy = TimeoutPolicy(stopDrainTimeout)
        let drainCompleted = await withTaskGroup(of: Bool.self) { group in
          group.addTask { [self] in
            await owner.recording.writer.stopAndDrainAll(
              notifyOnFailure: false,
            )
            return true
          }
          group.addTask {
            try? await stopDrainTimeoutPolicy.waitForTimeout()
            return false
          }
          let result = await group.next() ?? false
          group.cancelAll()
          return result
        }
        if !drainCompleted {
          let url = owner.state[locked: \.recordingURL]
          let error = WriterDrainTimeoutError(url: url, timeout: stopDrainTimeout)
          log.error("stopAndDrainAllWriterSessions timed out: \(error, privacy: .public)")
          let writer = owner.recording.writer
          writer.cancelAll()
          writer.recordFailure(ErrorContext(error), url: url)
        }
        cleanUp()
        owner.isRecording = false
        log.info("gracefulStop completed")
        await owner.deactivateAudioSessionIfNeeded(reason: "recording stopped")
      }

      @MainActor
      func cleanUp(closeFile: Bool = true) {
        owner.recording.receiver.stop()
        owner.tapErrorCode.store(0, ordering: .relaxed)
        let (writer, backend) = owner.state {
          state -> ((any RecordingFileWriter)?, (any RecordingCaptureBackend)?) in
          defer {
            state.recordingWriter = nil
            state.recordingURL = nil
            state.recordingOutputWasCreatedByStart = false
            state.recordingConfiguration = nil
            state.requestedRecordingConfiguration = nil
            state.captureResolution = nil
            state.audioBuffers = nil
            state.receiverBuffers = nil
            state.receiverTiming = nil
            state.tapConverter = nil
            state.tapConverterInputFormat = nil
            state.tapConverterOutputFormat = nil
            state.tapConvertedBuffer = nil
            state.captureBackend = nil
            state.captureSubstitutions = []
            state.toleratesPreferredInputMismatch = false
          }
          return (state.recordingWriter, state.captureBackend)
        }
        // Single, idempotent teardown point for every capture source.
        backend?.cleanup()
        owner.activeCaptureFormat = nil
        owner.recordingPause = nil
        owner.cancelRecordingResumeRetry()
        owner.recordingInfrastructure.tapSnapshotLock.withLock { $0 = .empty }
        if closeFile {
          writer?.close()
        }
        // Cancel any pending async tap-interval reinstall so it cannot run against
        // the graph this teardown is clearing. The on-queue teardown guard +
        // post-await re-check are the authoritative net; this is early cancellation.
        owner.recordingLifecycleState.tapIntervalReconfigureTask = nil
        owner.playbackTask = nil
      }

      package nonisolated
        func processAudio(
          buffer: AVAudioPCMBuffer,
          time: AVAudioTime?,
          to processingFormat: AVAudioFormat,
        )
      {
        #if DEBUG
          let tapStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let frameLength = buffer.frameLength
        guard frameLength > 0 else { return }

        let snapshot: TapSnapshot
        if let locked = owner.state.withLockIfAvailable({ state in
          Transferring(
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
        }) {
          snapshot = locked.value
          owner.recordingInfrastructure.tapSnapshotLock.withLockIfAvailable { $0 = locked.value }
        } else {
          if let cached = owner.recordingInfrastructure.tapSnapshotLock.withLockIfAvailable({
            Transferring($0)
          }) {
            snapshot = cached.value
          } else {
            return
          }
        }

        let audioBuffers = snapshot.audioBuffers
        let receiverBuffers = snapshot.receiverBuffers
        let timingBuffer = snapshot.receiverTiming
        let converter = snapshot.converter
        let converterInputFormat = snapshot.converterInputFormat
        let converterOutputFormat = snapshot.converterOutputFormat
        let convertedBuffer = snapshot.convertedBuffer
        guard let converter,
          let converterInputFormat,
          let converterOutputFormat,
          formatsCompatible(converterInputFormat, buffer.format),
          formatsCompatible(converterOutputFormat, processingFormat)
        else {
          owner.recordTapError(.converterMissing)
          return
        }

        let frameRatio = processingFormat.sampleRate / buffer.format.sampleRate
        let requestedCapacity = max(
          AVAudioFrameCount(ceil(Double(frameLength) * frameRatio)),
          1,
        )
        guard let convertedBuffer else {
          owner.recordTapError(.converterMissing)
          return
        }
        guard convertedBuffer.frameCapacity >= requestedCapacity else {
          owner.requestTapResize(frames: Int(requestedCapacity))
          owner.recordTapError(.bufferTooSmall)
          return
        }
        convertedBuffer.frameLength = requestedCapacity

        var error: NSError? = nil
        let inputBuffer = Transferring(buffer)
        let status = unsafe converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
          unsafe outStatus.pointee = .haveData
          return inputBuffer.value
        }
        guard status != .error else {
          owner.recordTapError(.conversionFailed)
          return
        }
        guard let audioBuffers else {
          return
        }

        let channelCount = Int(convertedBuffer.format.channelCount)
        let effectiveChannelCount = min(channelCount, audioBuffers.count)
        guard effectiveChannelCount > 0 else { return }
        if channelCount > audioBuffers.count, rtLoggingEnabled {
          log.error(
            "Channel count mismatch: \(channelCount, privacy: .public) vs \(audioBuffers.count, privacy: .public)",
          )
        }
        let convertedFrameLength = Int(convertedBuffer.frameLength)
        let writerAvailable = RecordingLifecycle.Writer.minimumAvailableWriteFrames(
          channelCount: effectiveChannelCount,
          audioBuffers: audioBuffers,
          limit: convertedFrameLength,
        )
        let writerCanWrite = writerAvailable >= convertedFrameLength
        let receiverCanWrite: Bool
        if let receiverBuffers, let timingBuffer {
          let timingHasCapacity = timingBuffer.availableToWrite >= 1
          receiverCanWrite =
            timingHasCapacity
            && RecordingLifecycle.Writer.minimumAvailableWriteFrames(
              channelCount: effectiveChannelCount,
              audioBuffers: receiverBuffers,
              limit: convertedFrameLength,
            ) >= convertedFrameLength
        } else {
          receiverCanWrite = false
        }
        #if DEBUG
          if !writerCanWrite {
            owner.metrics.writerDrops.wrappingIncrement(
              by: Int64(convertedFrameLength),
              ordering: .relaxed,
            )
          }
          if receiverBuffers != nil, !receiverCanWrite {
            owner.metrics.receiverDrops.wrappingIncrement(
              by: Int64(convertedFrameLength),
              ordering: .relaxed,
            )
          }
        #endif

        let processingStartSampleTime = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
        let sourceHostTime: UInt64? =
          (time?.isHostTimeValid ?? false) ? time?.hostTime : nil
        let sourceSampleTime: Int64? =
          (time?.isSampleTimeValid ?? false) ? time.map { Int64($0.sampleTime) } : nil
        let sourceSampleRate: Double? =
          (time?.isSampleTimeValid ?? false) ? time?.sampleRate : nil
        if writerCanWrite || receiverCanWrite {
          for i in 0..<effectiveChannelCount {
            guard let channelData = unsafe convertedBuffer.floatChannelData?[i] else {
              if rtLoggingEnabled {
                log.error("Failed to access channel data for channel \(i, privacy: .public)")
              }
              continue
            }
            if writerCanWrite {
              unsafe audioBuffers[i].write(
                UnsafeBufferPointer(start: channelData, count: convertedFrameLength),
              )
            }
            if receiverCanWrite, let receiverBuffers, i < receiverBuffers.count {
              unsafe receiverBuffers[i].write(
                UnsafeBufferPointer(start: channelData, count: convertedFrameLength),
              )
            }
          }
        }

        if writerCanWrite {
          // Timing describes PCM accepted by the file writer, not callbacks that may have been
          // dropped because the writer ring was full.
          owner.recordPersistedBufferTiming(
            frameCount: convertedFrameLength,
            hostTime: sourceHostTime,
            sourceSampleTime: sourceSampleTime,
          )
        }

        if receiverCanWrite, let receiverTimingBuffer = timingBuffer {
          var packet = TimingPacket(
            startSampleTime: processingStartSampleTime,
            frameCount: convertedFrameLength,
            hostTime: sourceHostTime,
            sourceSampleTime: sourceSampleTime,
            sourceSampleRate: sourceSampleRate,
          )
          _ = withUnsafePointer(to: &packet) { pointer in
            unsafe receiverTimingBuffer.write(UnsafeBufferPointer(start: pointer, count: 1))
          }
        }

        owner.recordingSampleTimeAtomic.wrappingIncrement(
          by: Int64(convertedBuffer.frameLength),
          ordering: .relaxed,
        )
        #if DEBUG
          owner.metrics.tapCallbackCount.wrappingIncrement(ordering: .relaxed)
          let tapElapsed = DispatchTime.now().uptimeNanoseconds &- tapStart
          let previousMax = owner.metrics.tapCallbackMaxNanos.load(ordering: .relaxed)
          if tapElapsed > previousMax {
            owner.metrics.tapCallbackMaxNanos.store(tapElapsed, ordering: .relaxed)
          }
        #endif
      }

      nonisolated
        func formatsCompatible(
          _ lhs: AVAudioFormat,
          _ rhs: AVAudioFormat,
        ) -> Bool
      {
        lhs.commonFormat == rhs.commonFormat
          && lhs.sampleRate == rhs.sampleRate
          && lhs.channelCount == rhs.channelCount
          && lhs.isInterleaved == rhs.isInterleaved
      }

    }
  }
#endif
