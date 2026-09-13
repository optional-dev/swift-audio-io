// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import AVFAudio
  import Tools

  actor IOSAudioInputConfigurationAdapter: PlatformAudioInputConfigurationAdapter {
    private let environment: AudioEnvironment
    private let inputWriteQueue: SerialAsyncWorkQueue
    private let bluetoothMicrophonePolicy: Synchronized<BluetoothMicrophonePolicy>
    private var orientation: AVAudioSession.StereoOrientation = .none

    init(
      environment: AudioEnvironment,
      inputWriteQueue: SerialAsyncWorkQueue,
      bluetoothMicrophonePolicy: Synchronized<BluetoothMicrophonePolicy> =
        Synchronized(.handsFree),
    ) {
      self.environment = environment
      self.inputWriteQueue = inputWriteQueue
      self.bluetoothMicrophonePolicy = bluetoothMicrophonePolicy
    }

    func updateOrientation(_ orientation: AVAudioSession.StereoOrientation) {
      self.orientation = orientation
    }

    func discover() async -> PlatformAudioInputSnapshot {
      Self.snapshot(environment: environment)
    }

    func prepare(processing: AudioInputProcessingPreference) async throws {
      let environment = environment
      let bluetoothMicrophone = bluetoothMicrophonePolicy.withLock { $0 }
      let result: Result<Void, AudioEnvironmentManager.ManagerError>? =
        await inputWriteQueue.submit {
          () -> Result<Void, AudioEnvironmentManager.ManagerError> in
          do {
            try AudioEnvironmentManager.configureAudioSessionCategory(
              environment.session,
              configuration: .recordingConfiguration(
                useMeasurement: processing == .measurement,
                bluetoothMicrophone: bluetoothMicrophone,
              ),
            )
            return .success(())
          } catch let error as AudioEnvironmentManager.ManagerError {
            return .failure(error)
          } catch {
            return .failure(.unexpected(ErrorContext(error)))
          }
        }
      guard let result else { throw AudioEnvironmentManager.ManagerError.notRunning }
      try result.get()
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      let orientation = orientation
      let environment = environment
      let result: Result<Void, AudioEnvironmentManager.ManagerError>? =
        await inputWriteQueue.submit {
          () -> Result<Void, AudioEnvironmentManager.ManagerError> in
          do {
            let preferredInput = plan.preferredInput.flatMap { selection in
              environment.availableInputs.first(where: { $0.id == selection.id })
            }
            if plan.preferredInput != nil, preferredInput == nil {
              return .failure(
                .inputConfigurationDeferred(
                  .requestedInputUnavailable(id: plan.resolvedInput.id),
                ),
              )
            }
            try environment.request(input: preferredInput)

            let resolvedInput =
              environment.availableInputs.first(where: { $0.id == plan.resolvedInput.id })
              ?? environment.input
            if let sourceSelection = plan.source {
              guard
                let resolvedInput,
                let source = resolvedInput.availableSources.first(where: {
                  $0.id == sourceSelection.id
                })
              else {
                return .failure(
                  .inputConfigurationUnsatisfied(
                    .unsupportedSource(id: sourceSelection.id),
                  ),
                )
              }
              if let patternID = sourceSelection.polarPatternID {
                guard
                  let pattern = source.supportedPolarPatterns.first(where: {
                    $0.id == patternID
                  })
                else {
                  return .failure(
                    .inputConfigurationUnsatisfied(
                      .unsupportedPolarPattern(id: patternID),
                    ),
                  )
                }
                try source.set(preferredPolarPattern: pattern)
              }
              try resolvedInput.set(preferredSource: source)
            }

            do {
              try AudioSessionPreferenceWrite.perform(
                plan.format.channels.count,
                whenNot: environment.session.preferredInputNumberOfChannels,
              ) { try environment.session.setPreferredInputNumberOfChannels($0) }
            } catch {
              return .failure(
                .audioSessionFailed(
                  operation: .setPreferredInputNumberOfChannels,
                  error: ErrorContext(error),
                ),
              )
            }

            // `.automatic` writes no rate preference: there is nothing to
            // prefer, the route's own rate is always correct, and skipping the
            // write avoids a needless route-change notification.
            if case .exact(let requestedRate) = plan.sampleRateIntent {
              try environment.request(sampleRate: requestedRate)
            }

            if plan.format.channels >= .stereo, orientation != .none {
              do {
                try AudioSessionPreferenceWrite.perform(
                  orientation,
                  whenNot: environment.session.preferredInputOrientation,
                ) { try environment.session.setPreferredInputOrientation($0) }
              } catch {
                return .failure(
                  .audioSessionFailed(
                    operation: .setPreferredInputOrientation,
                    error: ErrorContext(error),
                  ),
                )
              }
            }
            return .success(())
          } catch let error as AudioEnvironmentManager.ManagerError {
            return .failure(error)
          } catch let error as AudioEnvironment.RequestError {
            return .failure(.audioEnvironment(error))
          } catch let error as AudioInput.PreferenceError {
            return .failure(.audioInput(error))
          } catch let error as AudioSource.PreferenceError {
            return .failure(.audioSource(error))
          } catch {
            return .failure(.unexpected(ErrorContext(error)))
          }
        }

      guard let result else {
        throw AudioEnvironmentManager.ManagerError.notRunning
      }
      try result.get()
      return Self.snapshot(environment: environment)
    }

    private nonisolated static func snapshot(
      environment: AudioEnvironment,
    ) -> PlatformAudioInputSnapshot {
      let availableInputs = environment.availableInputs
      let currentInput = environment.input
      let effectiveInput =
        currentInput
        ?? availableInputs.first(where: { $0.avAudio.portType == .builtInMic })
        ?? availableInputs.first
      let inputs = availableInputs.map(AudioInputSelection.init(input:))
      let options = availableInputs.flatMap(sourceOptions)
      let endpointCapabilities = availableInputs.map(endpointCapabilities)
      let applied = appliedConfiguration(
        environment: environment,
        currentInput: currentInput,
      )
      let likelySampleRates = Array(
        Set(SampleRate.common + [environment.sampleRate]),
      ).sorted()
      return PlatformAudioInputSnapshot(
        capabilities: AudioInputConfigurationCapabilities(
          discovery: availableInputs.isEmpty ? .unavailable : .resolved,
          inputs: inputs,
          effectiveInput: effectiveInput.map(AudioInputSelection.init(input:)),
          sourceOptions: options,
          likelySampleRates: likelySampleRates,
          activeSampleRate: applied?.format.sampleRate,
          endpointCapabilities: endpointCapabilities,
        ),
        applied: applied,
      )
    }

    private nonisolated static func endpointCapabilities(
      input: AudioInput
    ) -> AudioInputEndpointCapabilities {
      let bluetooth = input.avAudio.bluetoothMicrophoneExtension.map { extensionValue in
        BluetoothMicrophoneCapabilities(
          highQualityRecording: AudioInputFeatureCapability(
            isSupported: extensionValue.highQualityRecording.isSupported,
            isEnabled: extensionValue.highQualityRecording.isEnabled,
          ),
          farFieldCapture: AudioInputFeatureCapability(
            isSupported: extensionValue.farFieldCapture.isSupported,
            isEnabled: extensionValue.farFieldCapture.isEnabled,
          ),
        )
      }
      return AudioInputEndpointCapabilities(
        inputID: input.id,
        bluetoothMicrophone: bluetooth,
      )
    }

    private nonisolated static func sourceOptions(
      input: AudioInput,
    ) -> [AudioSourceConfigurationOption] {
      guard !input.availableSources.isEmpty else {
        var options = [
          AudioSourceConfigurationOption(
            inputID: input.id,
            source: nil,
            channels: .mono,
          )
        ]
        if input.channelCount >= .stereo {
          options.append(
            AudioSourceConfigurationOption(
              inputID: input.id,
              source: nil,
              channels: .stereo,
            ),
          )
        }
        return options
      }

      return input.availableSources.flatMap { source in
        let patterns = source.supportedPolarPatterns
        if patterns.isEmpty {
          var options = [
            AudioSourceConfigurationOption(
              inputID: input.id,
              source: AudioSourceSelection(id: source.id, name: source.name),
              channels: .mono,
            )
          ]
          if input.channelCount >= .stereo {
            options.append(
              AudioSourceConfigurationOption(
                inputID: input.id,
                source: AudioSourceSelection(id: source.id, name: source.name),
                channels: .stereo,
              )
            )
          }
          return options
        }
        return patterns.map { pattern in
          let channels: ChannelCount = pattern == .stereo ? .stereo : .mono
          return AudioSourceConfigurationOption(
            inputID: input.id,
            source: AudioSourceSelection(
              id: source.id,
              name: source.name,
              polarPatternID: pattern.id,
              polarPatternName: pattern.name,
            ),
            channels: channels,
          )
        }
      }
    }

    private nonisolated static func appliedConfiguration(
      environment: AudioEnvironment,
      currentInput: AudioInput?,
    ) -> AppliedAudioInputConfiguration? {
      guard let currentInput else { return nil }
      let sampleRate = environment.session.sampleRate
      let channels = environment.session.inputNumberOfChannels
      guard sampleRate > 0, channels > 0 else { return nil }

      let source = environment.source.map { source in
        AudioSourceSelection(
          id: source.id,
          name: source.name,
          polarPatternID: source.avAudio.selectedPolarPattern?.rawValue,
          polarPatternName: source.avAudio.selectedPolarPattern?.rawValue,
        )
      }
      return AppliedAudioInputConfiguration(
        input: AudioInputSelection(input: currentInput),
        source: source,
        format: InputConfiguration(
          sampleRate: SampleRate(sampleRate),
          channels: ChannelCount(platform: AVAudioChannelCount(channels)),
        ),
        processing: environment.session.mode == .measurement ? .measurement : .processed,
      )
    }
  }
#endif
