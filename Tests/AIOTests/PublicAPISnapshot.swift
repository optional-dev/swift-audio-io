// © GoodHatsLLC

import AudioIO
import Testing

// Public-API snapshot fixture.
//
// Each test below references the curated `public typealias` declarations
// from `Sources/AudioIO/Exports.swift`. The compile itself is the
// assertion: if a future change drops one of these symbols from the
// `import AudioIO` surface, this file fails to build, which is exactly
// the canary we want.
//
// Adding a symbol to AudioIO's curated surface should be paired with a
// new line here so the surface is pinned. Removing a symbol must be a
// deliberate decision visible in this file.

@Test("Public API snapshot — AIOAudioSession re-exports compile via AudioIO")
func publicAPISnapshot_AIOAudioSession() throws {
  _ = AudioChannel.self
  _ = AudioEnvironment.self
  _ = AudioEnvironmentManager.self
  _ = AppliedAudioInputConfiguration.self
  _ = AudioChannelPreference.self
  _ = AudioInputConfigurationCapabilities.self
  _ = AudioInputEndpointCapabilities.self
  _ = AudioInputFeatureCapability.self
  _ = AudioInputConfigurationDeferral.self
  _ = AudioInputConfigurationIssue.self
  _ = AudioInputConfigurationReconciliation.self
  _ = AudioInputConfigurationRequest.self
  _ = AudioInputConfigurationState.self
  _ = CaptureInputContract.self
  _ = CaptureSubstitution.self
  _ = AudioSessionHold.self
  _ = AudioInput.self
  _ = AudioInputPreference.self
  _ = AudioInputProcessingPreference.self
  _ = AudioInputSelection.self
  _ = AudioSampleRatePreference.self
  _ = AudioSampleRateRange.self
  _ = BluetoothMicrophoneCapabilities.self
  _ = AudioPortSnapshot.self
  _ = AudioRouteChange.self
  _ = AudioRouteChangeReason.self
  _ = AudioRouteSnapshot.self
  _ = AudioSessionSnapshot.self
  _ = AudioSystemEvent.self
  _ = AudioSessionDeactivation.self
  _ = AudioSessionDeactivationSource.self
  _ = AudioInterruptionReason.self
  _ = AudioSessionConfiguration.self
  _ = AudioSource.self
  _ = AudioSourceConfigurationOption.self
  _ = AudioSourcePreference.self
  _ = AudioSourceSelection.self
  _ = AnyErrorManager.self
  _ = AudioInputFacts.self
  _ = BitDepth.self
  _ = CaptureConfigurationIssue.self
  _ = CaptureConfigurationValidation.self
  _ = ChannelCount.self
  _ = EncodingQuality.self
  _ = ErrorManager.self
  _ = (any ErrorManaging).self
  _ = FileFormat.self
  _ = InputConfiguration.self
  _ = MicrophoneRecordingInput.self
  _ = RecordingInput.self
  #if os(macOS)
    _ = SystemAudioProcess.self
    _ = SystemAudioProcessCatalog.self
    _ = SystemAudioProcessObjectID.self
    _ = SystemAudioProcessSelection.self
    _ = SystemAudioProcessSelection.Mode.self
    _ = SystemAudioRecordingInput.self
  #endif
  _ = MockErrorManager.self
  #if canImport(UIKit) && !os(macOS)
    _ = OrientationObserver.self
  #endif
  _ = OutputConfiguration.self
  _ = OutputConfigurationManager.self
  _ = PolarPattern.self
  _ = RecordingConfiguration.self
  _ = RecordingFilename.self
  _ = ReportedError.self
  _ = Reporter<ReportedError>.self
  _ = SampleRate.self
  _ = SettledMicrophoneInputConfiguration.self
  // Module-qualified: swift-testing also exports a `SourceLocation`, so the bare
  // name is ambiguous here. The point of this snapshot is that `AudioIO` re-exports
  // its own type, so name it explicitly.
  _ = AudioIO.SourceLocation.self
  _ = (any TypeDescribable).self
}

@Test("Public API snapshot — AIOContracts re-exports compile via AudioIO")
func publicAPISnapshot_AIOContracts() throws {
  _ = (any AudioSessionAuthority).self
  _ = (any BufferEmitter<Float>).self
  _ = (any BufferReceiver<Float>).self
  _ = BufferReceiverToken.self
  _ = BufferTiming.self
  _ = RecordingCompletion.self
  _ = RecordingRotation.self
  _ = RecordingTimingSnapshot.self
}

@MainActor
func publicAPISnapshotAsyncAudioSessionAPI(
  environment: AudioEnvironmentManager,
  authority: any AudioSessionAuthority,
  engine: AIOEngine,
  configuration: RecordingConfiguration,
) async throws {
  _ = await environment.requestInputConfiguration(.automatic)
  _ = try await environment.settleInputConfiguration()
  _ = try await environment.resolveCaptureInputContract()
  _ = await environment.refreshInputConfiguration()
  let hold = try await environment.acquireAudioSessionHold()
  await hold.release()
  try await environment.setAudioSessionActive(true)
  try await authority.setAudioSessionActive(true)

  let subscriberID = environment.addAudioSystemEventSubscriber { event in
    await engine.handleAudioSystemEvent(event)
  }
  environment.removeSubscriber(subscriberID)
  await engine.handleAudioSystemEvent(.mediaServicesReset)
}

@Test("Public API snapshot — AIOEngineCore re-exports compile via AudioIO")
func publicAPISnapshot_AIOEngineCore() throws {
  _ = AIOEngine.self
}

@Test("Public API snapshot — AIOPlayback re-exports compile via AudioIO")
func publicAPISnapshot_AIOPlayback() throws {
  _ = PlaybackScrubMode.self
  _ = PlaybackJogRate.self
  _ = PlaybackJogSnapshot.self
}

// Pins the canonical awaited recording lifecycle and immutable authority
// initializer. Compile-time only — never invoked.
@MainActor
func publicAPISnapshotRecordingStartAPI(
  engine: AIOEngine,
  authority: any AudioSessionAuthority,
  configuration: RecordingConfiguration,
) async {
  _ = try? await engine.startRecording(configuration: configuration)
  _ = try? await engine.stopRecording()
  _ = AIOEngine(recordingStartTimeout: .seconds(2))
  _ = AIOEngine(audioSessionAuthority: authority)
}

@Test("Public API snapshot — AIOMicHealth re-exports compile via AudioIO")
func publicAPISnapshot_AIOMicHealth() throws {
  _ = MicHealthInputs.self
  _ = MicHealthMonitor.self
  _ = MicHealthReason.self
  _ = MicHealthReasonKey.self
  _ = MicHealthState.self
  _ = MicHealthThresholds.self
  _ = PendingTrackEvent.self
  _ = PendingTrackEventKind.self
}

@Test("Public API snapshot — AIOVisualization re-exports compile via AudioIO")
func publicAPISnapshot_AIOVisualization() throws {
  _ = AudioVisualizationEngine.self
  _ = (any VisualizationDriving).self
  _ = VisualizationEvent.self
  _ = VisualizationEventMask.self
  _ = VisualizationRequest.self
  _ = VisualizationSubscription.self
}

@Test("Public API snapshot — AudioSignals re-exports compile via AudioIO")
func publicAPISnapshot_AudioSignals() throws {
  _ = AmplitudeAnalyzer.self
  _ = AmplitudeData.self
  _ = BandLODData.self
  _ = BeatDetectionConfiguration.self
  _ = BeatDetector.self
  _ = BeatInfo.self
  _ = CrossoverMode.self
  _ = FrequencyAnalyzer.self
  _ = FrequencyAnalyzerError.self
  _ = FrequencyBucket.self
  _ = FrequencyBucketMode.self
  _ = FrequencyBucketer.self
  _ = FrequencyDomainData.self
  _ = FrequencyDomainWork.self
  _ = FrequencyWeighting.self
  _ = LODChannel.self
  _ = (any LODSnapshot).self
  _ = LODSnapshotRef.self
  _ = \LODSnapshotRef.committedLODCount
  _ = LODTimelineLayout.self
  _ = LODWork.self
  _ = AnalysisWork.self
  _ = MultiBandLODConfiguration.self
  // `MultiBandLODProcessor` is `@unsafe`; the `unsafe` keyword is required
  // at reference sites under `SWIFT_STRICT_MEMORY_SAFETY`. Don't "clean
  // up" by removing it.
  _ = unsafe MultiBandLODProcessor.self
  // `LODGenerationError` is a nested enum inside `MultiBandLODProcessor`,
  // used in `throws(...)` clauses on `OfflineLODExtractor.extract(...)`.
  // Pinned here so a rename or access-level drop fails the snapshot.
  _ = MultiBandLODProcessor.LODGenerationError.self
  _ = MultiBandLODSnapshot.self
  // These types intentionally rely on AudioIO's exported AudioSignals import
  // instead of duplicate typealiases in Exports.swift.
  _ = OfflineLODExtractor.self
  _ = OfflineLODProgress.self
  _ = OfflineLODResult.self
  _ = (any SnapshotProvider).self
  _ = SpectrumData.self
  _ = StandardBands.self
  _ = TimeDomainData.self
  _ = VisualizationRateDefaults.self
  _ = VisualizationWork.self
}
