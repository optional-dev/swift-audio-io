// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import Foundation

  /// The replaceable collaborators a recording lifecycle reaches through to
  /// touch real audio hardware.
  ///
  /// Every field is optional, and `nil` means "use the built-in production
  /// path" — the same convention ``AIOEngine/audioSessionAuthority`` already
  /// follows, where absence means the engine drives platform activation
  /// itself. That keeps the layering intact: `AIOEngineCore` can *store* a
  /// capture-backend factory, but only `AIORecording` can construct the real
  /// `MicrophoneCaptureBackend`, so the production default lives at the point
  /// of use rather than here.
  ///
  /// The environment is immutable for the engine's lifetime. Tests supply
  /// fakes at initialization instead of mutating hooks at runtime, so a
  /// recording lifecycle cannot change which audio graph it is talking to
  /// half way through a start.
  package struct RecordingEnvironment: Sendable {
    /// Builds the capture backend for a prepared source. `nil` selects the
    /// built-in backend for the configuration's ``RecordingInput``.
    package var makeCaptureBackend:
      (@Sendable (RecordingInput, AIOEngine) -> any RecordingCaptureBackend)?

    /// Installs the input tap. `nil` uses the real `AVAudioEngine` graph.
    package var tapInstaller: (any TapInstalling)?

    /// Replaces `AVAudioEngine` graph teardown (tap removal plus
    /// `stop()`/`reset()`). `nil` performs the real teardown.
    package var engineTeardown: (@MainActor @Sendable () -> Void)?

    /// Replaces one readiness attempt inside the start deadline loop. `nil`
    /// runs the real bring-up. Typed as a closure rather than the
    /// `RecordingStartReadiness` port because that port is declared in
    /// `AIORecording`, which depends on this module.
    package var attemptRecordingStart:
      (@Sendable (RecordingConfiguration) async throws(RecordingError) -> URL)?

    #if os(iOS)
      /// Replaces the engine-managed platform activation path used when
      /// ``AIOEngine/audioSessionAuthority`` is `nil`. `nil` selects
      /// ``NativeAudioSessionActivator``.
      ///
      /// Set after initialization rather than through the memberwise
      /// initializer: the field only exists on iOS, and `#if` cannot gate a
      /// single function parameter. The environment is still immutable for the
      /// engine's lifetime — it is a value copied at engine init.
      package var sessionActivator: (any AudioSessionActivating)?
    #endif

    package init(
      makeCaptureBackend: (
        @Sendable (RecordingInput, AIOEngine) -> any RecordingCaptureBackend
      )? = nil,
      tapInstaller: (any TapInstalling)? = nil,
      engineTeardown: (@MainActor @Sendable () -> Void)? = nil,
      attemptRecordingStart: (
        @Sendable (RecordingConfiguration) async throws(RecordingError) -> URL
      )? = nil,
    ) {
      self.makeCaptureBackend = makeCaptureBackend
      self.tapInstaller = tapInstaller
      self.engineTeardown = engineTeardown
      self.attemptRecordingStart = attemptRecordingStart
    }

    /// The production environment: every collaborator is the built-in one.
    package static let live = RecordingEnvironment()
  }
#endif
