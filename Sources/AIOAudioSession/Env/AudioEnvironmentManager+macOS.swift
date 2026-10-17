// © GoodHatsLLC

#if os(macOS)
  public import AIOContracts
  public import Foundation
  public import Observation
  public import Tools

  @MainActor
  @Observable
  public final class AudioEnvironmentManager: AudioSessionAuthority {
    public enum ManagerError: AudioError {
      case alreadyRunning
      case notRunning
      case inputConfigurationDeferred(AudioInputConfigurationDeferral)
      case inputConfigurationUnsatisfied(AudioInputConfigurationIssue)

      public var description: String {
        switch self {
        case .alreadyRunning:
          "AudioEnvironmentManager is already running"
        case .notRunning:
          "AudioEnvironmentManager is not running"
        case .inputConfigurationDeferred(let deferral):
          "Input configuration is deferred: \(deferral)"
        case .inputConfigurationUnsatisfied(let issue):
          "Input configuration is unsatisfied: \(issue)"
        }
      }
    }

    @MainActor
    public static func prepareAudioSessionCategoryForAppLaunch() {}

    public convenience init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = UserDefaults(),
    ) {
      self.init(
        env: env,
        errorManager: errorManager,
        defaults: defaults,
        platformAudioBackend: PlatformAudioBackendFactory.makeDefault(),
      )
    }

    init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults,
      platformAudioBackend: any PlatformAudioBackend,
    ) {
      self.env = env
      self.errorManager = errorManager
      self.platformAudioBackend = platformAudioBackend
      let coordinator = AudioInputConfigurationCoordinator(
        defaults: defaults,
        adapter: MacOSAudioInputConfigurationAdapter(backend: platformAudioBackend),
      )
      inputConfigurationCoordinator = coordinator
      inputConfigurationState = coordinator.state
    }

    private let env: AudioEnvironment
    private let errorManager: any ErrorManaging
    private let platformAudioBackend: any PlatformAudioBackend
    private let inputConfigurationCoordinator: AudioInputConfigurationCoordinator
    private let callbackTasks = MainActorTaskRunner()
    /// Holds that keep the session active past the engine's release of its
    /// own demand. See ``acquireAudioSessionHold()``.
    @ObservationIgnored private var audioSessionHoldCount = 0
    /// Whether a release arrived while holds existed and is owed when the
    /// last hold goes.
    @ObservationIgnored private var deactivationDeferredByHold = false
    private var routeObserver: AudioRouteObserver { .init(owner: self) }
    private var backendRouteTask: MainActorOwnedWork?
    private var currentRoute = AudioRouteSnapshot(inputs: [], outputs: [])

    public var sessionConfiguration: AudioSessionConfiguration = .recordingConfiguration
    public private(set) var isRunning = false
    public private(set) var isReady = false
    public private(set) var isAudioSessionActive = false
    public private(set) var inputConfigurationState: AudioInputConfigurationState

    public var recordingUsesMeasurementMode: Bool {
      let processing =
        inputConfigurationState.applied?.processing
        ?? inputConfigurationState.requested.processing
      return processing == .measurement
    }

    public var onRequestAudioSessionActive: (@MainActor (Bool) -> Void)?

    public var audioSessionActive: Bool {
      get { isAudioSessionActive }
      set {
        guard newValue != isAudioSessionActive else { return }
        if let handler = onRequestAudioSessionActive {
          handler(newValue)
          return
        }
        callbackTasks.run { [weak self] in
          guard let self else { return }
          do {
            try await setAudioSessionActive(newValue)
          } catch {
            errorManager.enqueue(error)
          }
        }
      }
    }

    public func requestInputConfiguration(
      _ requested: AudioInputConfigurationRequest,
    ) async -> AudioInputConfigurationState {
      sessionConfiguration = .recordingConfiguration(
        useMeasurement: requested.processing == .measurement,
      )
      inputConfigurationState = await inputConfigurationCoordinator.submit(
        requested,
        isRunning: isRunning,
        isActive: isAudioSessionActive,
      )
      return inputConfigurationState
    }

    public func settleInputConfiguration() async throws(ManagerError)
      -> SettledMicrophoneInputConfiguration
    {
      try await readySignal()
      guard isAudioSessionActive else {
        throw .inputConfigurationDeferred(.sessionInactive)
      }
      inputConfigurationState = await inputConfigurationCoordinator.reconcile(
        isRunning: isRunning,
        isActive: true,
      )
      return try settledConfiguration(from: inputConfigurationState)
    }

    private func settledConfiguration(
      from state: AudioInputConfigurationState,
    ) throws(ManagerError) -> SettledMicrophoneInputConfiguration {
      switch state.reconciliation {
      case .satisfied:
        guard let applied = state.applied else {
          throw .inputConfigurationUnsatisfied(
            .readbackMismatch(
              expected: InputConfiguration(sampleRate: .dvd, channels: .mono),
              actual: nil,
            ),
          )
        }
        let preferredInput: AudioInputSelection? =
          switch state.requested.input {
          case .systemDefault: nil
          case .specific: applied.input
          }
        return SettledMicrophoneInputConfiguration(
          format: applied.format,
          preferredInput: preferredInput,
          source: applied.source,
          requestGeneration: state.requestedGeneration,
        )
      case .deferred(let deferral):
        throw .inputConfigurationDeferred(deferral)
      case .unsatisfied(let issue):
        throw .inputConfigurationUnsatisfied(issue)
      case .discovering, .reconciling:
        throw .inputConfigurationDeferred(.mediaServicesUnavailable)
      }
    }

    private func reconcileInputConfiguration(forcePlatformApply: Bool = false) async {
      inputConfigurationState = await inputConfigurationCoordinator.reconcile(
        isRunning: isRunning,
        isActive: isAudioSessionActive,
        forcePlatformApply: forcePlatformApply,
      )
    }

    private let eventHub = AudioEnvironmentEventHub()

    @discardableResult
    public func addAudioSystemEventSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioSystemEvent) async -> Void,
    ) -> UUID {
      eventHub.addSubscriber(handler)
    }

    public func removeSubscriber(_ id: UUID) {
      eventHub.removeSubscriber(id)
    }

    @MainActor
    public func readySignal() async throws(ManagerError) {
      guard isRunning else { throw .notRunning }
    }

    public func setAudioSessionActive(_ active: Bool) async throws(ManagerError) {
      if active {
        deactivationDeferredByHold = false
      } else if audioSessionHoldCount > 0 {
        // The engine is done with the session, but a surface is not. Keep it
        // active and settle the release when the last hold goes.
        deactivationDeferredByHold = true
        return
      }
      await applyAudioSessionActive(active)
    }

    private func applyAudioSessionActive(_ active: Bool) async {
      guard isRunning else { return }
      guard isAudioSessionActive != active else {
        if active {
          await reconcileInputConfiguration()
        }
        return
      }
      isAudioSessionActive = active
      if active {
        await reconcileInputConfiguration(forcePlatformApply: true)
      } else {
        inputConfigurationState = inputConfigurationCoordinator.markUnavailable(.sessionInactive)
      }
    }

    /// Keeps the session active until the returned hold is released.
    public func acquireAudioSessionHold() async throws(ManagerError) -> AudioSessionHold {
      audioSessionHoldCount += 1
      await applyAudioSessionActive(true)
      deactivationDeferredByHold = false
      return AudioSessionHold { [weak self] in
        await self?.releaseAudioSessionHold()
      }
    }

    private func releaseAudioSessionHold() async {
      audioSessionHoldCount = max(0, audioSessionHoldCount - 1)
      guard audioSessionHoldCount == 0, deactivationDeferredByHold else { return }
      deactivationDeferredByHold = false
      await applyAudioSessionActive(false)
    }

    /// Re-reads capabilities and applied state from the platform without
    /// changing the request — a configuration surface's refresh.
    public func refreshInputConfiguration() async -> AudioInputConfigurationState {
      await reconcileInputConfiguration()
      return inputConfigurationState
    }

    /// The contract the next microphone capture starts with. Reconciles the
    /// latest request first; never refuses.
    public func resolveCaptureInputContract() async throws(ManagerError) -> CaptureInputContract {
      try await readySignal()
      await reconcileInputConfiguration()
      return CaptureInputContract.derive(from: inputConfigurationState)
    }

    public func run() async throws(ManagerError) {
      guard !isRunning else { throw .alreadyRunning }
      isRunning = true
      defer { await finishRun() }
      await reconcileInputConfiguration()
      currentRoute = await platformAudioBackend.currentRoute()
      isReady = true

      await backendRouteTask?.cancel()
      backendRouteTask = routeObserver.makeRouteTask()

      await withCancellationOperation {}
    }

    private func finishRun() async {
      await withTaskCancellationShield {
        await backendRouteTask?.cancel()
        backendRouteTask = nil
        isAudioSessionActive = false
        inputConfigurationState =
          inputConfigurationCoordinator.markUnavailable(.environmentNotRunning)
        isReady = false
        isRunning = false
      }
    }

    private func notifyRouteChangeSubscribers(
      previousRoute: AudioRouteSnapshot,
      currentRoute: AudioRouteSnapshot,
    ) async {
      // The facts travel with the event so a live recording can tell a
      // no-op poll from a real change instead of rebuilding its tap on every
      // signature flap.
      let routeChange = AudioRouteChange(
        reason: .configurationChanged,
        previousRoute: previousRoute,
        currentRoute: currentRoute,
        session: await platformAudioBackend.currentInputSessionSnapshot(),
      )
      await eventHub.dispatch(.routeChanged(routeChange))
    }
  }

  extension AudioEnvironmentManager {
    private struct AudioRouteObserver {
      let owner: AudioEnvironmentManager

      @MainActor
      func makeRouteTask() -> MainActorOwnedWork {
        let backend = owner.platformAudioBackend
        return MainActorOwnedWork { [weak owner] in
          guard let owner else { return }
          for await _ in backend.routeChanges() {
            let previousRoute = owner.currentRoute
            await owner.reconcileInputConfiguration()
            let currentRoute = await backend.currentRoute()
            owner.currentRoute = currentRoute
            await owner.notifyRouteChangeSubscribers(
              previousRoute: previousRoute,
              currentRoute: currentRoute,
            )
          }
        }
      }
    }
  }

  private actor MacOSAudioInputConfigurationAdapter:
    PlatformAudioInputConfigurationAdapter
  {
    private let backend: any PlatformAudioBackend
    private var appliedPlan: PlatformAudioInputConfigurationPlan?

    init(backend: any PlatformAudioBackend) {
      self.backend = backend
    }

    func discover() async -> PlatformAudioInputSnapshot {
      let descriptors = await backend.availableInputs()
      return snapshot(descriptors: descriptors, appliedPlan: appliedPlan)
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      let descriptors = await backend.availableInputs()
      guard
        let descriptor = descriptors.first(where: { $0.id == plan.resolvedInput.id }),
        descriptor.channelCount >= plan.format.channels.count
      else {
        return snapshot(descriptors: descriptors, appliedPlan: nil)
      }
      appliedPlan = plan
      return snapshot(descriptors: descriptors, appliedPlan: plan)
    }

    private func snapshot(
      descriptors: [PlatformAudioInputDescriptor],
      appliedPlan: PlatformAudioInputConfigurationPlan?,
    ) -> PlatformAudioInputSnapshot {
      let inputs = descriptors.map(Self.selection)
      let endpointCapabilities = descriptors.map(Self.endpointCapabilities)
      let effectiveInput =
        descriptors.first(where: \.isDefault).map(Self.selection)
        ?? inputs.first
      let options = descriptors.flatMap { descriptor in
        let input = Self.selection(descriptor)
        var result = [
          AudioSourceConfigurationOption(
            inputID: input.id,
            source: nil,
            channels: .mono,
          )
        ]
        if descriptor.channelCount >= 2 {
          result.append(
            AudioSourceConfigurationOption(
              inputID: input.id,
              source: nil,
              channels: .stereo,
            ),
          )
        }
        return result
      }
      let applied: AppliedAudioInputConfiguration? = appliedPlan.flatMap { plan in
        guard inputs.contains(where: { $0.id == plan.resolvedInput.id }) else {
          return nil
        }
        return AppliedAudioInputConfiguration(
          input: plan.resolvedInput,
          source: plan.source,
          format: plan.format,
          processing: plan.processing,
        )
      }
      return PlatformAudioInputSnapshot(
        capabilities: AudioInputConfigurationCapabilities(
          discovery: descriptors.isEmpty ? .unavailable : .resolved,
          inputs: inputs,
          effectiveInput: effectiveInput,
          sourceOptions: options,
          likelySampleRates: Array(
            Set(SampleRate.common + descriptors.compactMap(\.nominalSampleRate)),
          ).sorted(),
          activeSampleRate: applied?.format.sampleRate,
          endpointCapabilities: endpointCapabilities,
        ),
        applied: applied,
      )
    }

    private static func selection(
      _ descriptor: PlatformAudioInputDescriptor,
    ) -> AudioInputSelection {
      AudioInputSelection(
        id: descriptor.id,
        name: descriptor.name,
        type: descriptor.type,
        channelCount: ChannelCount(count: descriptor.channelCount),
      )
    }

    private static func endpointCapabilities(
      _ descriptor: PlatformAudioInputDescriptor,
    ) -> AudioInputEndpointCapabilities {
      AudioInputEndpointCapabilities(
        inputID: descriptor.id,
        nativeSampleRateRanges: descriptor.nativeSampleRateRanges,
      )
    }
  }
#endif
