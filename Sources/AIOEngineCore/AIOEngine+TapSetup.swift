// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOSupport
  import Atomics
  package import AVFoundation
  #if os(macOS)
    import CoreAudio
  #endif
  import os
  import Tools

  private let tapSetupLog = SystemLog.make()

  extension AIOEngine {
    /// The input node's current hardware sample rate, read on the
    /// engine-control queue.
    ///
    /// This is the resolution read for a ``RecordingSampleRate/hardware``
    /// request: `prepare()` refreshes the node's cached format from the
    /// current route (the same call ``reinstallTap`` makes before its own
    /// format read), and the rate observed here becomes the recording's exact
    /// processing/file rate. A subsequent route change is absorbed the same
    /// way it is for an exact request — the tap reinstalls and the converter
    /// bridges into the pinned rate.
    package nonisolated func readHardwareInputSampleRate() -> Double? {
      runOnEngineControlQueue("hardware sample-rate read", fallingBackTo: nil) { [weak self] in
        guard let self else { return nil }
        // Materialize the input node *before* preparing. `AVAudioEngine`
        // creates its I/O nodes lazily on first property access, and
        // `AVAudioEngineGraph::Initialize` asserts
        // `inputNode != nullptr || outputNode != nullptr` — raising an
        // Objective-C exception, which no Swift `catch` can intercept, so the
        // process dies. A first `.hardware` bring-up reaches here in exactly
        // that state: preparation has attached only `player`, and nothing on
        // the path has read an I/O node yet. The other `prepare()` sites in
        // this file satisfy the precondition incidentally — ``reinstallTap``
        // removes a tap on `inputNode` first — so this is the one call that
        // has to state it. `reset()` does not de-materialize the node, so the
        // cost is one lazy creation per engine, not per read.
        let inputNode = self.engine.inputNode
        do {
          try self.prepareGraph("hardware sample-rate resolution")
        } catch {
          // A graph that will not initialize is exactly what this read already
          // reports as "no rate": the caller raises `.notReady`, and the start
          // deadline loop retries it.
          return nil
        }
        let sampleRate = inputNode.inputFormat(forBus: 0).sampleRate
        return sampleRate > 0 ? sampleRate : nil
      }
    }

    /// `engine.prepare()`, with the graph's Objective-C preconditions turned
    /// into a typed, retryable failure instead of a process abort.
    ///
    /// `AVAudioEngineGraph::Initialize` asserts four conditions — that the I/O
    /// nodes exist, and that each one is initialized — and reports a violation
    /// by raising, which no Swift `catch` can intercept. Every one of them
    /// describes a graph that is not *ready* rather than a request that is
    /// wrong, so they map to `.notReady`: transient, and retried by the start
    /// deadline loop like any other settling-route condition.
    ///
    /// Must run on the engine-control queue, like every other graph mutation
    /// in this file.
    nonisolated func prepareGraph(_ stage: String) throws(RecordingError) {
      guard let exception = ObjCException.raised(by: { engine.prepare() }) else { return }
      let raised = ObjCExceptionError(exception)
      tapSetupLog.error(
        "AVAudioEngine.prepare() raised during \(stage, privacy: .public): \(raised.description, privacy: .public)",
      )
      throw RecordingError.session(
        .notReady(details: "engine.prepare() raised during \(stage): \(raised)"),
      )
    }

    /// `engine.start()`, accounting for both ways it can fail: the Swift error
    /// it throws, and the Objective-C exception the graph raises.
    ///
    /// The two are not the same failure. A thrown error is the engine
    /// declining to start and stays `.engineStartFailed`; a raise is
    /// ``prepareGraph(_:)``'s condition set reached through `start()`'s own
    /// initialize, and is transient for the same reason.
    ///
    /// Must run on the engine-control queue.
    nonisolated func startGraph(_ stage: String) throws(RecordingError) {
      var startError: (any Error)?
      let exception = ObjCException.raised {
        do {
          try engine.start()
        } catch {
          startError = error
        }
      }
      if let exception {
        let raised = ObjCExceptionError(exception)
        tapSetupLog.error(
          "AVAudioEngine.start() raised during \(stage, privacy: .public): \(raised.description, privacy: .public)",
        )
        throw RecordingError.session(
          .notReady(details: "engine.start() raised during \(stage): \(raised)"),
        )
      }
      if let startError {
        throw RecordingError.session(.engineStartFailed(error: ErrorContext(startError)))
      }
    }

    /// Records one thing bring-up changed about the request. Idempotent, so an
    /// attempt retried by the start deadline loop does not report it twice.
    package nonisolated func recordCaptureSubstitution(_ substitution: CaptureSubstitution) {
      state.withLock { state in
        guard !state.captureSubstitutions.contains(substitution) else { return }
        state.captureSubstitutions.append(substitution)
      }
    }

    nonisolated func makeTapConversionArtifacts(
      inputFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      tapBufferSize: AVAudioFrameCount,
    ) throws(RecordingError) -> TapConversionArtifacts {
      guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
        throw RecordingError.formatConversionFailed
      }
      // A route narrower than the contract is replicated into it — mono into
      // both channels of a stereo file — by an explicit channel map, so the
      // result does not depend on the converter's default for the pairing.
      // A wider route keeps the converter's own downmix.
      if let channelMap = RecordingInputChannelContract.replicationChannelMap(
        source: Int(inputFormat.channelCount),
        contract: Int(processingFormat.channelCount),
      ) {
        converter.channelMap = channelMap.map { NSNumber(value: $0) }
      }
      let tapFrameRatio = processingFormat.sampleRate / inputFormat.sampleRate
      let maxTapFrames = max(
        AVAudioFrameCount(ceil(Double(tapBufferSize) * tapFrameRatio)),
        1,
      )
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: maxTapFrames,
        )
      else {
        throw RecordingError.formatConversionFailed
      }
      return TapConversionArtifacts(
        converter: converter,
        inputFormat: inputFormat,
        convertedBuffer: convertedBuffer,
      )
    }

    /// Reinstalls the audio input tap on the engine.
    ///
    /// This is the single method used by recording bring-up, route change handling,
    /// and tap interval updates. All engine graph mutations happen on the
    /// engine control queue in a single dispatch.
    /// Builds the `overrideResult` argument for ``reinstallTap`` from the
    /// `@MainActor` test seam. Returns `nil` in release builds (the seam only
    /// exists under `#if DEBUG`). Every `@MainActor` caller of ``reinstallTap``
    /// (startup, both route-change handlers, and tap-interval changes) routes
    /// through this single helper so none of them bypass the seam.
    @MainActor
    package func reinstallTapOverrideResult(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
    ) -> Transferring<Result<TapInstallResult, RecordingError>>? {
      guard let installer = recordingEnvironment.tapInstaller else { return nil }
      let result: Result<TapInstallResult, RecordingError>
      do {
        result = .success(
          try installer.installTap(
            configuration: configuration,
            processingFormat: processingFormat,
          ),
        )
      } catch let error as RecordingError {
        result = .failure(error)
      } catch {
        result = .failure(.engineError)
      }
      return Transferring(result)
    }

    /// Reinstalls the input tap **synchronously** on the engine-control queue.
    ///
    /// Used by the off-main `prepareRecordingGraph`, where the caller is already off the
    /// main thread and has opted
    /// into a blocking call. `@MainActor` lifecycle handlers must use the async
    /// ``reinstallTapAsync(configuration:processingFormat:stopEngine:overrideResult:)``
    /// instead so they never block the main thread.
    ///
    /// Returns `nil` — **without mutating the graph** — when a teardown
    /// (`gracefulStop()` / `hardStop()`) has set ``AIOEngine/engineTearingDown``
    /// before this reinstall reached the head of the serial queue. See
    /// ``reinstallTapOnEngineControlQueue(configuration:processingFormat:stopEngine:overrideResult:)``.
    package nonisolated func reinstallTap(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
      overrideResult: Transferring<Result<TapInstallResult, RecordingError>>? = nil,
    ) throws(RecordingError) -> TapInstallResult? {
      let installResult = runOnEngineControlQueueResult {
        [weak self] () throws -> TapInstallResult? in
        guard let self else { throw RecordingError.engineError }
        return try self.reinstallTapOnEngineControlQueue(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: stopEngine,
          overrideResult: overrideResult,
        )
      }
      return try finishReinstall(installResult)
    }

    /// Reinstalls the input tap **without blocking the main thread**, dispatching
    /// the graph mutation onto the engine-control queue via the async
    /// `withEngineControlQueueResult` helper.
    ///
    /// `@MainActor` callers (route-change handlers, tap-interval reconfigure)
    /// `await` this and **must** re-check liveness after the await — both
    /// `guard isRecording` and `guard !engineTearingDown` — before applying the
    /// result or emitting events, because a stop can complete (or begin) while
    /// the reinstall is suspended. The on-queue teardown guard inside the shared
    /// body closes the in-queue race; the post-await re-check closes the tail
    /// where the reinstall ran on-queue *before* a teardown raised the sentinel.
    package nonisolated func reinstallTapAsync(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
      overrideResult: Transferring<Result<TapInstallResult, RecordingError>>? = nil,
    ) async throws(RecordingError) -> TapInstallResult? {
      let installResult = await withEngineControlQueueResult {
        [weak self] () throws -> TapInstallResult? in
        guard let self else { throw RecordingError.engineError }
        return try self.reinstallTapOnEngineControlQueue(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: stopEngine,
          overrideResult: overrideResult,
        )
      }
      return try finishReinstall(installResult)
    }

    /// Maps the engine-control-queue result of a reinstall into the
    /// `throws(RecordingError) -> TapInstallResult?` contract shared by the sync
    /// and async wrappers.
    private nonisolated func finishReinstall(
      _ installResult: Result<TapInstallResult?, any Error>,
    ) throws(RecordingError) -> TapInstallResult? {
      switch installResult {
      case .success(let result):
        if let result {
          tapSetupLog.info("Tap installed: \(result.tapFormat, privacy: .public)")
        }
        return result
      case .failure(let error):
        throw (error as? RecordingError) ?? .session(.engineStartFailed(error: ErrorContext(error)))
      }
    }

    /// The shared on-engine-control-queue tap-reinstall body, invoked by both the
    /// sync ``reinstallTap`` and async ``reinstallTapAsync`` wrappers. **Must run
    /// on the engine-control queue** (asserted below).
    ///
    /// Returns `nil` — **without mutating the graph** — when a teardown
    /// (`gracefulStop()` / `hardStop()`) has set ``AIOEngine/engineTearingDown``
    /// before this reinstall reached the head of the serial queue. The check is
    /// honoured **on the engine-control queue** (the only point serialized
    /// against the teardown's enqueued work), so a route-change / tap-interval
    /// reinstall that lost the race to a concurrent stop never reinstalls a live
    /// tap onto a torn-down/stopped graph. Callers treat `nil` as "the teardown
    /// owns the graph now; do nothing" — no event, no state resurrection.
    nonisolated func reinstallTapOnEngineControlQueue(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
      overrideResult: Transferring<Result<TapInstallResult, RecordingError>>?,
    ) throws -> TapInstallResult? {
      dispatchPrecondition(condition: .onQueue(engineControlQueue))

      #if os(macOS)
        // System-audio capture owns this recording (Core Audio process tap +
        // aggregate device); there is no AVAudioEngine input tap to reinstall,
        // and installing one would start the microphone and overwrite the tap
        // converter shared with the capture pump. Bail without touching the
        // graph — same "do nothing" contract as the teardown guard below.
        if case .systemAudio = configuration.input {
          tapSetupLog.info("reinstallTap skipped: system-audio capture has no input tap")
          return nil
        }
      #endif

      // 0. Teardown serialization guard. If a teardown superseded this
      //    reinstall (it set `engineTearingDown` before enqueuing its teardown,
      //    which the FIFO serial queue ran ahead of us), bail before touching
      //    the graph. Checked here — on the serial queue — because
      //    `gracefulStop` flips `isRecording` only *after* its drain `await`, so
      //    a main-actor pre-check cannot close this window. The override seam is
      //    resolved *after* this guard so tests can exercise it deterministically
      //    without a real `AVAudioEngine`.
      if engineTearingDown.load(ordering: .sequentiallyConsistent) {
        tapSetupLog.info(
          "reinstallTap superseded by in-flight engine teardown; skipping graph mutation",
        )
        return nil
      }

      #if DEBUG
        if let overrideResult {
          switch overrideResult.value {
          case .success(let result): return result
          case .failure(let error): throw error
          }
        }
      #else
        _ = overrideResult
      #endif

      // 1. Remove existing tap
      let previousBus = state[locked: \.installedTapBus] ?? 0
      engine.inputNode.removeTap(onBus: previousBus)
      state[locked: \.installedTapBus] = nil

      // 2. Stop and reset engine if requested — reset() clears cached node
      //    formats so that prepare() queries the current hardware (critical
      //    after a route change where the sample rate may differ).
      if stopEngine {
        engine.stop()
        engine.reset()
        if !engine.attachedNodes.contains(player) {
          engine.attach(player)
        }
      }

      #if os(macOS)
        try applyPreferredInputDeviceIfNeeded(for: configuration)
      #endif

      // 3. Prepare — updates input node for current hardware
      try prepareGraph("tap reinstall")

      // 4. Read format — one read, one validation
      let inputFormat = engine.inputNode.inputFormat(forBus: 0)
      guard inputFormat.channelCount > 0 else {
        throw RecordingError.session(
          .notReady(details: "Input node has no channels (channelCount: 0)"),
        )
      }
      guard inputFormat.sampleRate > 0 else {
        throw RecordingError.session(
          .notReady(details: "Input node has invalid sample rate (sampleRate: 0)"),
        )
      }

      // 5. Create tap configuration
      guard let tapConfig = configuration.tapConfiguration(bus: 0, input: inputFormat) else {
        throw RecordingError.invalidConfiguration(details: "Cannot create tap configuration")
      }
      guard tapConfig.bufferSize > 0 else {
        throw RecordingError.invalidConfiguration(details: "Tap bufferSize is 0")
      }

      // 6. Install tap at the node's current format
      try installNodeTap(
        bus: tapConfig.bus,
        bufferSize: tapConfig.bufferSize,
        format: inputFormat,
        processingFormat: processingFormat,
      )

      // 7. Prepare post-install, read actual format
      try prepareGraph("post tap install")
      let postInstallFormat = engine.inputNode.inputFormat(forBus: 0)
      guard postInstallFormat.channelCount > 0, postInstallFormat.sampleRate > 0 else {
        throw RecordingError.invalidConfiguration(
          details:
            "Format invalid after tap install (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))",
        )
      }
      guard postInstallFormat.isEqual(inputFormat) else {
        throw RecordingError.invalidConfiguration(
          details:
            "Format changed after tap install (channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate)) -> (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))",
        )
      }

      // 8. Create conversion artifacts from the actual post-install format
      let artifacts = try makeTapConversionArtifacts(
        inputFormat: postInstallFormat,
        processingFormat: processingFormat,
        tapBufferSize: tapConfig.bufferSize,
      )

      let result = TapInstallResult(
        tapFormat: postInstallFormat,
        artifacts: artifacts,
        tapConfiguration: tapConfig,
      )

      // 9. Apply converter state before starting the engine so that
      //    processAudio sees the correct converter from the very first
      //    buffer delivered after start.
      applyTapInstallResult(result, processingFormat: processingFormat)

      // 10. Restart engine if we stopped it
      if stopEngine {
        try startGraph("tap reinstall restart")
      }

      return result
    }

    /// Installs the node-level input tap using
    /// `installAudioTap(onBus:bufferSize:format:tapProvider:)` — the throwing,
    /// `Sendable` replacement for `installTap`, whose provider receives an
    /// `AVReadOnlyAudioPCMBuffer`. Removal uses `removeTap(onBus:)`, which
    /// is not deprecated.
    ///
    /// The OS 27 path bridges zero-copy via
    /// ``ReadOnlyTapBufferBridge/pcmView(of:)`` — a view of the read-only
    /// samples in place, whose deallocator keeps the read-only storage alive
    /// for the view's own lifetime (safe even against a converter that holds
    /// its last input buffer across calls). `AVAudioPCMBuffer(copying:)`
    /// remains only as the fallback for a buffer layout the view cannot back.
    ///
    /// Must run on the engine-control queue, like every other graph mutation
    /// in this file.
    private nonisolated func installNodeTap(
      bus: Int,
      bufferSize: AVAudioFrameCount,
      format: AVAudioFormat,
      processingFormat: AVAudioFormat,
    ) throws {
      tapSetupLog.info("Installing input tap via installAudioTap (OS 27 path)")
      do {
        try engine.inputNode.installAudioTap(
          onBus: bus,
          bufferSize: bufferSize,
          format: format,
        ) { @Sendable [self] readOnlyBuffer, time in
          let buffer =
            ReadOnlyTapBufferBridge.pcmView(of: readOnlyBuffer)
            ?? AVAudioPCMBuffer(copying: readOnlyBuffer)
          self.recording.capture.processAudio(
            buffer: buffer,
            time: time,
            to: processingFormat,
          )
        }
      } catch {
        throw RecordingError.invalidConfiguration(
          details: "installAudioTap failed: \(error.localizedDescription)",
        )
      }
    }

    /// Applies tap install results to engine state.
    ///
    /// Thread Domain: engineControl (called from `reinstallTap` on the engine
    /// control queue, or from recording bring-up after the queue dispatch).
    package func applyTapInstallResult(_ result: TapInstallResult, processingFormat: AVAudioFormat)
    {
      let wrapped = state { state -> Transferring<TapSnapshot> in
        state.tapConverter = result.artifacts.converter
        state.tapConverterInputFormat = result.artifacts.inputFormat
        state.tapConverterOutputFormat = processingFormat
        state.tapConvertedBuffer = result.artifacts.convertedBuffer
        state.installedTapBus = result.tapConfiguration.bus
        // Provenance from the *installed* truth: even if a resolution pre-read
        // raced a route change, `tapFormat` is what the graph actually runs.
        state.captureResolution = ResolvedCaptureFormat(
          hardware: InputConfiguration(
            sampleRate: SampleRate(result.tapFormat.sampleRate),
            channels: ChannelCount(platform: result.tapFormat.channelCount),
          ),
          processing: InputConfiguration(
            sampleRate: SampleRate(processingFormat.sampleRate),
            channels: ChannelCount(platform: processingFormat.channelCount),
          ),
          substitutions: state.captureSubstitutions,
        )
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
    }

    #if os(macOS)
      private nonisolated func applyPreferredInputDeviceIfNeeded(
        for configuration: RecordingConfiguration,
      ) throws(RecordingError) {
        guard case .microphone(let microphone) = configuration.input,
          let preferredInput = microphone.preferredInput
        else {
          return
        }

        let deviceID = try MacOSAudioInputDeviceResolver.inputDeviceID(
          matchingUID: preferredInput.id,
          name: preferredInput.name,
        )
        do {
          try engine.inputNode.withAUAudioUnit { audioUnit in
            try audioUnit.setDeviceID(deviceID)
          }
        } catch {
          throw .captureSourceFailed(
            sourceDescription: preferredInput.description,
            details:
              "Could not select audio input device \(preferredInput.id): \(error.localizedDescription)",
          )
        }
      }
    #endif
  }

  #if os(macOS)
    private enum MacOSAudioInputDeviceResolver {
      static func inputDeviceID(
        matchingUID uid: String,
        name: String,
      ) throws(RecordingError) -> AudioDeviceID {
        for deviceID in deviceIDs() where inputChannelCount(deviceID: deviceID) > 0 {
          guard stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID) == uid
          else {
            continue
          }
          return deviceID
        }

        throw .captureSourceUnavailable(details: "Input '\(name)' (\(uid)) is not available.")
      }

      private static func deviceIDs() -> [AudioDeviceID] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDevices,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain,
        )
        var dataSize: UInt32 = 0
        let sizeStatus = unsafe AudioObjectGetPropertyDataSize(
          systemObjectID,
          &address,
          0,
          nil,
          &dataSize,
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        let readStatus = unsafe AudioObjectGetPropertyData(
          systemObjectID,
          &address,
          0,
          nil,
          &dataSize,
          &devices,
        )
        guard readStatus == noErr else { return [] }
        return devices
      }

      private static func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyStreamConfiguration,
          mScope: kAudioObjectPropertyScopeInput,
          mElement: kAudioObjectPropertyElementMain,
        )
        var dataSize: UInt32 = 0
        let sizeStatus = unsafe AudioObjectGetPropertyDataSize(
          deviceID,
          &address,
          0,
          nil,
          &dataSize,
        )
        guard sizeStatus == noErr, dataSize > 0 else { return 0 }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
          byteCount: Int(dataSize),
          alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer {
          unsafe rawBuffer.deallocate()
        }

        let readStatus = unsafe AudioObjectGetPropertyData(
          deviceID,
          &address,
          0,
          nil,
          &dataSize,
          rawBuffer,
        )
        guard readStatus == noErr else { return 0 }

        let bufferList = unsafe rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        let audioBuffers = unsafe UnsafeMutableAudioBufferListPointer(bufferList)
        return unsafe audioBuffers.reduce(into: 0) { partialResult, buffer in
          partialResult += unsafe Int(buffer.mNumberChannels)
        }
      }

      private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
      ) -> String? {
        var address = AudioObjectPropertyAddress(
          mSelector: selector,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain,
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let rawValue = UnsafeMutableRawPointer.allocate(
          byteCount: Int(dataSize),
          alignment: MemoryLayout<CFString?>.alignment,
        )
        defer {
          unsafe rawValue.deallocate()
        }
        let status = unsafe AudioObjectGetPropertyData(
          objectID,
          &address,
          0,
          nil,
          &dataSize,
          rawValue,
        )
        guard status == noErr else { return nil }
        let value = unsafe rawValue.assumingMemoryBound(to: CFString?.self).pointee
        return value as String?
      }
    }
  #endif
#endif
