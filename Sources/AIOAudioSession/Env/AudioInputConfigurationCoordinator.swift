// © GoodHatsLLC

package import Foundation

package struct PlatformAudioInputSnapshot: Hashable, Sendable {
  package let capabilities: AudioInputConfigurationCapabilities
  package let applied: AppliedAudioInputConfiguration?

  package init(
    capabilities: AudioInputConfigurationCapabilities,
    applied: AppliedAudioInputConfiguration?,
  ) {
    self.capabilities = capabilities
    self.applied = applied
  }

  /// The facts about the route that a platform write could have changed on
  /// purpose — everything except the applied state, which the route settles
  /// on its own after a write. See `AudioInputConfigurationCoordinator`'s
  /// write barrier for why the two are kept apart.
  package var routeIdentity: RouteIdentity {
    RouteIdentity(
      discovery: capabilities.discovery,
      inputs: capabilities.inputs,
      effectiveInput: capabilities.effectiveInput,
      sourceOptions: capabilities.sourceOptions,
      likelySampleRates: capabilities.likelySampleRates,
      endpointCapabilities: capabilities.endpointCapabilities,
    )
  }

  package struct RouteIdentity: Hashable, Sendable {
    package let discovery: AudioInputConfigurationCapabilities.Discovery
    package let inputs: [AudioInputSelection]
    package let effectiveInput: AudioInputSelection?
    package let sourceOptions: [AudioSourceConfigurationOption]
    package let likelySampleRates: [SampleRate]
    package let endpointCapabilities: [AudioInputEndpointCapabilities]
  }

  /// The same discovery with every applied-state fact removed: no applied
  /// configuration and no active sample rate. Published while the session is
  /// inactive, when those two are not facts.
  package func withoutAppliedState() -> PlatformAudioInputSnapshot {
    PlatformAudioInputSnapshot(
      capabilities: AudioInputConfigurationCapabilities(
        discovery: capabilities.discovery,
        inputs: capabilities.inputs,
        effectiveInput: capabilities.effectiveInput,
        sourceOptions: capabilities.sourceOptions,
        likelySampleRates: capabilities.likelySampleRates,
        activeSampleRate: nil,
        endpointCapabilities: capabilities.endpointCapabilities,
      ),
      applied: nil,
    )
  }
}

package struct PlatformAudioInputConfigurationPlan: Hashable, Sendable {
  package let requestedGeneration: UInt64
  package let preferredInput: AudioInputSelection?
  package let resolvedInput: AudioInputSelection
  package let source: AudioSourceSelection?
  package let format: InputConfiguration
  /// The caller's sample-rate intent, carried alongside the resolved
  /// ``format``. `.automatic` means the adapter writes no rate preference and
  /// readback classification accepts any rate — `format.sampleRate` is then
  /// only the best current guess, used for diagnostics payloads.
  package let sampleRateIntent: AudioSampleRatePreference
  package let processing: AudioInputProcessingPreference

  /// What the adapter actually writes for this plan — the plan's identity for
  /// the platform write barrier.
  ///
  /// `format.sampleRate` is a *guess* under an `.automatic` intent: the
  /// resolver fills it from `capabilities.activeSampleRate`, a `SampleRate?`
  /// that flips between `nil` and a value as the session activates. Comparing
  /// whole plans made an unchanged request look like a new plan every time
  /// that optional resolved, and authorised a platform write for nothing —
  /// which posts a route notification, which reconciles again. Only the
  /// values the adapter writes take part here; the guessed rate does not.
  package struct WriteIdentity: Hashable, Sendable {
    package let requestedGeneration: UInt64
    package let preferredInput: AudioInputSelection?
    package let resolvedInput: AudioInputSelection
    package let source: AudioSourceSelection?
    package let channels: ChannelCount
    /// The exact rate the adapter writes, or `nil` when it writes none.
    package let sampleRate: SampleRate?
    package let processing: AudioInputProcessingPreference
  }

  package var writeIdentity: WriteIdentity {
    let sampleRate: SampleRate? =
      switch sampleRateIntent {
      case .automatic: nil
      case .exact(let rate): rate
      }
    return WriteIdentity(
      requestedGeneration: requestedGeneration,
      preferredInput: preferredInput,
      resolvedInput: resolvedInput,
      source: source,
      channels: format.channels,
      sampleRate: sampleRate,
      processing: processing,
    )
  }

  package init(
    requestedGeneration: UInt64,
    preferredInput: AudioInputSelection?,
    resolvedInput: AudioInputSelection,
    source: AudioSourceSelection?,
    format: InputConfiguration,
    sampleRateIntent: AudioSampleRatePreference,
    processing: AudioInputProcessingPreference,
  ) {
    self.requestedGeneration = requestedGeneration
    self.preferredInput = preferredInput
    self.resolvedInput = resolvedInput
    self.source = source
    self.format = format
    self.sampleRateIntent = sampleRateIntent
    self.processing = processing
  }
}

/// Internal platform seam for session preparation, input discovery, mutation,
/// and readback. Processing is established before resolving input choices;
/// source and channel capabilities may depend on the session mode.
///
/// iOS, macOS, and deterministic tests provide independent adapters. The
/// public interface remains the request/state pair on `AudioEnvironmentManager`.
package protocol PlatformAudioInputConfigurationAdapter: Sendable {
  func discover() async -> PlatformAudioInputSnapshot
  /// Establishes the processing mode before discovering mode-dependent input
  /// choices. Must skip platform writes when the session already matches.
  func prepare(processing: AudioInputProcessingPreference) async throws
  func apply(
    _ plan: PlatformAudioInputConfigurationPlan,
  ) async throws -> PlatformAudioInputSnapshot
}

extension PlatformAudioInputConfigurationAdapter {
  // Platforms without session processing modes need no preparation.
  package func prepare(processing _: AudioInputProcessingPreference) async throws {}
}

package enum AudioInputConfigurationResolution: Hashable, Sendable {
  case deferred(AudioInputConfigurationDeferral)
  case unsupported(AudioInputConfigurationIssue)
  case apply(PlatformAudioInputConfigurationPlan)
}

package enum AudioInputConfigurationResolver {
  package static func resolve(
    requested: AudioInputConfigurationRequest,
    generation: UInt64,
    capabilities: AudioInputConfigurationCapabilities,
    currentApplied: AppliedAudioInputConfiguration?,
  ) -> AudioInputConfigurationResolution {
    guard capabilities.discovery == .resolved else {
      return .deferred(.mediaServicesUnavailable)
    }

    let resolvedInput: AudioInputSelection
    let preferredInput: AudioInputSelection?
    switch requested.input {
    case .systemDefault:
      guard let effectiveInput = capabilities.effectiveInput else {
        return .deferred(.mediaServicesUnavailable)
      }
      resolvedInput = effectiveInput
      preferredInput = nil
    case .specific(let id):
      guard let input = capabilities.inputs.first(where: { $0.id == id }) else {
        return .deferred(.requestedInputUnavailable(id: id))
      }
      resolvedInput = input
      preferredInput = input
    }

    var options = capabilities.sourceOptions.filter { $0.inputID == resolvedInput.id }
    switch requested.source {
    case .automatic:
      break
    case .specific(let sourceID, let polarPatternID):
      guard options.contains(where: { $0.source?.id == sourceID }) else {
        return .unsupported(.unsupportedSource(id: sourceID))
      }
      if let polarPatternID,
        !options.contains(where: {
          $0.source?.id == sourceID && $0.source?.polarPatternID == polarPatternID
        })
      {
        return .unsupported(.unsupportedPolarPattern(id: polarPatternID))
      }
      options = options.filter {
        $0.source?.id == sourceID
          && (polarPatternID == nil || $0.source?.polarPatternID == polarPatternID)
      }
    }

    if let exactChannels = requested.channels.exactChannelCount {
      options = options.filter { $0.channels == exactChannels }
      guard !options.isEmpty else {
        return .unsupported(.unsupportedChannels(exactChannels))
      }
    }

    guard
      let option = options.sorted(by: optionPreference).first
        ?? sourceFreeOption(for: resolvedInput, requested: requested.channels)
    else {
      return .unsupported(
        .unsupportedChannels(requested.channels.exactChannelCount ?? .mono),
      )
    }

    // For `.automatic` this rate is never written or checked — it only fills
    // the plan's diagnostics payloads — so prefer facts over guesses: the
    // applied rate, then the session's live rate, then the standard guess.
    let sampleRate: SampleRate
    switch requested.sampleRate {
    case .automatic:
      if let currentApplied, currentApplied.input.id == resolvedInput.id {
        sampleRate = currentApplied.format.sampleRate
      } else if let activeSampleRate = capabilities.activeSampleRate {
        sampleRate = activeSampleRate
      } else if capabilities.likelySampleRates.contains(.dvd) {
        sampleRate = .dvd
      } else {
        sampleRate = capabilities.likelySampleRates.first ?? .dvd
      }
    case .exact(let requestedRate):
      sampleRate = requestedRate
    }

    return .apply(
      PlatformAudioInputConfigurationPlan(
        requestedGeneration: generation,
        preferredInput: preferredInput,
        resolvedInput: resolvedInput,
        source: option.source,
        format: InputConfiguration(sampleRate: sampleRate, channels: option.channels),
        sampleRateIntent: requested.sampleRate,
        processing: requested.processing,
      ),
    )
  }

  private static func optionPreference(
    _ lhs: AudioSourceConfigurationOption,
    _ rhs: AudioSourceConfigurationOption,
  ) -> Bool {
    if lhs.channels != rhs.channels {
      return lhs.channels > rhs.channels
    }
    return lhs.id < rhs.id
  }

  private static func sourceFreeOption(
    for input: AudioInputSelection,
    requested: AudioChannelPreference,
  ) -> AudioSourceConfigurationOption? {
    let channels = requested.exactChannelCount ?? (input.channelCount >= .stereo ? .stereo : .mono)
    guard channels <= input.channelCount else { return nil }
    return AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: channels)
  }
}

@MainActor
package final class AudioInputConfigurationRequestStore {
  package static let storageKey = "aio.audio_env.input_configuration_request.v1"

  private let defaults: UserDefaults

  package init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  package func load() -> AudioInputConfigurationRequest {
    guard let data = defaults.data(forKey: Self.storageKey) else {
      return .automatic
    }
    return (try? JSONDecoder().decode(AudioInputConfigurationRequest.self, from: data))
      ?? .automatic
  }

  package func save(_ request: AudioInputConfigurationRequest) {
    guard let data = try? JSONEncoder().encode(request) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}

/// How long the coordinator keeps retrying a platform write that failed
/// outright, before the write barrier holds and waits for a fresh trigger.
///
/// A *rejected* write — one the platform accepted but answered with a different
/// sample rate — is never retried on its own; the barrier holds immediately.
/// Only a thrown platform error gets a budget, because those are the ones that
/// are plausibly transient (a preferred input that vanished for the length of
/// one route transition, say).
package struct AudioInputReconciliationPolicy: Hashable, Sendable {
  /// Extra platform applies allowed after a thrown apply, before the barrier
  /// holds. Zero disables retrying entirely.
  package var platformFailureRetryBudget: Int

  package init(platformFailureRetryBudget: Int) {
    self.platformFailureRetryBudget = platformFailureRetryBudget
  }

  package static let `default` = AudioInputReconciliationPolicy(
    platformFailureRetryBudget: 2,
  )
}

/// Owns requested state, persistence, serialized reconciliation, and readback
/// classification for one audio environment.
///
/// ## Why reconciliation is coalesced and barriered
///
/// On iOS every `AVAudioSession` preference write — `setCategory`,
/// `setPreferredInput`, `setPreferredSampleRate`, and friends — may post
/// `AVAudioSession.routeChangeNotification` back at the process, usually with
/// `.categoryChange`. ``AudioEnvironmentManager/AudioRouteObserver`` reconciles
/// on every such notification. Two properties therefore have to hold or the
/// environment drives itself in circles, and takes a live recording tap with
/// it:
///
/// 1. **Single-flight.** At most one reconciliation runs at a time, and every
///    request that arrives during one is merged into a single follow-up run.
///    `reconcile` suspends at `adapter.apply`, and it is called from several
///    independent tasks (route notifications, input-availability notifications,
///    the periodic poll), so main-actor isolation alone does not serialize it.
/// 2. **A platform write barrier.** A reconciliation only writes to the
///    platform when something it can name has changed: a new requested
///    generation, a different resolved plan, different observed platform facts,
///    a deliberate forced apply, or a bounded retry after a thrown write.
///    Everything else is a *refresh*, and a refresh must not touch the
///    platform. This is what stops a stably unsatisfied state — an exact sample
///    rate the route refuses — from rewriting its preferences forever.
@MainActor
package final class AudioInputConfigurationCoordinator {
  package private(set) var state: AudioInputConfigurationState

  private let adapter: any PlatformAudioInputConfigurationAdapter
  private let store: AudioInputConfigurationRequestStore
  private let policy: AudioInputReconciliationPolicy
  private var generation: UInt64

  /// The last platform write and the facts observed immediately after it.
  ///
  /// `nil` means "nothing is known about the platform", which always authorises
  /// a write.
  private var writeBarrier: PlatformWriteBarrier?
  /// Preparation is idempotent on success. A rejected preparation is bounded
  /// separately because it must run before a full input plan can be resolved.
  private var preparationFailure: PreparationFailure?

  /// The reconciliation currently in flight, if any.
  private var activeRun: ReconcileRun?

  /// The single follow-up run standing for every request that arrived while
  /// ``activeRun`` was in flight, and its merged parameters.
  private var queuedRequest: ReconcileParameters?
  private var queuedTask: Task<AudioInputConfigurationState, Never>?

  private var nextRunID: UInt64 = 0

  package init(
    defaults: UserDefaults,
    adapter: any PlatformAudioInputConfigurationAdapter,
    policy: AudioInputReconciliationPolicy = .default,
  ) {
    self.adapter = adapter
    self.policy = policy
    store = AudioInputConfigurationRequestStore(defaults: defaults)
    let requested = store.load()
    generation = 0
    state = .initial(requested: requested)
  }

  package func submit(
    _ requested: AudioInputConfigurationRequest,
    isRunning: Bool,
    isActive: Bool,
  ) async -> AudioInputConfigurationState {
    generation &+= 1
    store.save(requested)
    state = AudioInputConfigurationState(
      requested: requested,
      requestedGeneration: generation,
      applied: isActive ? state.applied : nil,
      capabilities: state.capabilities,
      reconciliation: isRunning
        ? (isActive ? .reconciling : .deferred(.sessionInactive))
        : .deferred(.environmentNotRunning),
    )
    guard isRunning else { return state }
    // An inactive session cannot apply the request, but it can still say what
    // the platform currently offers — a configuration surface asking for
    // Stereo deserves a fresh capability read, not last poll's.
    return await reconcile(isRunning: true, isActive: isActive)
  }

  /// Reconciles requested state against the platform, coalescing concurrent
  /// callers.
  ///
  /// Callers that arrive while a reconciliation is in flight do not start a
  /// second one. They are merged into a single follow-up run — one that still
  /// re-discovers, so a genuine route change arriving mid-apply is not lost,
  /// but that will not reissue platform preferences unless the write barrier
  /// authorises it.
  package func reconcile(
    isRunning: Bool,
    isActive: Bool,
    forcePlatformApply: Bool = false,
  ) async -> AudioInputConfigurationState {
    let parameters = ReconcileParameters(
      isRunning: isRunning,
      isActive: isActive,
      forcePlatformApply: forcePlatformApply,
    )

    guard activeRun != nil else {
      return await beginRun(parameters).value
    }

    // One follow-up run stands for every request that arrives during an
    // in-flight one. Merging rather than queueing keeps the work bounded at
    // "one running, one pending" no matter how many notifications land.
    queuedRequest = queuedRequest?.merging(parameters) ?? parameters
    if let queuedTask {
      return await queuedTask.value
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return AudioInputConfigurationState.initial() }
      return await drainQueuedRun()
    }
    queuedTask = task
    return await task.value
  }

  /// Waits out every in-flight run, then performs the merged follow-up.
  @MainActor
  private func drainQueuedRun() async -> AudioInputConfigurationState {
    while let activeRun {
      _ = await activeRun.task.value
    }
    guard let parameters = queuedRequest else { return state }
    queuedRequest = nil
    queuedTask = nil
    return await beginRun(parameters).value
  }

  /// Starts a run and publishes it as ``activeRun`` *before* returning, so a
  /// caller that arrives at the next suspension point sees it and queues.
  @MainActor
  private func beginRun(
    _ parameters: ReconcileParameters,
  ) -> Task<AudioInputConfigurationState, Never> {
    nextRunID &+= 1
    let id = nextRunID
    let task = Task { @MainActor [weak self] in
      guard let self else { return AudioInputConfigurationState.initial() }
      defer {
        if activeRun?.id == id { activeRun = nil }
      }
      return await performReconcile(parameters)
    }
    activeRun = ReconcileRun(id: id, task: task)
    return task
  }

  @MainActor
  private func performReconcile(
    _ parameters: ReconcileParameters,
  ) async -> AudioInputConfigurationState {
    let isRunning = parameters.isRunning
    let isActive = parameters.isActive
    let forcePlatformApply = parameters.forcePlatformApply
    while true {
      let requested = state.requested
      let requestedGeneration = generation
      var snapshot = await adapter.discover()
      guard requestedGeneration == generation else { continue }

      guard isRunning else {
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: nil,
          reconciliation: .deferred(.environmentNotRunning),
        )
      }
      guard isActive else {
        // No applied configuration exists while inactive, so no active rate
        // can be claimed either: the raw session reports a routeless default
        // (typically 44.1 kHz) that is not the microphone's rate.
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot.withoutAppliedState(),
          applied: nil,
          reconciliation: .deferred(.sessionInactive),
        )
      }

      // Mode changes can add/remove inputs, sources, polar patterns, and
      // channel choices. Resolving those choices first can reject the request
      // before the mode setter is reached, trapping the session in Raw.
      let previousFailure = preparationFailure.flatMap {
        $0.generation == requestedGeneration && $0.route == snapshot.routeIdentity ? $0 : nil
      }
      if let previousFailure, previousFailure.retryBudget == 0, !forcePlatformApply {
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: snapshot.applied,
          reconciliation: .unsatisfied(previousFailure.issue),
        )
      }
      do {
        try await adapter.prepare(processing: requested.processing)
        preparationFailure = nil
        snapshot = await adapter.discover()
        guard requestedGeneration == generation else { continue }
      } catch {
        snapshot = await adapter.discover()
        guard requestedGeneration == generation else { continue }
        let issue = AudioInputConfigurationIssue.platformOperationFailed(String(describing: error))
        preparationFailure = PreparationFailure(
          generation: requestedGeneration,
          route: snapshot.routeIdentity,
          retryBudget: previousFailure.map { max(0, $0.retryBudget - 1) }
            ?? policy.platformFailureRetryBudget,
          issue: issue,
        )
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: snapshot.applied,
          reconciliation: .unsatisfied(issue),
        )
      }
      let preparedApplied = snapshot.applied

      switch AudioInputConfigurationResolver.resolve(
        requested: requested,
        generation: requestedGeneration,
        capabilities: snapshot.capabilities,
        currentApplied: preparedApplied,
      ) {
      case .deferred(let reason):
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: preparedApplied,
          reconciliation: .deferred(reason),
        )
      case .unsupported(let issue):
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: preparedApplied,
          reconciliation: .unsatisfied(issue),
        )
      case .apply(let plan):
        // Route notifications and periodic discovery are refreshes, not new
        // configuration intent. Reissuing AVAudioSession preferences generates
        // another route notification, which drives another reconciliation — and
        // if a recording is live, another tap teardown. The barrier answers the
        // only question that matters: has anything changed since the write that
        // produced the state we are already publishing?
        guard authorisePlatformApply(plan: plan, snapshot: snapshot, force: forcePlatformApply)
        else {
          // A refresh: no write, but the classification is made against what
          // the platform reports *now*, never against the readback the last
          // write happened to see. A route settling after a write — an
          // applied configuration appearing where the readback had none — is
          // exactly the change this has to notice, and it must notice it
          // without writing again. The barrier then tracks this reading, so
          // a later genuine move is measured from the settled state.
          writeBarrier?.observed = snapshot
          return publish(
            requested: requested,
            generation: requestedGeneration,
            snapshot: snapshot,
            applied: preparedApplied,
            reconciliation: Self.classify(readback: preparedApplied, expected: plan),
          )
        }
        _ = publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: preparedApplied,
          reconciliation: .reconciling,
        )
        do {
          let readback = try await adapter.apply(plan)
          let reconciliation = Self.classify(readback: readback.applied, expected: plan)
          // The barrier records the facts observed *after* the write, so the
          // next discovery compares like with like. A rejected preference
          // settles here: the plan and the observed snapshot both stay put, so
          // no later refresh writes again.
          writeBarrier = PlatformWriteBarrier(
            plan: plan,
            observed: readback,
            retryBudget: 0,
          )
          guard requestedGeneration == generation else {
            state = AudioInputConfigurationState(
              requested: state.requested,
              requestedGeneration: generation,
              applied: readback.applied,
              capabilities: readback.capabilities,
              reconciliation: .reconciling,
            )
            continue
          }
          return publish(
            requested: requested,
            generation: requestedGeneration,
            snapshot: readback,
            applied: readback.applied,
            reconciliation: reconciliation,
          )
        } catch {
          let readback = await adapter.discover()
          let failure = AudioInputConfigurationReconciliation.unsatisfied(
            .platformOperationFailed(String(describing: error)),
          )
          // A thrown write is the one failure mode that may be transient, so it
          // is the one that gets a bounded retry budget rather than an
          // immediate barrier. The budget is *carried*, not reissued: a run of
          // identical failures has to exhaust it, or the retry would be
          // unbounded.
          writeBarrier = PlatformWriteBarrier(
            plan: plan,
            observed: readback,
            retryBudget: carriedFailureRetryBudget(plan: plan, observed: readback),
          )
          guard requestedGeneration == generation else { continue }
          return publish(
            requested: requested,
            generation: requestedGeneration,
            snapshot: readback,
            applied: readback.applied,
            reconciliation: failure,
          )
        }
      }
    }
  }

  package func markUnavailable(
    _ deferral: AudioInputConfigurationDeferral,
  ) -> AudioInputConfigurationState {
    // Deactivation and media-services loss both discard platform state that the
    // barrier was describing, so nothing is known any more and recovery is free
    // to write once.
    writeBarrier = nil
    preparationFailure = nil
    state = AudioInputConfigurationState(
      requested: state.requested,
      requestedGeneration: generation,
      applied: nil,
      capabilities: state.capabilities,
      reconciliation: .deferred(deferral),
    )
    return state
  }

  /// Decides whether this reconciliation may write to the platform, and
  /// consumes one unit of retry budget when it does so on a failure's account.
  ///
  /// The authorised triggers are exactly: a deliberate forced apply, no known
  /// platform state, a changed plan (which subsumes a changed requested
  /// generation, because the generation is stamped into the plan), a changed
  /// *route* — the inputs and options the platform offers — or remaining
  /// retry budget after a thrown write.
  ///
  /// Applied state is deliberately not a trigger. A readback taken right
  /// after a preference write routinely reports no applied configuration
  /// (the route has not settled), and the next discovery reports one. That
  /// `nil` → value transition is the route catching up with the write, not a
  /// reason to write again — and writing again posts a route notification,
  /// which reconciles again, which is the loop this barrier exists to break.
  private func authorisePlatformApply(
    plan: PlatformAudioInputConfigurationPlan,
    snapshot: PlatformAudioInputSnapshot,
    force: Bool,
  ) -> Bool {
    if force { return true }
    guard var barrier = writeBarrier else { return true }
    guard barrier.plan.writeIdentity == plan.writeIdentity,
      barrier.observed.routeIdentity == snapshot.routeIdentity,
      !Self.appliedStateMoved(from: barrier.observed.applied, to: snapshot.applied)
    else {
      return true
    }
    guard barrier.retryBudget > 0 else { return false }
    barrier.retryBudget -= 1
    writeBarrier = barrier
    return true
  }

  /// The retry budget a fresh failure barrier inherits.
  ///
  /// A repeat of the same failure, under the same observed facts, keeps
  /// spending the budget the previous attempt left behind. Anything else — a
  /// different plan, or facts that moved — is a new situation and starts over.
  private func carriedFailureRetryBudget(
    plan: PlatformAudioInputConfigurationPlan,
    observed: PlatformAudioInputSnapshot,
  ) -> Int {
    guard let barrier = writeBarrier,
      barrier.plan.writeIdentity == plan.writeIdentity,
      barrier.observed.routeIdentity == observed.routeIdentity,
      !Self.appliedStateMoved(from: barrier.observed.applied, to: observed.applied)
    else {
      return policy.platformFailureRetryBudget
    }
    return barrier.retryBudget
  }

  private func publish(
    requested: AudioInputConfigurationRequest,
    generation: UInt64,
    snapshot: PlatformAudioInputSnapshot,
    applied: AppliedAudioInputConfiguration?,
    reconciliation: AudioInputConfigurationReconciliation,
  ) -> AudioInputConfigurationState {
    state = AudioInputConfigurationState(
      requested: requested,
      requestedGeneration: generation,
      applied: applied,
      capabilities: snapshot.capabilities,
      reconciliation: reconciliation,
    )
    return state
  }

  private static func classify(
    readback: AppliedAudioInputConfiguration?,
    expected: PlatformAudioInputConfigurationPlan,
  ) -> AudioInputConfigurationReconciliation {
    guard let readback else {
      return .unsatisfied(.readbackMismatch(expected: expected.format, actual: nil))
    }
    // `.automatic` wrote no rate preference, so every readback rate is the
    // correct one — only an `.exact` intent can be rejected.
    if case .exact(let requestedRate) = expected.sampleRateIntent {
      guard readback.format.sampleRate == requestedRate else {
        return .unsatisfied(
          .rejectedSampleRate(
            requested: requestedRate,
            applied: readback.format.sampleRate,
          ),
        )
      }
    }
    guard readback.input.id == expected.resolvedInput.id,
      readback.format.channels == expected.format.channels,
      readback.processing == expected.processing,
      sourceMatches(readback.source, expected.source)
    else {
      return .unsatisfied(
        .readbackMismatch(expected: expected.format, actual: readback.format),
      )
    }
    return .satisfied
  }

  /// One reconciliation's parameters, as supplied by its caller.
  private struct ReconcileParameters: Hashable {
    var isRunning: Bool
    var isActive: Bool
    var forcePlatformApply: Bool

    /// Folds a later request into a pending one. The newest lifecycle facts
    /// win; a forced apply is sticky, because dropping it would lose the one
    /// trigger that exists to re-establish platform state the session may have
    /// silently discarded.
    func merging(_ other: ReconcileParameters) -> ReconcileParameters {
      ReconcileParameters(
        isRunning: other.isRunning,
        isActive: other.isActive,
        forcePlatformApply: forcePlatformApply || other.forcePlatformApply,
      )
    }
  }

  private struct ReconcileRun {
    let id: UInt64
    let task: Task<AudioInputConfigurationState, Never>
  }

  /// What the coordinator last asked the platform for, and the facts it read
  /// back immediately afterwards.
  private struct PlatformWriteBarrier {
    let plan: PlatformAudioInputConfigurationPlan
    var observed: PlatformAudioInputSnapshot
    var retryBudget: Int
  }

  private struct PreparationFailure {
    let generation: UInt64
    let route: PlatformAudioInputSnapshot.RouteIdentity
    let retryBudget: Int
    let issue: AudioInputConfigurationIssue
  }

  /// Whether the platform's applied state moved between two *settled*
  /// readings — a different rate, channel count, input, or source on the
  /// same route. A reading with no applied state is not a move in either
  /// direction: `nil` → value is the route catching up with the last write,
  /// and value → `nil` has nothing to write to.
  private static func appliedStateMoved(
    from previous: AppliedAudioInputConfiguration?,
    to current: AppliedAudioInputConfiguration?,
  ) -> Bool {
    guard let previous, let current else { return false }
    return previous != current
  }

  private static func sourceMatches(
    _ applied: AudioSourceSelection?,
    _ expected: AudioSourceSelection?,
  ) -> Bool {
    switch (applied, expected) {
    case (nil, nil):
      true
    case (.some(let applied), .some(let expected)):
      applied.id == expected.id
        && (expected.polarPatternID == nil
          || applied.polarPatternID == expected.polarPatternID)
    case (.none, .some), (.some, .none):
      false
    }
  }
}
