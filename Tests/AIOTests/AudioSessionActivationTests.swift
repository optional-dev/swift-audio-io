// © GoodHatsLLC

#if os(iOS)
  import AVFAudio
  import Foundation
  import Testing
  import Tools

  @testable import AIOAudioSession
  @testable import AIOEngineCore
  @testable import AIOTestSupport
  @testable import AudioIO

  /// Covers the activation seam introduced for the iOS 27 asynchronous
  /// `AVAudioSession` lifecycle: ordering, supersession, and the fact that
  /// applied state is only ever written from a real platform transition.
  ///
  /// `.serialized` because every case drives one manager through the shared
  /// activation queue and asserts on ordered call records.
  @Suite(.serialized)
  struct AudioSessionActivationTests {
    @Test
    @MainActor
    func `applied state is written only after the activator succeeds`() async throws {
      let activator = FakeAudioSessionActivator()
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      #expect(manager.isAudioSessionActive == false)

      try await manager.setAudioSessionActive(true)

      #expect(manager.isAudioSessionActive)
      #expect(activator.appliedStates == [true])
    }

    @Test
    @MainActor
    func `a failed activation leaves applied state untouched`() async throws {
      let activator = FakeAudioSessionActivator(
        failureForCall: { _ in .refused(active: true) },
      )
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      await #expect(throws: AudioEnvironmentManager.ManagerError.self) {
        try await manager.setAudioSessionActive(true)
      }

      #expect(manager.isAudioSessionActive == false)
      #expect(activator.appliedStates.isEmpty)
    }

    @Test
    @MainActor
    func `a retry after a failed activation is not swallowed by the entry guard`() async throws {
      let activator = FakeAudioSessionActivator(
        failureForCall: { call in call == 0 ? .refused(active: true) : nil },
      )
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      await #expect(throws: AudioEnvironmentManager.ManagerError.self) {
        try await manager.setAudioSessionActive(true)
      }
      try await manager.setAudioSessionActive(true)

      #expect(manager.isAudioSessionActive)
      #expect(activator.startedCount == 2)
      #expect(activator.appliedStates == [true])
    }

    @Test
    @MainActor
    func `an opposite request queued during activation runs after it, in order`() async throws {
      let gate = AsyncSignal<Void>()
      let activator = FakeAudioSessionActivator(
        gateForCall: { call in call == 0 ? gate : nil },
      )
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      let activate = MainActorOwnedWork { try? await manager.setAudioSessionActive(true) }
      await waitUntil { activator.startedCount == 1 }
      let generationBefore = manager.audioSessionActivationGeneration

      // The opposite request arrives while the first is still in flight. It
      // must not be measured against applied state the first has not written.
      let deactivate = MainActorOwnedWork { try? await manager.setAudioSessionActive(false) }
      await waitUntil { manager.audioSessionActivationGeneration > generationBefore }

      gate.signal()
      await activate.value
      await deactivate.value

      #expect(activator.appliedStates == [true, false])
      #expect(manager.isAudioSessionActive == false)
    }

    @Test
    @MainActor
    func `a queued request the platform already satisfied makes no platform call`() async throws {
      let gate = AsyncSignal<Void>()
      let activator = FakeAudioSessionActivator(
        gateForCall: { call in call == 0 ? gate : nil },
      )
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      let first = MainActorOwnedWork { try? await manager.setAudioSessionActive(true) }
      await waitUntil { activator.startedCount == 1 }
      let generationBefore = manager.audioSessionActivationGeneration

      // Same direction as the in-flight request. It cannot be dropped at entry
      // (applied state still says inactive), so it queues — and by the time it
      // runs the platform already matches, making it a no-op.
      let second = MainActorOwnedWork { try? await manager.setAudioSessionActive(true) }
      await waitUntil { manager.audioSessionActivationGeneration > generationBefore }

      gate.signal()
      await first.value
      await second.value

      #expect(activator.startedCount == 1)
      #expect(activator.appliedStates == [true])
      #expect(manager.isAudioSessionActive)
    }

    @Test
    @MainActor
    func `a superseded completion does not claim the newer request's generation`() async throws {
      let gate = AsyncSignal<Void>()
      let activator = FakeAudioSessionActivator(
        gateForCall: { call in call == 0 ? gate : nil },
      )
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      let activate = MainActorOwnedWork { try? await manager.setAudioSessionActive(true) }
      await waitUntil { activator.startedCount == 1 }

      let generationBefore = manager.audioSessionActivationGeneration
      let deactivate = MainActorOwnedWork { try? await manager.setAudioSessionActive(false) }
      await waitUntil { manager.audioSessionActivationGeneration > generationBefore }

      gate.signal()
      await activate.value
      await deactivate.value

      // The newest request owns the settled state; the superseded one did not
      // roll it back on the way out.
      #expect(manager.isAudioSessionActive == false)
      #expect(manager.requestedAudioSessionActive == false)
    }

    @Test
    @MainActor
    func `cancelling mid-activation leaves applied state consistent with the platform`()
      async throws
    {
      let gate = AsyncSignal<Void>()
      let activator = FakeAudioSessionActivator(
        gateForCall: { call in call == 0 ? gate : nil },
      )
      let manager = try makeManager(activator: activator)
      manager.isRunning = true

      let activate = MainActorOwnedWork { try? await manager.setAudioSessionActive(true) }
      await waitUntil { activator.startedCount == 1 }

      // Cancellation cannot interrupt a platform transition that is already
      // under way. What it must not do is leave applied state disagreeing with
      // what the platform actually did.
      activate.cancelNow()
      gate.signal()
      await activate.value

      #expect(activator.appliedStates == [true])
      #expect(manager.isAudioSessionActive)
    }

    @Test
    @MainActor
    func `activation is refused while the manager is not running`() async throws {
      let activator = FakeAudioSessionActivator()
      let manager = try makeManager(activator: activator)

      try await manager.setAudioSessionActive(true)

      #expect(activator.startedCount == 0)
      #expect(manager.isAudioSessionActive == false)
    }

    @Test
    @MainActor
    func `engine-managed session demand routes through the shared activator exactly once`()
      async throws
    {
      let activator = FakeAudioSessionActivator()
      var environment = RecordingEnvironment()
      environment.sessionActivator = activator
      let engine = AIOEngine(
        audioSessionAuthority: nil,
        recordingEnvironment: environment,
      )

      // The deactivation path taken while I/O is stopping. It used to call
      // `AVAudioSession.setActive` raw, outside `AudioSessionAccess`.
      await engine.deactivateAudioSessionIfNeeded(reason: "test")

      #expect(activator.appliedStates == [false])
      #expect(activator.startedCount == 1)
    }

    @Test
    @MainActor
    func `an audio-session authority displaces the engine's own activator`() async throws {
      let activator = FakeAudioSessionActivator()
      var environment = RecordingEnvironment()
      environment.sessionActivator = activator
      let authority = RecordingAuthoritySpy()
      let engine = AIOEngine(
        audioSessionAuthority: authority,
        recordingEnvironment: environment,
      )

      await engine.deactivateAudioSessionIfNeeded(reason: "test")

      #expect(activator.startedCount == 0)
      #expect(authority.requested == [false])
    }

    @Test
    @MainActor
    func `session activation stream stays open until cancelled`() async throws {
      let notifications = AudioEnvironment.Notifications(center: NotificationCenter())
      let terminatedEarly = await withTimeoutReturningNil(of: .milliseconds(200)) {
        for await _ in notifications.sessionDidBecomeActive { return false }
        return true
      }
      #expect(terminatedEarly == nil)
    }

    @Test
    @MainActor
    func `a deactivation notification is captured as a neutral value`() async throws {
      // The neutral conversion is what the recovery policy consumes; the raw
      // platform context never leaves the adapter (ADR 0002). The context
      // types are system-constructed, so this asserts the conversion directly.
      let systemDeactivation = AudioSessionDeactivation(
        source: .system,
        interruptionReason: .routeDisconnected,
      )
      #expect(systemDeactivation.source == .system)
      #expect(systemDeactivation.interruptionReason == .routeDisconnected)
      #expect(systemDeactivation.userLabel.contains("Audio route disconnected"))

      let appDeactivation = AudioSessionDeactivation(source: .app)
      #expect(appDeactivation.interruptionReason == nil)

      // The platform-source adapter only exists when built against the
      // iOS 27 SDK — see `AudioSystemEvent+iOS`.
      #expect(AudioSessionDeactivationSource(.app) == .app)
      #expect(AudioSessionDeactivationSource(.system) == .system)
      #expect(AudioInterruptionReason(.default) == .default)
      #expect(AudioInterruptionReason(.builtInMicMuted) == .builtInMicMuted)
      #expect(AudioInterruptionReason(.routeDisconnected) == .routeDisconnected)
    }

    // MARK: - Helpers

    @MainActor
    private func makeManager(
      activator: any AudioSessionActivating,
    ) throws -> AudioEnvironmentManager {
      let suiteName = "aio.tests.session-activation.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      return AudioEnvironmentManager(
        env: AudioEnvironment(),
        errorManager: MockErrorManager(),
        defaults: defaults,
        sessionActivator: activator,
      )
    }

    /// Spins the main actor until `condition` holds, so a test can observe an
    /// activation that is deliberately parked inside the activator.
    @MainActor
    private func waitUntil(
      _ condition: @MainActor () -> Bool,
      limit: Int = 10_000,
    ) async {
      var spins = 0
      while !condition(), spins < limit {
        spins += 1
        await Task.yield()
      }
      #expect(condition(), "condition never became true")
    }

    private func withTimeoutReturningNil<T: Sendable>(
      of duration: Duration,
      _ body: @escaping @Sendable () async -> T,
    ) async -> T? {
      try? await withTimeout(of: duration) { await body() }
    }
  }

  @MainActor
  private final class RecordingAuthoritySpy: AudioSessionAuthority {
    nonisolated init() {}

    var requested: [Bool] = []

    func setAudioSessionActive(_ active: Bool) async throws {
      requested.append(active)
    }
  }
#endif
