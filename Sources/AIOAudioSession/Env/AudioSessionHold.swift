// © GoodHatsLLC

/// A claim on an active platform audio session by something other than
/// capture or playback — a configuration surface that has to show the route
/// the next recording will actually run on.
///
/// While at least one hold exists, the engine's release of session demand
/// after a stop is *deferred* rather than applied: the session stays active
/// until the last hold is released, and the deferred release then happens.
/// Release is explicit. A hold that is dropped without being released keeps
/// the session active, which is the honest failure mode for a surface that
/// forgot — the microphone indicator makes it visible.
@MainActor
public final class AudioSessionHold {
  private var releaseHandler: (@MainActor () async -> Void)?

  /// A hold whose release runs `release`. Public so a test double for
  /// `AudioEnvironmentDriving` can hand one out; production holds come from
  /// `AudioEnvironmentManager.acquireAudioSessionHold()`.
  public init(release: @escaping @MainActor () async -> Void) {
    releaseHandler = release
  }

  /// Whether this hold still keeps the session active.
  public var isHeld: Bool { releaseHandler != nil }

  /// Gives the session back. Idempotent.
  public func release() async {
    guard let handler = releaseHandler else { return }
    releaseHandler = nil
    await withTaskCancellationShield { await handler() }
  }
}
