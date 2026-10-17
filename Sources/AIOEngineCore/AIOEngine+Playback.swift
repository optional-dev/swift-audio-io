// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  package import AVFoundation
  import Foundation

  extension AIOEngine {
    @MainActor
    public func play(url: URL) async throws(PlaybackError) -> Playback {
      try await playbackRuntime.play(url: url)
    }

    @MainActor
    public func play(url: URL, playbackPollingInterval: Duration?) async throws(PlaybackError)
      -> Playback
    {
      try await playbackRuntime.play(
        url: url,
        playbackPollingInterval: playbackPollingInterval,
      )
    }

    @MainActor
    public func playSegment(
      url: URL,
      startTime: TimeInterval,
      endTime: TimeInterval,
      onComplete: (@MainActor @Sendable () -> Void)? = nil,
      playbackPollingInterval: Duration? = nil,
    ) async throws(PlaybackError) -> Playback {
      try await playbackRuntime.playSegment(
        url: url,
        startTime: startTime,
        endTime: endTime,
        onComplete: onComplete,
        playbackPollingInterval: playbackPollingInterval,
      )
    }

    @MainActor
    package func resetPlaybackPolling(to instance: PlaybackInstance) {
      playbackRuntime.resetPlaybackPolling(to: instance)
    }

    @concurrent
    package nonisolated func scrub(
      framePosition: AVAudioFramePosition,
      file: AVAudioFile,
      newInstance: PlaybackInstance,
      play: Bool,
    ) async {
      await playbackRuntime.scrub(
        framePosition: framePosition,
        file: file,
        newInstance: newInstance,
        play: play,
        callbackTasks: playbackCallbackTasks,
      )
    }

    /// Scrubs the active playback.
    ///
    /// `time` is segment-relative for `playSegment` playback and file-relative for whole-file
    /// playback.
    @MainActor
    public func scrub(
      to time: TimeInterval,
      updatePlaybackPolling: Bool = true,
    ) throws(PlaybackError) -> Playback? {
      try playbackRuntime.scrub(
        to: time,
        updatePlaybackPolling: updatePlaybackPolling,
      )
    }

    /// Scrubs the active playback with caller intent.
    ///
    /// `time` is segment-relative for `playSegment` playback and file-relative for whole-file
    /// playback. Use ``PlaybackScrubMode/interactive`` for repeated drag updates and
    /// ``PlaybackScrubMode/committed`` for the final drag release or one-shot seek.
    @MainActor
    public func scrub(
      to time: TimeInterval,
      mode: PlaybackScrubMode,
    ) throws(PlaybackError) -> Playback? {
      try playbackRuntime.scrub(
        to: time,
        updatePlaybackPolling: mode.updatesPlaybackPolling,
      )
    }

    /// Starts gesture-scoped audible jog playback at the requested time.
    ///
    /// `time` follows the active playback coordinate system: file-relative for
    /// whole-file playback and segment-relative for segment playback.
    @MainActor
    public func beginPlaybackJog(at time: TimeInterval) throws(PlaybackError)
      -> PlaybackJogSnapshot?
    {
      try playbackRuntime.beginPlaybackJog(at: time)
    }

    /// Updates the active audible jog rate and optional drift-correction anchor.
    ///
    /// `anchorTime` follows the active playback coordinate system. Passing
    /// `nil` leaves the render-owned cursor moving at the current rate.
    @MainActor
    public func updatePlaybackJog(
      rate: PlaybackJogRate,
      anchorTime: TimeInterval?,
    ) throws(PlaybackError) -> PlaybackJogSnapshot? {
      try playbackRuntime.updatePlaybackJog(rate: rate, anchorTime: anchorTime)
    }

    /// Ends audible jog playback.
    ///
    /// When `commit` is `true`, the current jog cursor is committed through the
    /// ordinary scrub/seek path. When `false`, playback is restored to the
    /// pre-jog position and play/pause state.
    @MainActor
    public func endPlaybackJog(commit: Bool) throws(PlaybackError) -> Playback? {
      try playbackRuntime.endPlaybackJog(commit: commit)
    }

    /// Cancels audible jog without attempting playback recovery.
    ///
    /// Route-change and media-services recovery paths call this before their
    /// normal playback restart logic so jog preview state is never serialized or
    /// treated as resumable playback.
    @MainActor
    public func cancelPlaybackJog() async {
      await playbackRuntime.cancelPlaybackJog()
    }

    /// Stops playback and releases its resources even when the caller is cancelled.
    @MainActor
    public func stopPlayback() async {
      await playbackRuntime.stopPlayback()
    }

    @MainActor
    public func pausePlayback() {
      playbackRuntime.pausePlayback()
    }

    @MainActor
    public func resumePlayback() {
      playbackRuntime.resumePlayback()
    }

    @MainActor
    public func setPlaybackMixerAmplitude(_ amplitude: Float) {
      playbackRuntime.setPlaybackMixerAmplitude(amplitude)
    }

    package nonisolated func cleanupPlaybackInstance(_ instance: PlaybackInstance) {
      playbackRuntime.cleanupPlaybackInstance(instance)
    }

    package nonisolated func stopPlayerIfNeeded() async {
      await playbackRuntime.stopPlayerIfNeeded()
    }

    @MainActor
    package func capturePlaybackResumeState() -> PlaybackResume? {
      playbackRuntime.capturePlaybackResumeState()
    }

    @MainActor
    package func restartPlayback(from resume: PlaybackResume) async {
      await playbackRuntime.restartPlayback(from: resume)
    }
  }
#endif
