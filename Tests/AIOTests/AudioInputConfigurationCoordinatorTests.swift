// © GoodHatsLLC

import Foundation
import Testing
import Tools

@testable import AIOAudioSession

struct AudioInputConfigurationCoordinatorTests {
  enum AdapterFailure: Error {
    case rejected
  }

  actor ScriptedAdapter: PlatformAudioInputConfigurationAdapter {
    var snapshot: PlatformAudioInputSnapshot
    var appliedPlans: [PlatformAudioInputConfigurationPlan] = []
    let throwsOnApply: Bool
    let throwsOnPrepare: Bool
    private var preparationCount = 0

    init(
      snapshot: PlatformAudioInputSnapshot,
      throwsOnApply: Bool = false,
      throwsOnPrepare: Bool = false,
    ) {
      self.snapshot = snapshot
      self.throwsOnApply = throwsOnApply
      self.throwsOnPrepare = throwsOnPrepare
    }

    func prepare(processing _: AudioInputProcessingPreference) async throws {
      preparationCount += 1
      if throwsOnPrepare { throw AdapterFailure.rejected }
    }

    func preparations() -> Int { preparationCount }

    func discover() async -> PlatformAudioInputSnapshot {
      snapshot
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      appliedPlans.append(plan)
      if throwsOnApply {
        throw AdapterFailure.rejected
      }
      return snapshot
    }

    func setSnapshot(_ snapshot: PlatformAudioInputSnapshot) {
      self.snapshot = snapshot
    }

    func plans() -> [PlatformAudioInputConfigurationPlan] {
      appliedPlans
    }
  }

  actor BlockingAdapter: PlatformAudioInputConfigurationAdapter {
    private let input: AudioInputSelection
    private let applyStarted = AsyncContinuation<Void>()
    private let releaseFirstApply = AsyncContinuation<Void>()
    private var blocksNextApply = true
    private var appliedChannels: ChannelCount?
    private var applyCount = 0

    init(input: AudioInputSelection) {
      self.input = input
    }

    /// Discovery reflects what has already been applied, the way a real
    /// platform readback does. Without that the write barrier could never
    /// recognise a settled state.
    func discover() async -> PlatformAudioInputSnapshot {
      snapshot(appliedChannels: appliedChannels)
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      applyCount += 1
      if blocksNextApply {
        blocksNextApply = false
        try? applyStarted.yield()
        await releaseFirstApply()
      }
      appliedChannels = plan.format.channels
      return snapshot(appliedChannels: appliedChannels)
    }

    func applies() -> Int {
      applyCount
    }

    func waitForFirstApply() async {
      await applyStarted()
    }

    func release() {
      try? releaseFirstApply.yield()
    }

    private func snapshot(
      appliedChannels: ChannelCount?
    ) -> PlatformAudioInputSnapshot {
      PlatformAudioInputSnapshot(
        capabilities: AudioInputConfigurationCapabilities(
          discovery: .resolved,
          inputs: [input],
          effectiveInput: input,
          sourceOptions: [
            AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .mono),
            AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo),
          ],
          likelySampleRates: [.dvd],
          activeSampleRate: nil,
        ),
        applied: appliedChannels.map {
          AppliedAudioInputConfiguration(
            input: input,
            source: nil,
            format: InputConfiguration(sampleRate: .dvd, channels: $0),
            processing: .processed,
          )
        },
      )
    }
  }

  /// Processing changes can change the source/channel choices exposed by the
  /// session. In particular, choices missing in Raw may return in Processed.
  actor ProcessingAdapter: PlatformAudioInputConfigurationAdapter {
    private var processing = AudioInputProcessingPreference.processed
    private var appliedPlans: [PlatformAudioInputConfigurationPlan] = []
    private var processingWrites = 0

    func prepare(processing: AudioInputProcessingPreference) async throws {
      guard self.processing != processing else { return }
      processingWrites += 1
      self.processing = processing
    }

    func writes() -> Int { processingWrites }
    func plans() -> [PlatformAudioInputConfigurationPlan] { appliedPlans }

    func discover() async -> PlatformAudioInputSnapshot {
      let channels: ChannelCount = processing == .processed ? .stereo : .mono
      let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: channels)
      let source = AudioSourceSelection(
        id: processing == .processed ? "processed-source" : "raw-source",
        name: "Source",
      )
      return PlatformAudioInputSnapshot(
        capabilities: AudioInputConfigurationCapabilities(
          discovery: .resolved,
          inputs: [input],
          effectiveInput: input,
          sourceOptions: [
            AudioSourceConfigurationOption(inputID: input.id, source: source, channels: channels)
          ],
          likelySampleRates: [.dvd],
          activeSampleRate: .dvd,
        ),
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: source,
          format: InputConfiguration(sampleRate: .dvd, channels: channels),
          processing: processing,
        ),
      )
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      appliedPlans.append(plan)
      return await discover()
    }
  }

  @Test(arguments: [false, true])
  @MainActor
  func `processing can switch back after Raw removes requested input choices`(
    selectsSource: Bool
  ) async throws {
    let defaults = try isolatedDefaults()
    let adapter = ProcessingAdapter()
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    if selectsSource {
      request.source = .specific(sourceID: "processed-source", polarPatternID: nil)
    }

    for processing: AudioInputProcessingPreference in [
      .processed, .measurement, .processed, .measurement, .processed,
    ] {
      request.processing = processing
      let state = await coordinator.submit(request, isRunning: true, isActive: true)
      #expect(state.requested == request)
      #expect(state.applied?.processing == processing)
      if processing == .processed {
        #expect(state.reconciliation == .satisfied)
        #expect(state.applied?.format.channels == .stereo)
      } else {
        #expect(
          state.reconciliation == .unsatisfied(
            selectsSource
              ? .unsupportedSource(id: "processed-source") : .unsupportedChannels(.stereo)
          )
        )
      }
    }
    let plans = await adapter.plans()
    for _ in 0..<10 {
      _ = await coordinator.reconcile(isRunning: true, isActive: true)
    }
    #expect(await adapter.writes() == 4)
    #expect(await adapter.plans() == plans)
  }

  @Test
  @MainActor
  func `processing is prepared even while the requested input is unavailable`() async throws {
    let adapter = ProcessingAdapter()
    let coordinator = AudioInputConfigurationCoordinator(
      defaults: try isolatedDefaults(), adapter: adapter,
    )
    let request = AudioInputConfigurationRequest(
      input: .specific(id: "disconnected"), processing: .measurement,
    )
    let state = await coordinator.submit(request, isRunning: true, isActive: true)
    #expect(state.requested == request)
    #expect(state.applied?.processing == .measurement)
    #expect(state.reconciliation == .deferred(.requestedInputUnavailable(id: "disconnected")))
    #expect(await adapter.plans().isEmpty)
  }

  @Test
  @MainActor
  func `inactive processing request waits for activation`() async throws {
    let adapter = ProcessingAdapter()
    let coordinator = AudioInputConfigurationCoordinator(
      defaults: try isolatedDefaults(), adapter: adapter,
    )
    let request = AudioInputConfigurationRequest(processing: .measurement)
    let inactive = await coordinator.submit(request, isRunning: true, isActive: false)
    #expect(inactive.requested == request)
    #expect(inactive.applied == nil)
    #expect(await adapter.writes() == 0)
    let active = await coordinator.reconcile(isRunning: true, isActive: true)
    #expect(active.applied?.processing == .measurement)
    #expect(active.reconciliation == .satisfied)
    #expect(await adapter.writes() == 1)
  }

  @Test
  @MainActor
  func `processing preparation failures retry within budget and a new request can retry`()
    async throws
  {
    let adapter = ScriptedAdapter(
      snapshot: stereoSnapshot(appliedChannels: .stereo), throwsOnPrepare: true,
    )
    let coordinator = AudioInputConfigurationCoordinator(
      defaults: try isolatedDefaults(), adapter: adapter,
      policy: AudioInputReconciliationPolicy(platformFailureRetryBudget: 2),
    )
    let request = AudioInputConfigurationRequest(processing: .measurement)
    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    for _ in 0..<10 {
      let state = await coordinator.reconcile(isRunning: true, isActive: true)
      #expect(state.requested == request)
      #expect(state.applied?.processing == .processed)
      guard case .unsatisfied(.platformOperationFailed) = state.reconciliation else {
        Issue.record("Expected a preparation failure, got \(state.reconciliation)")
        return
      }
    }
    #expect(await adapter.preparations() == 3)
    #expect(await adapter.plans().isEmpty)
    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    #expect(await adapter.preparations() == 4)
  }

  @Test
  @MainActor
  func `unresolved startup retains automatic request and publishes discovery facts`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(
      snapshot: PlatformAudioInputSnapshot(
        capabilities: .discovering,
        applied: nil,
      ),
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)

    let state = await coordinator.reconcile(isRunning: true, isActive: false)

    #expect(state.requested == .automatic)
    #expect(state.requestedGeneration == 0)
    #expect(state.capabilities.discovery == .discovering)
    #expect(state.applied == nil)
    #expect(state.reconciliation == .deferred(.sessionInactive))
  }

  @Test
  @MainActor
  func `inactive stereo request persists without touching the platform`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: nil))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: false)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied == nil)
    #expect(state.reconciliation == .deferred(.sessionInactive))
    #expect(await adapter.plans().isEmpty)

    let restored = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    #expect(restored.state.requested.channels == .stereo)
  }

  @Test
  @MainActor
  func `active request is satisfied only after exact stereo readback`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied?.format.channels == .stereo)
    #expect(state.reconciliation == .satisfied)
    #expect(await adapter.plans().map(\.format.channels) == [.stereo])
  }

  @Test
  @MainActor
  func `refreshing an already satisfied request does not touch the platform`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    let refreshed = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(refreshed.reconciliation == .satisfied)
    let appliedPlans = await adapter.plans()
    #expect(
      appliedPlans.map(\.format.channels) == [.stereo],
      "A capability refresh reapplied the satisfied route \(appliedPlans.count) times.",
    )
  }

  @Test
  @MainActor
  func `forcing a satisfied reconciliation reapplies platform preferences once`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    let reconciled = await coordinator.reconcile(
      isRunning: true,
      isActive: true,
      forcePlatformApply: true,
    )
    let notificationRefresh = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(reconciled.reconciliation == .satisfied)
    #expect(notificationRefresh.reconciliation == .satisfied)
    #expect(await adapter.plans().map(\.format.channels) == [.stereo, .stereo])
  }

  @Test
  @MainActor
  func `activation reconciles the stereo request submitted while inactive`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: false)
    let state = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.reconciliation == .satisfied)
    #expect(await adapter.plans().map(\.format.channels) == [.stereo])
  }

  @Test
  func `automatic resolution chooses stereo when available and mono otherwise`() {
    let stereo = AudioInputConfigurationResolver.resolve(
      requested: .automatic,
      generation: 1,
      capabilities: stereoSnapshot(appliedChannels: nil).capabilities,
      currentApplied: nil,
    )
    let mono = AudioInputConfigurationResolver.resolve(
      requested: .automatic,
      generation: 2,
      capabilities: monoSnapshot(appliedChannels: nil).capabilities,
      currentApplied: nil,
    )

    guard case .apply(let stereoPlan) = stereo, case .apply(let monoPlan) = mono else {
      Issue.record("Expected platform plans for both automatic requests")
      return
    }
    #expect(stereoPlan.format.channels == .stereo)
    #expect(monoPlan.format.channels == .mono)
  }

  @Test
  func `exact source resolution produces one complete platform plan`() {
    let input = AudioInputSelection(id: "mic", name: "Microphone", channelCount: .stereo)
    let source = AudioSourceSelection(
      id: "front",
      name: "Front",
      polarPatternID: "stereo",
      polarPatternName: "Stereo",
    )
    let capabilities = snapshot(
      input: input,
      options: [
        AudioSourceConfigurationOption(inputID: input.id, source: source, channels: .stereo)
      ],
      applied: nil,
    ).capabilities
    let request = AudioInputConfigurationRequest(
      input: .specific(id: input.id),
      source: .specific(sourceID: source.id, polarPatternID: source.polarPatternID),
      channels: .stereo,
      sampleRate: .exact(.dvd),
      processing: .measurement,
    )

    let resolution = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 4,
      capabilities: capabilities,
      currentApplied: nil,
    )

    guard case .apply(let plan) = resolution else {
      Issue.record("Expected a complete platform plan, got \(resolution)")
      return
    }
    #expect(plan.requestedGeneration == 4)
    #expect(plan.preferredInput == input)
    #expect(plan.resolvedInput == input)
    #expect(plan.source == source)
    #expect(plan.format == InputConfiguration(sampleRate: .dvd, channels: .stereo))
    #expect(plan.processing == .measurement)
  }

  @Test
  func `explicit stereo remains unsupported on a mono-only input`() {
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let resolution = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 3,
      capabilities: monoSnapshot(appliedChannels: .mono).capabilities,
      currentApplied: monoSnapshot(appliedChannels: .mono).applied,
    )

    #expect(resolution == .unsupported(.unsupportedChannels(.stereo)))
    #expect(request.channels == .stereo)
  }

  @Test
  @MainActor
  func `platform no-op keeps stereo requested and reports mono readback`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .mono))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied?.format.channels == .mono)
    guard case .unsatisfied(.readbackMismatch) = state.reconciliation else {
      Issue.record("Expected readback mismatch, got \(state.reconciliation)")
      return
    }
  }

  @Test
  @MainActor
  func `apply failure preserves stereo intent and publishes truthful mono readback`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(
      snapshot: stereoSnapshot(appliedChannels: .mono),
      throwsOnApply: true,
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied?.format.channels == .mono)
    guard case .unsatisfied(.platformOperationFailed) = state.reconciliation else {
      Issue.record("Expected platform failure, got \(state.reconciliation)")
      return
    }
  }

  @Test
  @MainActor
  func `sample-rate rejection keeps requested rate and reports applied rate`() async throws {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let adapter = ScriptedAdapter(
      snapshot: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo)
        ],
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .cd, channels: .stereo),
          processing: .processed,
        ),
      )
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    request.sampleRate = .exact(.dvd)

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.sampleRate == .exact(.dvd))
    #expect(state.applied?.format.sampleRate == .cd)
    #expect(
      state.reconciliation == .unsatisfied(.rejectedSampleRate(requested: .dvd, applied: .cd)))
  }

  @Test
  @MainActor
  func `automatic sample rate writes no preference and any readback rate satisfies`() async throws
  {
    // The same 44.1 kHz route that rejects an exact 48 kHz request. An
    // `.automatic` request has no rate to reject: the plan carries the
    // automatic intent (the adapter writes no preference for it) and the
    // readback's rate is definitionally correct.
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let adapter = ScriptedAdapter(
      snapshot: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo)
        ],
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .cd, channels: .stereo),
          processing: .processed,
        ),
      )
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.reconciliation == .satisfied)
    #expect(state.applied?.format.sampleRate == .cd)
    #expect(await adapter.plans().last?.sampleRateIntent == AudioSampleRatePreference.automatic)
  }

  @Test
  @MainActor
  func `capabilities surface the applied rate as the active sample rate`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot(appliedSampleRate: .cd))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.capabilities.activeSampleRate == .cd)
    #expect(state.capabilities.likelySampleRates.contains(.dvd))
  }

  @Test
  @MainActor
  func `partial source readback cannot satisfy exact stereo source`() async throws {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let requestedSource = AudioSourceSelection(
      id: "front",
      name: "Front",
      polarPatternID: "stereo",
      polarPatternName: "Stereo",
    )
    let appliedSource = AudioSourceSelection(
      id: "back",
      name: "Back",
      polarPatternID: "stereo",
      polarPatternName: "Stereo",
    )
    let adapter = ScriptedAdapter(
      snapshot: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(
            inputID: input.id,
            source: requestedSource,
            channels: .stereo,
          )
        ],
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: appliedSource,
          format: InputConfiguration(sampleRate: .dvd, channels: .stereo),
          processing: .processed,
        ),
      )
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.input = .specific(id: input.id)
    request.source = .specific(sourceID: requestedSource.id, polarPatternID: "stereo")
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.source == request.source)
    guard case .unsatisfied(.readbackMismatch) = state.reconciliation else {
      Issue.record("Expected source readback mismatch, got \(state.reconciliation)")
      return
    }
  }

  @Test
  func `resolver rejects an unsupported exact polar pattern`() {
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let source = AudioSourceSelection(
      id: "front",
      name: "Front",
      polarPatternID: "cardioid",
      polarPatternName: "Cardioid",
    )
    var request = AudioInputConfigurationRequest.automatic
    request.source = .specific(sourceID: source.id, polarPatternID: "stereo")

    let resolution = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 9,
      capabilities: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(inputID: input.id, source: source, channels: .mono)
        ],
        applied: nil,
      ).capabilities,
      currentApplied: nil,
    )

    #expect(resolution == .unsupported(.unsupportedPolarPattern(id: "stereo")))
  }

  @Test
  @MainActor
  func `route refresh changes capabilities without erasing stereo request`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    _ = await coordinator.submit(request, isRunning: true, isActive: true)

    await adapter.setSnapshot(monoSnapshot(appliedChannels: .mono))
    let state = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.capabilities.effectiveInput?.channelCount == .mono)
    #expect(state.reconciliation == .unsatisfied(.unsupportedChannels(.stereo)))
  }

  @Test
  @MainActor
  func `deactivation clears applied state without changing request`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    _ = await coordinator.submit(request, isRunning: true, isActive: true)

    let state = coordinator.markUnavailable(.sessionInactive)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied == nil)
    #expect(state.reconciliation == .deferred(.sessionInactive))
  }

  @Test
  @MainActor
  func `media-services recovery reconciles the unchanged latest generation`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    let applied = await coordinator.submit(request, isRunning: true, isActive: true)

    let unavailable = coordinator.markUnavailable(.mediaServicesUnavailable)
    let recovered = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(unavailable.requested == request)
    #expect(unavailable.requestedGeneration == applied.requestedGeneration)
    #expect(unavailable.applied == nil)
    #expect(unavailable.reconciliation == .deferred(.mediaServicesUnavailable))
    #expect(recovered.requested == request)
    #expect(recovered.requestedGeneration == applied.requestedGeneration)
    #expect(recovered.applied?.format.channels == .stereo)
    #expect(recovered.reconciliation == .satisfied)
  }

  @Test
  @MainActor
  func `newer request wins over an in-flight uninterruptible apply`() async throws {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let adapter = BlockingAdapter(input: input)
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var stereo = AudioInputConfigurationRequest.automatic
    stereo.channels = .stereo
    let first = MainActorOwnedWork {
      _ = await coordinator.submit(stereo, isRunning: true, isActive: true)
    }
    await adapter.waitForFirstApply()

    var mono = AudioInputConfigurationRequest.automatic
    mono.channels = .mono
    let second = MainActorOwnedWork {
      _ = await coordinator.submit(mono, isRunning: true, isActive: true)
    }
    // Reconciliation is single-flight, so the newer request is coalesced behind
    // the uninterruptible apply rather than racing it. Releasing first is what
    // lets both settle; the contract being asserted is which request *wins*,
    // not which one gets to interleave with the platform.
    await adapter.release()
    await first.value
    await second.value

    #expect(coordinator.state.requested.channels == .mono)
    #expect(coordinator.state.applied?.format.channels == .mono)
    #expect(coordinator.state.reconciliation == .satisfied)
  }

  // MARK: - Platform write barrier

  /// The reported feedback loop, in miniature. An exact sample rate the route
  /// refuses leaves reconciliation stably `.unsatisfied`, and the old guard —
  /// "skip the write only when already `.satisfied`" — rewrote the preferences
  /// on every refresh. Each rewrite posts a `.categoryChange` route
  /// notification, which triggers the next refresh.
  @Test
  @MainActor
  func `a rejected exact sample rate is not rewritten on repeated route refreshes`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot())
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    request.sampleRate = .exact(.dvd)

    let submitted = await coordinator.submit(request, isRunning: true, isActive: true)
    #expect(submitted.reconciliation == .unsatisfied(.rejectedSampleRate(requested: .dvd, applied: .cd)))
    #expect(await adapter.plans().count == 1)

    for _ in 0..<8 {
      let refreshed = await coordinator.reconcile(isRunning: true, isActive: true)
      #expect(
        refreshed.reconciliation
          == .unsatisfied(.rejectedSampleRate(requested: .dvd, applied: .cd)),
      )
      #expect(refreshed.requested.sampleRate == .exact(.dvd))
    }

    let plans = await adapter.plans()
    #expect(
      plans.count == 1,
      "A stably unsatisfied sample rate was rewritten \(plans.count) times.",
    )
  }

  @Test
  @MainActor
  func `a route notification during an in-flight apply does not queue a second apply`()
    async throws
  {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let adapter = BlockingAdapter(input: input)
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let submit = MainActorOwnedWork {
      _ = await coordinator.submit(request, isRunning: true, isActive: true)
    }
    await adapter.waitForFirstApply()

    // Three route notifications land while the apply is suspended. They must
    // collapse into one follow-up run, and that run must find nothing changed.
    let refreshes = (0..<3).map { _ in
      MainActorOwnedWork {
        _ = await coordinator.reconcile(isRunning: true, isActive: true)
      }
    }

    await adapter.release()
    await submit.value
    for refresh in refreshes { await refresh.value }

    let applies = await adapter.applies()
    #expect(applies == 1, "A mid-apply route notification produced \(applies) platform applies.")
    #expect(coordinator.state.reconciliation == .satisfied)
  }

  @Test
  @MainActor
  func `a new request after an unsatisfied state performs exactly one new apply`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot())
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var rejected = AudioInputConfigurationRequest.automatic
    rejected.channels = .stereo
    rejected.sampleRate = .exact(.dvd)

    _ = await coordinator.submit(rejected, isRunning: true, isActive: true)
    _ = await coordinator.reconcile(isRunning: true, isActive: true)
    #expect(await adapter.plans().count == 1)

    // New user intent is the canonical reason to write again — the requested
    // generation is stamped into the plan, so the barrier cannot hold.
    var accepted = rejected
    accepted.sampleRate = .exact(.cd)
    let settled = await coordinator.submit(accepted, isRunning: true, isActive: true)

    #expect(settled.reconciliation == .satisfied)
    let plans = await adapter.plans()
    #expect(plans.count == 2, "A new request produced \(plans.count) platform applies in total.")
    #expect(plans.last?.format.sampleRate == .cd)
  }

  @Test
  @MainActor
  func `a forced apply writes once and its own notification does not recur`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot())
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    request.sampleRate = .exact(.dvd)

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    #expect(await adapter.plans().count == 1)

    // Activation, orientation, and media-services recovery all opt into one
    // write because the platform may have discarded state the readback cannot
    // describe.
    _ = await coordinator.reconcile(isRunning: true, isActive: true, forcePlatformApply: true)
    #expect(await adapter.plans().count == 2)

    // The forced write posts its own route notification. Reconciling on it must
    // not start the loop over.
    for _ in 0..<5 {
      _ = await coordinator.reconcile(isRunning: true, isActive: true)
    }

    let plans = await adapter.plans()
    #expect(plans.count == 2, "A forced apply recursed into \(plans.count) platform applies.")
  }

  @Test
  @MainActor
  func `media-services loss re-authorises exactly one write on recovery`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot())
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    request.sampleRate = .exact(.dvd)

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    _ = coordinator.markUnavailable(.mediaServicesUnavailable)

    _ = await coordinator.reconcile(isRunning: true, isActive: true)
    #expect(await adapter.plans().count == 2)

    for _ in 0..<3 {
      _ = await coordinator.reconcile(isRunning: true, isActive: true)
    }
    #expect(await adapter.plans().count == 2)
  }

  /// The barrier is not a permanent lockout: a genuine external change — a new
  /// route offering a different rate — is exactly what re-authorises a write.
  @Test
  @MainActor
  func `a changed route re-authorises the platform write`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot())
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    request.sampleRate = .exact(.dvd)

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    _ = await coordinator.reconcile(isRunning: true, isActive: true)
    #expect(await adapter.plans().count == 1)

    await adapter.setSnapshot(rejectedSampleRateSnapshot(appliedSampleRate: .dvd))
    let recovered = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(recovered.reconciliation == .satisfied)
    #expect(await adapter.plans().count == 2)
  }

  @Test
  @MainActor
  func `a thrown platform write retries within its budget and then stops`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(
      snapshot: stereoSnapshot(appliedChannels: .mono),
      throwsOnApply: true,
    )
    let coordinator = AudioInputConfigurationCoordinator(
      defaults: defaults,
      adapter: adapter,
      policy: AudioInputReconciliationPolicy(platformFailureRetryBudget: 2),
    )
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    for _ in 0..<6 {
      _ = await coordinator.reconcile(isRunning: true, isActive: true)
    }

    // One write for the submit, then the budget's two retries, then the barrier
    // holds. A thrown write is the only failure mode that gets a budget.
    let plans = await adapter.plans()
    #expect(plans.count == 3, "A failing write was retried \(plans.count) times.")
  }

  @Test
  func `resolver rejects an exact unsupported source without changing channel intent`() {
    var request = AudioInputConfigurationRequest.automatic
    request.source = .specific(sourceID: "missing", polarPatternID: nil)
    request.channels = .stereo

    let decision = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 7,
      capabilities: stereoSnapshot(appliedChannels: nil).capabilities,
      currentApplied: nil,
    )

    #expect(decision == .unsupported(.unsupportedSource(id: "missing")))
    #expect(request.channels == .stereo)
  }

  @Test
  @MainActor
  func `legacy preference keys are ignored`() throws {
    let defaults = try isolatedDefaults()
    defaults.set("old-mic", forKey: "aio.audio_env.explicit_preferred_input_id.v2")
    defaults.set(true, forKey: "aio.audio_env.use_measurement")
    defaults.set(Data([0x00]), forKey: "aio.audio_env.input_prefs_by_id.v1")

    let store = AudioInputConfigurationRequestStore(defaults: defaults)

    #expect(store.load() == .automatic)
  }

  @Test
  @MainActor
  func `complete request schema round trips`() throws {
    let defaults = try isolatedDefaults()
    let store = AudioInputConfigurationRequestStore(defaults: defaults)
    let request = AudioInputConfigurationRequest(
      input: .specific(id: "usb"),
      source: .specific(sourceID: "front", polarPatternID: "stereo"),
      channels: .stereo,
      sampleRate: .exact(.hiRes96),
      processing: .measurement,
    )

    store.save(request)

    #expect(store.load() == request)
  }

  private func stereoSnapshot(
    appliedChannels: ChannelCount?,
  ) -> PlatformAudioInputSnapshot {
    let input = AudioInputSelection(
      id: "mic",
      name: "Stereo Microphone",
      channelCount: .stereo,
    )
    let mono = AudioSourceConfigurationOption(
      inputID: input.id,
      source: nil,
      channels: .mono,
    )
    let stereo = AudioSourceConfigurationOption(
      inputID: input.id,
      source: nil,
      channels: .stereo,
    )
    return PlatformAudioInputSnapshot(
      capabilities: AudioInputConfigurationCapabilities(
        discovery: .resolved,
        inputs: [input],
        effectiveInput: input,
        sourceOptions: [mono, stereo],
        likelySampleRates: [.dvd],
        activeSampleRate: nil,
      ),
      applied: appliedChannels.map {
        AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .dvd, channels: $0),
          processing: .processed,
        )
      },
    )
  }

  @Test
  @MainActor
  func `a request submitted while inactive re-discovers and claims no active rate`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: rejectedSampleRateSnapshot(appliedSampleRate: .cd))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)

    var requested = AudioInputConfigurationRequest.automatic
    requested.channels = .stereo
    let state = await coordinator.submit(requested, isRunning: true, isActive: false)

    // The session cannot apply the request, but the surface asking for
    // Stereo still gets a fresh read of what the platform offers.
    #expect(state.reconciliation == .deferred(.sessionInactive))
    #expect(state.capabilities.discovery == .resolved)
    #expect(state.capabilities.inputs.map(\.id) == ["mic"])
    // And nothing is claimed as applied: the raw session's rate is not a fact.
    #expect(state.applied == nil)
    #expect(state.capabilities.activeSampleRate == nil)
    #expect(await adapter.plans().isEmpty)
  }

  @Test
  @MainActor
  func `a route settling after a write is noticed without writing again`() async throws {
    // The readback right after the write reports no applied configuration
    // (the route has not settled); the next discovery reports one that
    // matches the plan. That `nil` → value transition must classify the
    // request as satisfied *without* another platform write — a second write
    // posts a route notification, which reconciles again, which is a loop.
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let unsettled = snapshot(
      input: input,
      options: [AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo)],
      applied: nil,
    )
    let adapter = ScriptedAdapter(snapshot: unsettled)
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)

    var requested = AudioInputConfigurationRequest.automatic
    requested.channels = .stereo
    let afterWrite = await coordinator.submit(requested, isRunning: true, isActive: true)
    #expect(await adapter.plans().count == 1)
    #expect(afterWrite.applied == nil)
    guard case .unsatisfied = afterWrite.reconciliation else {
      Issue.record("Expected an unsettled readback to be unsatisfied, got \(afterWrite.reconciliation)")
      return
    }

    await adapter.setSnapshot(
      snapshot(
        input: input,
        options: [AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo)],
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .dvd, channels: .stereo),
          processing: .processed,
        ),
      ),
    )
    let settled = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(settled.reconciliation == .satisfied)
    #expect(settled.applied?.format.channels == .stereo)
    #expect(settled.capabilities.activeSampleRate == .dvd)
    #expect(await adapter.plans().count == 1)
  }

  /// A stereo route that answers a 48 kHz request with 44.1 kHz, unless
  /// `appliedSampleRate` says the route has meanwhile changed its mind.
  private func rejectedSampleRateSnapshot(
    appliedSampleRate: SampleRate = .cd,
  ) -> PlatformAudioInputSnapshot {
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    return snapshot(
      input: input,
      options: [
        AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo)
      ],
      applied: AppliedAudioInputConfiguration(
        input: input,
        source: nil,
        format: InputConfiguration(sampleRate: appliedSampleRate, channels: .stereo),
        processing: .processed,
      ),
    )
  }

  private func monoSnapshot(
    appliedChannels: ChannelCount?,
  ) -> PlatformAudioInputSnapshot {
    let input = AudioInputSelection(
      id: "mic",
      name: "Mono Microphone",
      channelCount: .mono,
    )
    return snapshot(
      input: input,
      options: [
        AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .mono)
      ],
      applied: appliedChannels.map {
        AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .dvd, channels: $0),
          processing: .processed,
        )
      },
    )
  }

  private func snapshot(
    input: AudioInputSelection,
    options: [AudioSourceConfigurationOption],
    applied: AppliedAudioInputConfiguration?,
  ) -> PlatformAudioInputSnapshot {
    PlatformAudioInputSnapshot(
      capabilities: AudioInputConfigurationCapabilities(
        discovery: .resolved,
        inputs: [input],
        effectiveInput: input,
        sourceOptions: options,
        likelySampleRates: [.cd, .dvd],
        // Mirror the real adapters: the active rate is a fact only when an
        // applied configuration exists to read it from.
        activeSampleRate: applied?.format.sampleRate,
      ),
      applied: applied,
    )
  }

  @MainActor
  private func isolatedDefaults() throws -> UserDefaults {
    let name = "AudioInputConfigurationCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }
}
