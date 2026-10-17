// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import AsyncAlgorithms
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()
  private let playbackJogDecodeCapBytes = 64 * 1024 * 1024

  /// File and segment playback: transport, scrubbing, the gesture-scoped jog,
  /// and the polling that publishes playback observations.
  ///
  /// This is the sole owner of playback state. Callers observe and control it
  /// through ``AIOEngine``, which holds exactly one of these for its lifetime.
  ///
  // SAFETY: the individual stores carry their own synchronization — `state` is
  // lock-guarded and `context` is `@MainActor`. This type adds no
  // unsynchronized state of its own beyond the immutable `owner` reference.
  package final class PlaybackRuntime: @unchecked Sendable {
    /// The engine that owns this runtime. `unowned` is safe because the engine
    /// holds it as a stored `let`, so it always outlives it. Implicitly
    /// unwrapped because the engine must finish initializing its own stored
    /// properties before it can hand `self` over.
    package unowned var owner: AIOEngine!

    /// Lock-guarded playback state, read from polling and scrub paths.
    package let state: Synchronized<PlaybackRuntimeState> = .init(.init())

    /// Main-actor-isolated task slots and polling configuration.
    @MainActor package var context = AIOEngine.PlaybackRuntimeContext()

    package init() {}

    /// Opens an audio file for reading **off the main actor**.
    ///
    /// `AVAudioFile(forReading:)` reads the file header synchronously (disk I/O)
    /// and can block tens of milliseconds. `@concurrent` forces this body onto
    /// the global executor even when awaited from a `@MainActor` playback path —
    /// REQUIRED under this package's `NonisolatedNonsendingByDefault`
    /// (SE-0461), where a plain `nonisolated async` function would otherwise
    /// inherit the caller's (main) actor and block the main thread. The returned
    /// file is freshly created and unshared, so it crosses back cleanly.
    @concurrent
    nonisolated func openFileForReading(url: URL) async throws(PlaybackError) -> sending AVAudioFile
    {
      #if DEBUG
        // Guard the off-main contract at the executor (main-actor) level, not the
        // raw OS thread: this body must not run on the main actor's executor.
        dispatchPrecondition(condition: .notOnQueue(.main))
      #endif
      do {
        return try AVAudioFile(forReading: url)
      } catch {
        throw PlaybackError.fileReadFailed(url: url, error: ErrorContext(error))
      }
    }

    @concurrent
    nonisolated func decodePlaybackJogPCM(
      request: PlaybackJogDecodeRequest,
    ) async throws(PlaybackError) -> sending PlaybackJogPreparedAudio {
      #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
      #endif
      do {
        let file = try AVAudioFile(forReading: request.fileURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = max(1, Int(format.channelCount))
        let requestedLower = max(0, min(request.lowerBoundFrame, file.length))
        let requestedUpper = max(requestedLower, min(request.upperBoundFrame, file.length))
        let requestedFrames = max(0, requestedUpper - requestedLower)
        guard requestedFrames > 0 else {
          throw PlaybackError.fileReadFailed(
            url: request.fileURL,
            error: ErrorContext(EmptyAudioFileError(url: request.fileURL)),
          )
        }

        let bytesPerFrame = max(1, channelCount) * MemoryLayout<Float>.stride
        let maximumFrames = max(1, playbackJogDecodeCapBytes / bytesPerFrame)
        let decodeFrameCount = min(Int(requestedFrames), maximumFrames)
        let centerFrame = AVAudioFramePosition(request.cursorFrame.rounded())
        var baseFrame = centerFrame - AVAudioFramePosition(decodeFrameCount / 2)
        baseFrame = max(
          requestedLower, min(baseFrame, requestedUpper - AVAudioFramePosition(decodeFrameCount)))
        let framesToRead = AVAudioFrameCount(
          max(1, min(decodeFrameCount, Int(requestedUpper - baseFrame))))

        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: framesToRead,
          )
        else {
          throw PlaybackError.fileReadFailed(
            url: request.fileURL,
            error: ErrorContext(MissingAudioFileError(url: request.fileURL)),
          )
        }

        file.framePosition = baseFrame
        try file.read(into: buffer, frameCount: framesToRead)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let floatData = unsafe buffer.floatChannelData else {
          throw PlaybackError.fileReadFailed(
            url: request.fileURL,
            error: ErrorContext(EmptyAudioFileError(url: request.fileURL)),
          )
        }

        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
          let source = unsafe floatData[channel]
          let copied = unsafe Array(UnsafeBufferPointer(start: source, count: frameLength))
          channels.append(copied)
        }

        return PlaybackJogPreparedAudio(
          pcm: PlaybackJogPCMStore(baseFrame: baseFrame, channels: channels),
          sampleRate: sampleRate,
          channelCount: channelCount,
        )
      } catch let error as PlaybackError {
        throw error
      } catch {
        throw PlaybackError.fileReadFailed(url: request.fileURL, error: ErrorContext(error))
      }
    }

    @MainActor
    func play(url: URL) async throws(PlaybackError) -> AIOEngine.Playback {
      try await play(url: url, playbackPollingInterval: nil)
    }

    @MainActor
    func play(
      url: URL,
      playbackPollingInterval: Duration?,
    ) async throws(PlaybackError) -> AIOEngine.Playback {
      guard !owner.isRecording else {
        throw PlaybackError.cannotPlayWhileRecording
      }

      do {
        try await owner.configureAudioSessionForPlayback()
      } catch let sessionError {
        throw PlaybackError.session(sessionError)
      }

      // Open the file off the main thread (header read is blocking disk I/O).
      let file = try await openFileForReading(url: url)
      // Re-check after the off-main await: a recording could have started while
      // we were suspended (the top guard ran before the suspension point).
      guard !owner.isRecording else {
        throw PlaybackError.cannotPlayWhileRecording
      }
      guard file.length > 0 else {
        throw PlaybackError.fileReadFailed(
          url: url,
          error: ErrorContext(EmptyAudioFileError(url: url)),
        )
      }

      let interval =
        (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval) > .zero
        ? (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval)
        : .seconds(0.5)
      let playbackInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: file.framePosition,
        pollingInterval: interval,
      )

      if owner.getPlayback() != nil {
        owner.playbackState[locked: \.playbackInstance] = nil
        owner.setPlayback(nil)
      }
      owner.playbackState[locked: \.playbackInstance] = playbackInstance

      let startResult = await owner.withEngineControlQueueResult { [weak owner] in
        guard let owner else { return }
        owner.player.stop()
        owner.engine.stop()
        owner.engine.reset()
        if !owner.engine.attachedNodes.contains(owner.player) {
          owner.engine.attach(owner.player)
        }
        owner.engine.connect(
          owner.player,
          to: owner.engine.mainMixerNode,
          format: file.processingFormat,
        )
        owner.player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
          [weak owner, playbackInstance] _ in
          guard let owner else { return }
          owner.playbackRuntime.cleanupPlaybackInstance(playbackInstance)
        }
        try owner.engine.start()
        owner.player.play()
      }
      if case .failure(let error) = startResult {
        throw PlaybackError.session(.engineStartFailed(error: ErrorContext(error)))
      }

      let playback = owner.getPlayback(for: playbackInstance)
      owner.setPlayback(playback)
      resetPlaybackPolling(to: playbackInstance)
      return playback
    }

    @MainActor
    func playSegment(
      url: URL,
      startTime: TimeInterval,
      endTime: TimeInterval,
      onComplete: (@MainActor @Sendable () -> Void)? = nil,
      playbackPollingInterval: Duration? = nil,
    ) async throws(PlaybackError) -> AIOEngine.Playback {
      guard !owner.isRecording else {
        throw PlaybackError.cannotPlayWhileRecording
      }

      do {
        try await owner.configureAudioSessionForPlayback()
      } catch let sessionError {
        throw PlaybackError.session(sessionError)
      }

      // Open the file off the main thread (header read is blocking disk I/O).
      let file = try await openFileForReading(url: url)
      // Re-check after the off-main await: a recording could have started while
      // we were suspended (the top guard ran before the suspension point).
      guard !owner.isRecording else {
        throw PlaybackError.cannotPlayWhileRecording
      }
      let sampleRate = file.processingFormat.sampleRate
      let startFrame = AVAudioFramePosition(startTime * sampleRate)
      let duration = endTime - startTime

      // Guard hard invariants first: the start must be inside the file and the
      // caller must have asked for a positive window.
      guard startFrame >= 0, startFrame < file.length, duration > 0 else {
        throw PlaybackError.invalidTimeRange
      }

      // Clamp the requested frame count to fit within the file. Stored ranges
      // frequently describe the nominal source duration, which — due to sample
      // rate rounding and AAC/encoding padding — can land a frame or two past
      // `file.length`. Treat that as "play to end of file" rather than
      // rejecting the whole segment.
      let requestedFrameCount = AVAudioFrameCount(duration * sampleRate)
      let maxFrameCount = AVAudioFrameCount(file.length - startFrame)
      let frameCount = min(requestedFrameCount, maxFrameCount)

      guard frameCount > 0 else {
        throw PlaybackError.invalidTimeRange
      }

      let interval =
        (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval) > .zero
        ? (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval)
        : .seconds(0.5)
      let playbackInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: startFrame,
        pollingInterval: interval,
        activeSegment: PlaybackSegment(startFrame: startFrame, frameCount: frameCount),
        onComplete: onComplete,
      )
      let callbackTasks = owner.playbackCallbackTasks

      if owner.getPlayback() != nil {
        owner.playbackState[locked: \.playbackInstance] = nil
        owner.setPlayback(nil)
      }
      owner.playbackState[locked: \.playbackInstance] = playbackInstance

      let startResult = await owner.withEngineControlQueueResult { [weak owner] in
        guard let owner else { return }
        owner.player.stop()
        owner.engine.stop()
        owner.engine.reset()
        if !owner.engine.attachedNodes.contains(owner.player) {
          owner.engine.attach(owner.player)
        }
        owner.engine.connect(
          owner.player,
          to: owner.engine.mainMixerNode,
          format: file.processingFormat,
        )
        owner.player.scheduleSegment(
          file,
          startingFrame: startFrame,
          frameCount: frameCount,
          at: nil,
          completionCallbackType: .dataPlayedBack,
        ) { [weak owner, playbackInstance] _ in
          guard let owner else { return }
          owner.playbackRuntime.cleanupPlaybackInstance(playbackInstance)
          if let onComplete = playbackInstance.onComplete {
            callbackTasks.run { [onComplete] in
              await onComplete()
            }
          }
        }
        try owner.engine.start()
        owner.player.play()
      }
      if case .failure(let error) = startResult {
        throw PlaybackError.session(.engineStartFailed(error: ErrorContext(error)))
      }

      let playback = owner.getPlayback(for: playbackInstance)
      owner.setPlayback(playback)
      resetPlaybackPolling(to: playbackInstance)

      return playback
    }

    @MainActor
    func resetPlaybackPolling(to instance: PlaybackInstance) {
      owner.playbackTask = MainActorOwnedWork { [owner = owner!] in
        let pollingPolicy = PollingPolicy(interval: instance.pollingInterval)
        while !Task.isCancelled {
          try? await pollingPolicy.waitForNextPoll()
          if Task.isCancelled { return }
          let playback = owner.getPlayback()
          if playback?.id == instance.id {
            if owner.playback?.time != playback?.time
              || owner.playback?.isPlaying != playback?.isPlaying
            {
              owner.setPlayback(playback)
            }
          }
        }
      }
    }

    @MainActor
    func beginPlaybackJog(at time: TimeInterval) throws(PlaybackError) -> PlaybackJogSnapshot? {
      if owner.playbackState[locked: \.playbackJogInstance] != nil {
        clearPlaybackJog(scheduleGraphTeardown: true)
      }
      guard let initialInstance = owner.playbackState[locked: \.playbackInstance] else {
        return nil
      }
      let playback = owner.getPlayback(for: initialInstance)
      let allowsUpperBound = initialInstance.activeSegment != nil
      guard time >= 0,
        allowsUpperBound ? playback.duration >= time : playback.duration > time
      else {
        throw PlaybackError.invalidScrubTime(value: time)
      }

      let sampleRate = initialInstance.file.processingFormat.sampleRate
      let framePosition = absoluteFrame(
        for: time,
        in: initialInstance,
        sampleRate: sampleRate,
      )
      guard let resume = capturePlaybackResumeState() else { return nil }
      let lowerBoundFrame = initialInstance.activeSegment?.startFrame ?? 0
      let upperBoundFrame = initialInstance.activeSegment?.endFrame ?? initialInstance.file.length
      guard upperBoundFrame > lowerBoundFrame else { return nil }

      let jogInstance = PlaybackJogInstance(
        id: .init(),
        fileURL: initialInstance.file.url,
        activeSegment: initialInstance.activeSegment,
        duration: playback.duration,
        originalPlayback: resume,
        sampleRate: sampleRate,
        lowerBoundFrame: lowerBoundFrame,
        upperBoundFrame: upperBoundFrame,
        cursorFrame: Double(framePosition),
      )

      owner.playbackState[locked: \.playbackJogInstance] = jogInstance
      owner.playbackTask = nil
      owner.scrubTask = nil
      owner.jogPreparationTask = MainActorOwnedWork(priority: .utility) { [weak owner] in
        guard let owner else { return }
        await owner.playbackRuntime.preparePlaybackJog(instanceID: jogInstance.id)
      }
      resetPlaybackJogPolling(to: jogInstance.id)
      owner.engineControlQueue.async { [weak owner] in
        owner?.player.pause()
      }

      let snapshot = jogInstance.snapshot()
      owner.setPlaybackJog(snapshot)
      return snapshot
    }

    @MainActor
    func updatePlaybackJog(
      rate: PlaybackJogRate,
      anchorTime: TimeInterval?,
    ) throws(PlaybackError) -> PlaybackJogSnapshot? {
      guard let current = owner.playbackState[locked: \.playbackJogInstance] else {
        return nil
      }
      let anchorFrame: Double?
      if let anchorTime {
        guard anchorTime >= 0, current.duration >= anchorTime else {
          throw PlaybackError.invalidScrubTime(value: anchorTime)
        }
        anchorFrame = Double(
          absoluteFrame(
            for: anchorTime,
            activeSegment: current.activeSegment,
            sampleRate: current.sampleRate,
          ),
        )
      } else {
        anchorFrame = nil
      }

      var result: PlaybackJogSnapshot?
      owner.playbackState.withLock { state in
        guard var jogInstance = state.playbackJogInstance, jogInstance.id == current.id else {
          return
        }
        let clampedRate = min(max(rate.value, -4), 4)
        jogInstance.rate = clampedRate
        if let anchorFrame {
          jogInstance.cursorFrame = jogInstance.clampedFrame(anchorFrame)
        }
        if let renderState = jogInstance.renderState {
          renderState.setRate(clampedRate)
          if let anchorFrame {
            renderState.publishAnchor(frame: anchorFrame)
          }
        }
        result = jogInstance.snapshot()
        state.playbackJogInstance = jogInstance
      }

      if let result {
        owner.setPlaybackJog(result)
        applyPlaybackJogTimePitchRate(for: result.rate)
      }
      return result
    }

    @MainActor
    func endPlaybackJog(commit: Bool) throws(PlaybackError) -> AIOEngine.Playback? {
      guard let jogInstance = owner.playbackState[locked: \.playbackJogInstance] else {
        return nil
      }
      let snapshot = jogInstance.snapshot()
      let resume = jogInstance.originalPlayback
      clearPlaybackJog(scheduleGraphTeardown: true)

      let targetTime = commit ? snapshot.time : resume.time
      return try scrub(
        to: targetTime,
        updatePlaybackPolling: true,
        playOverride: resume.wasPlaying,
      )
    }

    @MainActor
    func cancelPlaybackJog() async {
      clearPlaybackJog(scheduleGraphTeardown: false)
      await owner.withEngineControlQueue("playback jog detach") { [weak owner] in
        guard let owner else { return }
        owner.playbackRuntime.detachPlaybackJogNode()
      }
    }

    @MainActor
    func resetPlaybackJogPolling(to instanceID: UUID) {
      owner.jogPollingTask = MainActorOwnedWork { [owner = owner!] in
        let pollingPolicy = PollingPolicy(interval: .milliseconds(33))
        while !Task.isCancelled {
          try? await pollingPolicy.waitForNextPoll()
          if Task.isCancelled { return }
          guard
            let snapshot = owner.playbackState.withLock({ state -> PlaybackJogSnapshot? in
              guard let jogInstance = state.playbackJogInstance, jogInstance.id == instanceID else {
                return nil
              }
              return jogInstance.snapshot()
            })
          else {
            return
          }
          owner.setPlaybackJog(snapshot)
        }
      }
    }

    @MainActor
    func preparePlaybackJog(instanceID: UUID) async {
      guard
        let request = owner.playbackState.withLock({ state -> PlaybackJogDecodeRequest? in
          guard let jogInstance = state.playbackJogInstance, jogInstance.id == instanceID else {
            return nil
          }
          return jogInstance.decodeRequest
        })
      else {
        return
      }

      do {
        let prepared = try await decodePlaybackJogPCM(request: request)
        guard
          let format = AVAudioFormat(
            standardFormatWithSampleRate: prepared.sampleRate,
            channels: AVAudioChannelCount(prepared.channelCount),
          )
        else {
          throw PlaybackError.fileReadFailed(
            url: request.fileURL,
            error: ErrorContext(MissingAudioFileError(url: request.fileURL)),
          )
        }

        let renderState = PlaybackJogRenderState(
          cursorFrame: request.cursorFrame,
          rate: 0,
          lowerBoundFrame: request.lowerBoundFrame,
          upperBoundFrame: request.upperBoundFrame,
          sourceSampleRate: prepared.sampleRate,
          channels: prepared.channelCount,
          pcm: prepared.pcm,
        )

        let stillActive = owner.playbackState.withLock { state -> Bool in
          guard var jogInstance = state.playbackJogInstance, jogInstance.id == instanceID else {
            return false
          }
          renderState.setRate(jogInstance.rate)
          renderState.publishAnchor(frame: jogInstance.cursorFrame)
          jogInstance.renderState = renderState
          state.playbackJogInstance = jogInstance
          return true
        }
        guard stillActive else { return }
        let timePitchRate = PlaybackJogRenderState.timePitchRate(for: renderState.rate)

        let startResult = await owner.withEngineControlQueueResult { [weak owner] in
          guard let owner else { return }
          owner.playbackRuntime.detachPlaybackJogNode()
          let sourceNode = unsafe AVAudioSourceNode(format: format) {
            _, _, frameCount, outputData in
            unsafe renderState.render(frameCount: frameCount, outputData: outputData)
          }
          let timePitchNode = AVAudioUnitTimePitch()
          timePitchNode.pitch = 0
          timePitchNode.rate = Float(timePitchRate)
          unsafe owner.jogSourceNode = sourceNode
          unsafe owner.jogTimePitchNode = timePitchNode
          owner.engine.attach(sourceNode)
          owner.engine.attach(timePitchNode)
          owner.engine.connect(
            sourceNode,
            to: timePitchNode,
            format: format,
          )
          owner.engine.connect(
            timePitchNode,
            to: owner.engine.mainMixerNode,
            format: format,
          )
          if !owner.engine.isRunning {
            try owner.engine.start()
          }
        }
        if case .failure(let error) = startResult {
          owner.eventSubject.send(
            AudioIOEvent.error(
              PlaybackError.session(.engineStartFailed(error: ErrorContext(error)))),
          )
        }

        if let snapshot = owner.playbackState.withLock({ state -> PlaybackJogSnapshot? in
          guard let jogInstance = state.playbackJogInstance, jogInstance.id == instanceID else {
            return nil
          }
          return jogInstance.snapshot()
        }) {
          owner.setPlaybackJog(snapshot)
        }
      } catch let error as PlaybackError {
        owner.eventSubject.send(AudioIOEvent.error(error))
      } catch {
        owner.eventSubject.send(
          AudioIOEvent.error(
            PlaybackError.fileReadFailed(url: request.fileURL, error: ErrorContext(error))),
        )
      }
    }

    @MainActor
    func clearPlaybackJog(scheduleGraphTeardown: Bool) {
      let renderState = owner.playbackState.withLock { state -> PlaybackJogRenderState? in
        let renderState = state.playbackJogInstance?.renderState
        state.playbackJogInstance = nil
        return renderState
      }
      renderState?.stop()
      owner.jogPreparationTask = nil
      owner.jogPollingTask = nil
      owner.setPlaybackJog(nil)
      guard scheduleGraphTeardown else { return }
      owner.engineControlQueue.async { [weak owner] in
        guard let owner else { return }
        owner.playbackRuntime.detachPlaybackJogNode()
      }
    }

    nonisolated func detachPlaybackJogNode() {
      owner.detachPlaybackJogGraph()
    }

    private func applyPlaybackJogTimePitchRate(for signedRate: Double) {
      let timePitchRate = PlaybackJogRenderState.timePitchRate(for: signedRate)
      owner.engineControlQueue.async { [weak owner] in
        unsafe owner?.jogTimePitchNode?.rate = Float(timePitchRate)
      }
    }

    private func absoluteFrame(
      for time: TimeInterval,
      in instance: PlaybackInstance,
      sampleRate: Double,
    ) -> AVAudioFramePosition {
      absoluteFrame(
        for: time,
        activeSegment: instance.activeSegment,
        sampleRate: sampleRate,
      )
    }

    private func absoluteFrame(
      for time: TimeInterval,
      activeSegment: PlaybackSegment?,
      sampleRate: Double,
    ) -> AVAudioFramePosition {
      if let activeSegment {
        activeSegment.clampedAbsoluteFrame(forRelativeTime: time, sampleRate: sampleRate)
      } else {
        AVAudioFramePosition(time * sampleRate)
      }
    }

    @concurrent
    nonisolated func scrub(
      framePosition: AVAudioFramePosition,
      file: AVAudioFile,
      newInstance: PlaybackInstance,
      play: Bool,
      callbackTasks: AsyncTaskRunner,
    ) async {
      if Task.isCancelled { return }
      await owner.withEngineControlQueue("playback segment reschedule") { [weak owner] in
        guard let owner else { return }
        owner.player.stop()
        file.framePosition = framePosition
        owner.player.scheduleSegment(
          file,
          startingFrame: framePosition,
          frameCount: newInstance.scheduledFrameCount,
          at: nil,
          completionCallbackType: .dataPlayedBack,
          completionHandler: { [weak owner, newInstance] _ in
            guard let owner else { return }
            owner.playbackRuntime.cleanupPlaybackInstance(newInstance)
            if let onComplete = newInstance.onComplete {
              callbackTasks.run { [onComplete] in
                await onComplete()
              }
            }
          },
        )
        if play {
          owner.player.play()
        }
      }
    }

    @MainActor
    func scrub(
      to time: TimeInterval,
      updatePlaybackPolling: Bool = true,
      playOverride: Bool? = nil,
    ) throws(PlaybackError) -> AIOEngine.Playback? {
      if let initialInstance = owner.playbackState[locked: \.playbackInstance] {
        let playback = owner.getPlayback(for: initialInstance)
        let shouldPlay = playOverride ?? playback.isPlaying
        let file = initialInstance.file
        let allowsUpperBound = initialInstance.activeSegment != nil
        guard time >= 0,
          allowsUpperBound ? playback.duration >= time : playback.duration > time
        else {
          throw PlaybackError.invalidScrubTime(value: time)
        }
        let framePosition =
          if let activeSegment = initialInstance.activeSegment {
            activeSegment.clampedAbsoluteFrame(
              forRelativeTime: time,
              sampleRate: file.processingFormat.sampleRate,
            )
          } else {
            AVAudioFramePosition(time * file.processingFormat.sampleRate)
          }
        let newInstance = PlaybackInstance(
          id: .init(),
          file: file,
          startFrame: framePosition,
          pollingInterval: initialInstance.pollingInterval,
          activeSegment: initialInstance.activeSegment,
          onComplete: initialInstance.onComplete,
        )
        owner.playbackState[locked: \.playbackInstance] = newInstance
        owner.scrubTask = MainActorOwnedWork(priority: .utility) { [weak owner] in
          guard let owner else { return }
          await owner.playbackRuntime.scrub(
            framePosition: framePosition,
            file: file,
            newInstance: newInstance,
            play: shouldPlay,
            callbackTasks: owner.playbackCallbackTasks,
          )
        }

        let newPlayback = AIOEngine.Playback(
          id: newInstance.id,
          file: file.url,
          isPlaying: shouldPlay,
          time: newInstance.playbackTime(forAbsoluteFrame: framePosition),
          duration: playback.duration,
        )
        defer { owner.setPlayback(newPlayback) }
        if updatePlaybackPolling {
          resetPlaybackPolling(to: newInstance)
        } else {
          owner.playbackTask = nil
        }
        return newPlayback
      } else {
        return nil
      }
    }

    @MainActor
    func stopPlayback() async {
      await withTaskCancellationShield { await finishPlayback() }
    }

    @MainActor
    private func finishPlayback() async {
      await cancelPlaybackJog()
      // Detach the finished file on the main actor, then tear down the graph and
      // close the file together on the engine-control queue — the file close
      // (blocking I/O) runs off the main thread, after the player has stopped so
      // there is no use-after-close.
      let finishedFile: AVAudioFile? = owner.playbackState {
        if let foundInstance = $0.playbackInstance {
          $0.playbackInstance = nil
          return foundInstance.file
        } else {
          return nil
        }
      }
      await owner.withEngineControlQueue("playback graph reset") { [weak owner, finishedFile] in
        guard let owner else { return }
        owner.player.stop()
        owner.engine.stop()
        owner.engine.reset()
        if !owner.engine.attachedNodes.contains(owner.player) {
          owner.engine.attach(owner.player)
        }
        finishedFile?.close()
      }
      owner.playbackTask = nil
      owner.scrubTask = nil
      owner.playbackState[locked: \.playbackInstance] = nil
      owner.setPlayback(nil)
      await owner.deactivateAudioSessionIfNeeded(reason: "playback stopped")
    }

    @MainActor
    func pausePlayback() {
      guard owner.isPlayback else { return }
      clearPlaybackJog(scheduleGraphTeardown: true)
      owner.engineControlQueue.async { [weak owner] in
        owner?.player.pause()
      }
      owner.scrubTask = nil
      if let instance = owner.playbackState[locked: \.playbackInstance] {
        owner.setPlayback(owner.getPlayback(for: instance))
      }
    }

    @MainActor
    func resumePlayback() {
      guard owner.isPlayback, !owner.player.isPlaying else { return }
      owner.engineControlQueue.async { [weak owner] in
        owner?.player.play()
      }
      if let instance = owner.playbackState[locked: \.playbackInstance] {
        owner.setPlayback(owner.getPlayback(for: instance))
      }
    }

    nonisolated func cleanupPlaybackInstance(_ instance: PlaybackInstance) {
      let runtimeOwner: AIOEngine = owner
      let finishedFile: AVAudioFile? = runtimeOwner.playbackState.withLock { state in
        if let foundInstance = state.playbackInstance, foundInstance.id == instance.id {
          state.playbackInstance = nil
          return foundInstance.file
        } else {
          return nil
        }
      }
      if let finishedFile {
        let callbackTasks = runtimeOwner.playbackCallbackTasks
        runtimeOwner.engineControlQueue.async { [weak runtimeOwner] in
          guard let runtimeOwner else { return }
          guard runtimeOwner.playbackState[locked: \.playbackInstance] == nil else { return }
          runtimeOwner.player.stop()
          runtimeOwner.engine.stop()
          runtimeOwner.engine.reset()
          if !runtimeOwner.engine.attachedNodes.contains(runtimeOwner.player) {
            runtimeOwner.engine.attach(runtimeOwner.player)
          }
        }
        callbackTasks.run { [weak runtimeOwner] in
          let shouldDeactivate = await MainActor.run {
            guard runtimeOwner?.playbackState[locked: \.playbackInstance] == nil else {
              return false
            }
            runtimeOwner?.setPlayback(nil)
            return true
          }
          guard shouldDeactivate, let runtimeOwner else { return }
          await runtimeOwner.deactivateAudioSessionIfNeeded(reason: "playback finished")
        }
        finishedFile.close()
      }
    }

    nonisolated func stopPlayerIfNeeded() async {
      await owner.withEngineControlQueue("player stop") { [weak owner] in
        guard let owner, owner.player.isPlaying else { return }
        owner.player.stop()
      }
    }

    @MainActor
    func setPlaybackMixerAmplitude(_ amplitude: Float) {
      // Write directly to the mixer's output volume. Safe to call at any
      // cadence; AVAudioMixerNode.outputVolume is thread-safe for writes.
      owner.engine.mainMixerNode.outputVolume = amplitude
    }

    @MainActor
    func capturePlaybackResumeState() -> PlaybackResume? {
      if let jogInstance = owner.playbackState[locked: \.playbackJogInstance] {
        return jogInstance.originalPlayback
      }
      guard let instance = owner.playbackState[locked: \.playbackInstance] else { return nil }
      let playback = owner.getPlayback(for: instance)
      let time =
        playback.time
        ?? (Double(instance.startFrame) / instance.file.processingFormat.sampleRate)

      return PlaybackResume(
        fileURL: instance.file.url,
        time: time,
        duration: playback.duration,
        wasPlaying: playback.isPlaying,
        pollingInterval: instance.pollingInterval,
        activeSegment: instance.activeSegment,
        sampleRate: instance.file.processingFormat.sampleRate,
      )
    }

    @MainActor
    func restartPlayback(from resume: PlaybackResume) async {
      let duration = resume.duration
      let clampedTime = min(max(0, resume.time), max(0, duration - 0.001))
      guard duration > clampedTime else { return }

      do {
        if let activeSegment = resume.activeSegment {
          let sampleRate = resume.sampleRate
          let segmentStartTime = Double(activeSegment.startFrame) / sampleRate
          let segmentEndTime = Double(activeSegment.endFrame) / sampleRate
          _ = try await playSegment(
            url: resume.fileURL,
            startTime: segmentStartTime,
            endTime: segmentEndTime,
            onComplete: nil,
            playbackPollingInterval: resume.pollingInterval,
          )
        } else {
          _ = try await play(url: resume.fileURL, playbackPollingInterval: resume.pollingInterval)
        }
        if clampedTime > 0 {
          _ = try scrub(to: clampedTime, updatePlaybackPolling: true)
        }
        if resume.wasPlaying == false {
          pausePlayback()
        }
      } catch {
        log.error(
          "Failed to resume playback after audio-system recovery: \(error, privacy: .public)",
        )
        owner.eventSubject.send(.error(error))
      }
    }
  }
#endif
