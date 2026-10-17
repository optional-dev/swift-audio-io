// © GoodHatsLLC

#if os(iOS)
  public import AIOContracts
  import AIOSupport
  public import AVFAudio
  import Foundation
  public import Observation
  import os
  public import Tools

  private let log = SystemLog.make()

  /// The audio-session authority and the sole public owner of microphone
  /// configuration request, capability, reconciliation, and applied state.
  @MainActor
  @Observable
  public final class AudioEnvironmentManager: AudioSessionAuthority {
    public enum ManagerError: AudioError {
      public enum AudioSessionOperation: String, Sendable, Equatable, CustomStringConvertible {
        case setCategory
        case setAllowHapticsAndSystemSoundsDuringRecording
        case setPrefersNoInterruptionsFromSystemAlerts
        case setPrefersInterruptionOnRouteDisconnect
        case setPreferredInputNumberOfChannels
        case setPreferredInputOrientation
        case setActive

        public var description: String { rawValue }
      }

      case alreadyRunning
      case notRunning
      case audioEnvironment(AudioEnvironment.RequestError)
      case audioInput(AudioInput.PreferenceError)
      case audioSource(AudioSource.PreferenceError)
      case audioSessionFailed(operation: AudioSessionOperation, error: ErrorContext)
      case inputConfigurationDeferred(AudioInputConfigurationDeferral)
      case inputConfigurationUnsatisfied(AudioInputConfigurationIssue)
      case unexpected(ErrorContext)

      public var description: String {
        switch self {
        case .alreadyRunning:
          "AudioEnvironmentManager is already running"
        case .notRunning:
          "AudioEnvironmentManager is not running"
        case .audioEnvironment(let error):
          "Audio environment error: \(error)"
        case .audioInput(let error):
          "Audio input error: \(error)"
        case .audioSource(let error):
          "Audio source error: \(error)"
        case .audioSessionFailed(let operation, let error):
          "Audio session operation '\(operation)' failed: \(error)"
        case .inputConfigurationDeferred(let deferral):
          "Input configuration is deferred: \(deferral)"
        case .inputConfigurationUnsatisfied(let issue):
          "Input configuration is unsatisfied: \(issue)"
        case .unexpected(let error):
          "Unexpected error: \(error)"
        }
      }
    }

    /// Prepares the shared category without activating the audio session.
    @MainActor
    public static func prepareAudioSessionCategoryForAppLaunch() {
      do {
        try configureAudioSessionCategory(
          AVAudioSession.sharedInstance(),
          configuration: .recordingConfiguration,
        )
      } catch {
        log.error(
          "Failed to prepare audio session category on launch: \(error.localizedDescription, privacy: .public)",
        )
      }
    }

    /// Applies the session category and its companion preferences, skipping
    /// every write the session already reads back.
    ///
    /// This is called on every input-configuration apply. Writing `setCategory`
    /// unconditionally posts an `AVAudioSession.routeChangeNotification` with
    /// `.categoryChange`, which reconciles input configuration again and, if a
    /// recording is live, reconsiders its tap — so an unconditional write here
    /// is the first link in a self-sustaining loop.
    public nonisolated static func configureAudioSessionCategory(
      _ session: AVAudioSession,
      configuration: AudioSessionConfiguration,
    ) throws(ManagerError) {
      try AudioSessionAccess.result(catching: ManagerError.self) {
        () throws(ManagerError) -> Void in
        if session.category != configuration.category
          || session.mode != configuration.mode
          || session.categoryOptions != configuration.options
        {
          do {
            try session.setCategory(
              configuration.category,
              mode: configuration.mode,
              options: configuration.options,
            )
          } catch {
            throw .audioSessionFailed(operation: .setCategory, error: ErrorContext(error))
          }
        }
        do {
          try AudioSessionPreferenceWrite.perform(
            configuration.allowsHapticsAndSystemSoundsDuringRecording,
            whenNot: session.allowHapticsAndSystemSoundsDuringRecording,
          ) { try session.setAllowHapticsAndSystemSoundsDuringRecording($0) }
        } catch {
          throw .audioSessionFailed(
            operation: .setAllowHapticsAndSystemSoundsDuringRecording,
            error: ErrorContext(error),
          )
        }
        do {
          try AudioSessionPreferenceWrite.perform(
            configuration.prefersNoInterruptionsFromSystemAlerts,
            whenNot: session.prefersNoInterruptionsFromSystemAlerts,
          ) { try session.setPrefersNoInterruptionsFromSystemAlerts($0) }
        } catch {
          throw .audioSessionFailed(
            operation: .setPrefersNoInterruptionsFromSystemAlerts,
            error: ErrorContext(error),
          )
        }
        do {
          try AudioSessionPreferenceWrite.perform(
            configuration.prefersInterruptionOnRouteDisconnect,
            whenNot: session.prefersInterruptionOnRouteDisconnect,
          ) { try session.setPrefersInterruptionOnRouteDisconnect($0) }
        } catch {
          throw .audioSessionFailed(
            operation: .setPrefersInterruptionOnRouteDisconnect,
            error: ErrorContext(error),
          )
        }
      }.get()
    }

    public convenience init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = UserDefaults(),
    ) {
      self.init(
        env: env,
        errorManager: errorManager,
        defaults: defaults,
        sessionActivator: NativeAudioSessionActivator(),
      )
    }

    /// Creates a manager with a replaceable activation path.
    ///
    /// Tests substitute a fake to assert ordering without a live `AVAudioSession`.
    package init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = UserDefaults(),
      sessionActivator: any AudioSessionActivating,
    ) {
      let queue = SerialAsyncWorkQueue()
      let bluetoothPolicyStorage = Synchronized(BluetoothMicrophonePolicy.handsFree)
      let adapter = IOSAudioInputConfigurationAdapter(
        environment: env,
        inputWriteQueue: queue,
        bluetoothMicrophonePolicy: bluetoothPolicyStorage,
      )
      let coordinator = AudioInputConfigurationCoordinator(
        defaults: defaults,
        adapter: adapter,
      )
      self.env = env
      self.errorManager = errorManager
      self.sessionActivator = sessionActivator
      inputWriteQueue = queue
      platformInputAdapter = adapter
      inputConfigurationCoordinator = coordinator
      inputConfigurationState = coordinator.state
      bluetoothMicrophonePolicyStorage = bluetoothPolicyStorage
      sessionConfiguration = .recordingConfiguration(
        useMeasurement: coordinator.state.requested.processing == .measurement,
      )
    }

    /// Shared with the input-configuration adapter so its category
    /// reconfigurations honor the app's Bluetooth-microphone choice instead of
    /// silently reverting to `.handsFree`.
    @ObservationIgnored private let bluetoothMicrophonePolicyStorage:
      Synchronized<BluetoothMicrophonePolicy>

    /// How recording sessions treat Bluetooth microphones. Defaults to
    /// ``BluetoothMicrophonePolicy/handsFree``, the platform's historical
    /// behavior.
    ///
    /// Setting this also rebuilds ``sessionConfiguration`` from the recording
    /// factory, so the bootstrap path and input-configuration reconciliation
    /// stay in agreement about the category options.
    public var recordingBluetoothMicrophonePolicy: BluetoothMicrophonePolicy {
      get { bluetoothMicrophonePolicyStorage.withLock { $0 } }
      set {
        bluetoothMicrophonePolicyStorage.withLock { $0 = newValue }
        sessionConfiguration = .recordingConfiguration(
          useMeasurement: recordingUsesMeasurementMode,
          bluetoothMicrophone: newValue,
        )
      }
    }

    let env: AudioEnvironment
    let errorManager: any ErrorManaging
    @ObservationIgnored let inputWriteQueue: SerialAsyncWorkQueue

    /// The single activation path for this manager, fixed at initialization.
    @ObservationIgnored let sessionActivator: any AudioSessionActivating

    /// Serializes activation requests so two platform transitions are never in
    /// flight at once. Distinct from ``inputWriteQueue``, which serializes
    /// input-preference writes.
    @ObservationIgnored let audioSessionActivationQueue = SerialAsyncWorkQueue()

    /// Monotonically increasing id for accepted activation requests. A
    /// completion whose generation is stale has been superseded and must not
    /// write applied state.
    @ObservationIgnored var audioSessionActivationGeneration: UInt64 = 0

    /// The newest *requested* activation state, which can differ from
    /// ``isAudioSessionActive`` while a request is in flight. `nil` means no
    /// request has been made, so applied state is the current intent.
    @ObservationIgnored var requestedAudioSessionActive: Bool?
    @ObservationIgnored private let platformInputAdapter: IOSAudioInputConfigurationAdapter
    @ObservationIgnored private let inputConfigurationCoordinator:
      AudioInputConfigurationCoordinator
    @ObservationIgnored var callbackTasks = MainActorTaskRunner()

    /// Holds that keep the session active past the engine's release of its
    /// own demand. See ``acquireAudioSessionHold()``.
    @ObservationIgnored private var audioSessionHoldCount = 0
    /// Whether a release arrived while holds existed and is owed when the
    /// last hold goes.
    @ObservationIgnored private var deactivationDeferredByHold = false

    private var lifecycleRuntime: AudioEnvironmentLifecycleRuntime { .init(owner: self) }
    var sessionBootstrap: AudioSessionBootstrap { .init(owner: self) }
    var sessionController: AudioSessionController { .init(owner: self) }
    var routeObserver: AudioRouteObserver { .init(owner: self) }

    public var sessionConfiguration: AudioSessionConfiguration
    public internal(set) var isRunning = false
    public internal(set) var isAudioSessionActive = false
    public internal(set) var isReady = false {
      didSet {
        if isReady {
          try? readinessSignal.yield()
        }
      }
    }
    public private(set) var inputConfigurationState: AudioInputConfigurationState

    public var recordingUsesMeasurementMode: Bool {
      let processing =
        inputConfigurationState.applied?.processing
        ?? inputConfigurationState.requested.processing
      return processing == .measurement
    }

    private let readinessSignal = AwaitableBox<Void>()
    private let eventHub = AudioEnvironmentEventHub()

    public var onRequestAudioSessionActive: (@MainActor (Bool) -> Void)?

    public var audioSessionActive: Bool {
      get { isAudioSessionActive }
      set {
        guard newValue != isAudioSessionActive else { return }
        if let handler = onRequestAudioSessionActive {
          handler(newValue)
        } else {
          callbackTasks.run { [weak self] in
            guard let self else { return }
            do {
              try await setAudioSessionActive(newValue)
            } catch {
              errorManager.enqueue(
                error,
                visibility: .userInterrupting,
                userMessage: newValue
                  ? "Couldn't enable the microphone."
                  : "Couldn't disable the microphone.",
                context: "Audio session",
              )
            }
          }
        }
      }
    }

    @discardableResult
    public func addAudioSystemEventSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioSystemEvent) async -> Void,
    ) -> UUID {
      eventHub.addSubscriber(handler)
    }

    public func removeSubscriber(_ id: UUID) {
      eventHub.removeSubscriber(id)
    }

    public func requestInputConfiguration(
      _ requested: AudioInputConfigurationRequest,
    ) async -> AudioInputConfigurationState {
      sessionConfiguration = .recordingConfiguration(
        useMeasurement: requested.processing == .measurement,
        bluetoothMicrophone: recordingBluetoothMicrophonePolicy,
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
      await reconcileInputConfiguration()
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

    @MainActor
    func reconcileInputConfiguration(forcePlatformApply: Bool = false) async {
      inputConfigurationState = await inputConfigurationCoordinator.reconcile(
        isRunning: isRunning,
        isActive: isAudioSessionActive,
        forcePlatformApply: forcePlatformApply,
      )
    }

    @MainActor
    func markInputConfigurationUnavailable(
      _ deferral: AudioInputConfigurationDeferral,
    ) {
      inputConfigurationState = inputConfigurationCoordinator.markUnavailable(deferral)
    }

    @MainActor
    func updateOrientation(
      _ orientation: AVAudioSession.StereoOrientation,
    ) async {
      await platformInputAdapter.updateOrientation(orientation)
      if isAudioSessionActive {
        await reconcileInputConfiguration(forcePlatformApply: true)
      }
    }

    @MainActor
    public func readySignal() async throws(ManagerError) {
      guard isRunning else {
        assert(!isReady)
        throw .notRunning
      }
      await readinessSignal()
      assert(isReady)
    }

    public func setAudioSessionActive(_ active: Bool) async throws(ManagerError) {
      if active {
        deactivationDeferredByHold = false
      } else if audioSessionHoldCount > 0 {
        // The engine is done with the session, but a surface is not. Keep it
        // active and settle the release when the last hold goes.
        deactivationDeferredByHold = true
        log.info(
          "Audio session release deferred by \(self.audioSessionHoldCount, privacy: .public) hold(s)",
        )
        return
      }
      try await sessionController.setAudioSessionActive(active)
    }

    /// Keeps the session active — engaged under the recording category, with
    /// the latest request reconciled against the live route — until the
    /// returned hold is released. Activation failures throw, and no hold is
    /// taken in that case.
    public func acquireAudioSessionHold() async throws(ManagerError) -> AudioSessionHold {
      audioSessionHoldCount += 1
      do {
        try await sessionController.setAudioSessionActive(true)
      } catch {
        audioSessionHoldCount -= 1
        throw error
      }
      deactivationDeferredByHold = false
      return AudioSessionHold { [weak self] in
        await self?.releaseAudioSessionHold()
      }
    }

    private func releaseAudioSessionHold() async {
      audioSessionHoldCount = max(0, audioSessionHoldCount - 1)
      guard audioSessionHoldCount == 0, deactivationDeferredByHold else { return }
      deactivationDeferredByHold = false
      do {
        try await sessionController.setAudioSessionActive(false)
      } catch {
        errorManager.enqueue(
          error,
          visibility: .debug,
          userMessage: nil,
          context: "Audio session release after hold",
        )
      }
    }

    /// Re-reads capabilities and applied state from the platform without
    /// changing the request — a configuration surface's refresh.
    public func refreshInputConfiguration() async -> AudioInputConfigurationState {
      await reconcileInputConfiguration()
      return inputConfigurationState
    }

    /// The contract the next microphone capture starts with. Reconciles the
    /// latest request against the live route first; never refuses.
    public func resolveCaptureInputContract() async throws(ManagerError) -> CaptureInputContract {
      try await readySignal()
      await reconcileInputConfiguration()
      return CaptureInputContract.derive(from: inputConfigurationState)
    }

    public func run() async throws(ManagerError) {
      try await lifecycleRuntime.run(sessionConfiguration: sessionConfiguration)
    }

    @MainActor
    func dispatchAudioSystemEvent(_ event: AudioSystemEvent) async {
      await eventHub.dispatch(event)
    }
  }
#endif
