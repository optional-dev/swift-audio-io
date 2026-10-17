// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  public import AVFoundation
  import os
  public import Tools

  private let log = SystemLog.make()

  /// A struct that provides information about the audio environment and allows for its configuration.
  public struct AudioEnvironment: Sendable {
    public enum RequestError: AudioError {
      public enum Operation: String, Sendable, Equatable, CustomStringConvertible {
        case setPreferredInput
        case setPreferredSampleRate
        case setPreferredDataSource

        public var description: String {
          rawValue
        }
      }

      case noActiveAudioInputForDataSource
      case operationFailed(operation: Operation, error: ErrorContext)

      public var description: String {
        switch self {
        case .noActiveAudioInputForDataSource:
          "No active audio input to set data source on"
        case .operationFailed(let operation, let error):
          "Audio environment operation '\(operation)' failed: \(error)"
        }
      }
    }

    /// Creates a new `AudioEnvironment` instance.
    ///
    /// - Parameters:
    ///   - session: The `AVAudioSession` to use. Defaults to the shared instance.
    ///   - notifications: The `Notifications` instance to use.
    public init(
      session: AVAudioSession = AVAudioSession.sharedInstance(),
      notifications: Notifications = Notifications(),
    ) {
      self.session = session
      self.notifications = notifications
    }

    let session: AVAudioSession
    /// The notifications provided by the audio environment.
    public let notifications: Notifications

    /// The current audio input.
    public var input: AudioInput? {
      AudioSessionAccess.sync {
        session.currentRoute.inputs.first.map {
          AudioInput(port: $0)
        }
      }
    }

    /// Requests a specific audio input.
    ///
    /// Idempotent: the platform is only written when `session.preferredInput`
    /// does not already name this port. Rewriting it can post a route-change
    /// notification, which this package treats as a reason to reconcile.
    ///
    /// - Parameter input: The audio input to request.
    /// - Throws: An error if the input cannot be set.
    public func request(input: AudioInput?) throws(RequestError) {
      try AudioSessionAccess.result(catching: RequestError.self) {
        () throws(RequestError) -> Void in
        do {
          try AudioSessionPreferenceWrite.performPreferredInput(
            input?.avAudio,
            on: session,
          ) { try session.setPreferredInput($0) }
        } catch {
          throw .operationFailed(operation: .setPreferredInput, error: ErrorContext(error))
        }
      }.get()
    }

    /// The available audio inputs.
    public var availableInputs: [AudioInput] {
      AudioSessionAccess.sync {
        (session.availableInputs ?? []).map { AudioInput(port: $0) }
      }
    }

    /// The current audio source.
    public var source: AudioSource? {
      AudioSessionAccess.sync {
        session.inputDataSource.map {
          AudioSource(avAudio: $0)
        }
      }
    }

    /// The current sample rate.
    public var sampleRate: SampleRate {
      AudioSessionAccess.sync {
        SampleRate(session.sampleRate)
      }
    }

    /// Requests a specific sample rate.
    ///
    /// The requested sample rate may not be honored; read ``sampleRate`` back to
    /// see what the route actually settled on. The *preference* is what this
    /// writes, and it is only written when it differs from
    /// `session.preferredSampleRate` — a route that refuses 48 kHz still stores
    /// 48 kHz as the preference, so a rejected request is idempotent too, and
    /// re-requesting it costs nothing.
    ///
    /// - Parameter sampleRate: The sample rate to request.
    /// - Throws: An error if the sample rate cannot be set.
    public func request(sampleRate: SampleRate) throws(RequestError) {
      try AudioSessionAccess.result(catching: RequestError.self) {
        () throws(RequestError) -> Void in
        do {
          try AudioSessionPreferenceWrite.perform(
            sampleRate.hz,
            whenNot: session.preferredSampleRate,
          ) { try session.setPreferredSampleRate($0) }
        } catch {
          throw .operationFailed(operation: .setPreferredSampleRate, error: ErrorContext(error))
        }
      }.get()
    }

    /// Requests a specific audio source.
    ///
    /// - Parameter source: The audio source to request.
    /// - Throws: An error if the source cannot be set.
    public func request(source: AudioSource?) throws(RequestError) {
      try AudioSessionAccess.result(catching: RequestError.self) {
        () throws(RequestError) -> Void in
        // Always set the data source on the currently active input from the route.
        // This ensures we target the correct port in multi-input scenarios where
        // preferredInput might be nil (system defaults) or point to an inactive device.
        guard let activeInput = session.currentRoute.inputs.first else {
          throw .noActiveAudioInputForDataSource
        }
        do {
          try activeInput.setPreferredDataSource(source?.avAudio)
        } catch {
          throw .operationFailed(operation: .setPreferredDataSource, error: ErrorContext(error))
        }
      }.get()
    }

    /// The available audio sources.
    public var availableSources: [AudioSource] {
      AudioSessionAccess.sync {
        if let sources = session.inputDataSources {
          return sources.map { AudioSource(avAudio: $0) }
        }
        return session.currentRoute.inputs.first.map { activeInput in
          (activeInput.dataSources ?? []).map { AudioSource(avAudio: $0) }
        } ?? []
      }
    }
  }

  extension AudioEnvironment {
    /// Asynchronous streams for AVAudioSession system notifications.
    ///
    /// ## Threading Contract
    ///
    /// AVAudioSession notifications arrive on Apple's internal "AVAudioSession Notify
    /// Thread", **not** the main thread. The `compactMap`/`map` closures in each stream
    /// property execute on that originating thread — they only parse `userInfo`
    /// dictionaries and perform no mutable state access, so this is safe.
    ///
    /// The actual event handlers run on `@MainActor` because
    /// `AudioEnvironmentManager.subscribe()` consumes these streams via `for await` inside
    /// tasks that inherit MainActor isolation. Handlers passed to `AIOEngine`
    /// (`handleAudioSystemEvent(_:)`) are also `@MainActor`.
    public struct Notifications: Sendable {
      /// Creates a new `Notifications` instance.
      ///
      /// - Parameter center: The `NotificationCenter` to use. Defaults to the default notification center.
      public init(center: NotificationCenter = .default) {
        self.center = center
      }

      private let center: NotificationCenter
      /// An asynchronous stream of audio session interruption notifications.
      public var interruption:
        AsyncSignalStream<
          (type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?),
        >
      {
        AsyncSignalStream<
          (type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?),
        >(
          source: center.notifications(named: AVAudioSession.interruptionNotification),
          compactMap: {
            (notification: Notification) -> (
              type: AVAudioSession.InterruptionType,
              options: AVAudioSession.InterruptionOptions?
            )? in
            guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else {
              log.error(
                """
                interruption notification inapplicable:
                info: \(String(dump: notification.userInfo), privacy: .public)
                """,
              )
              return nil
            }

            // Extract interruption options if available
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            log.warning(
              """
                env, interruption notification: type=\(type.rawValue, privacy: .public), options=\(options.map { "\($0.rawValue)" } ?? "nil", privacy: .public)
              """,
            )
            return (type, options)
          },
        )
      }

      /// An asynchronous stream of audio session route change notifications.
      public var routeChange:
        AsyncSignalStream<
          (reason: AVAudioSession.RouteChangeReason, previous: AVAudioSessionRouteDescription?),
        >
      {
        AsyncSignalStream<
          (reason: AVAudioSession.RouteChangeReason, previous: AVAudioSessionRouteDescription?),
        >(
          source: center.notifications(named: AVAudioSession.routeChangeNotification),
          compactMap: { notification in
            log.warning("Environment: route change")
            if let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            {
              let previousRoute =
                info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
              return (reason, previousRoute)
            } else {
              log.error(
                """
                routeChange notification inapplicable:
                info: \(String(dump: notification.userInfo), privacy: .public)
                """,
              )
              return nil
            }
          },
        )
      }

      /// An asynchronous stream of notifications for when the available inputs change.
      public var availableInputsChanged: AsyncSignalStream<Void> {
        AsyncSignalStream<Void>(
          source: center.notifications(named: AVAudioSession.availableInputsChangeNotification),
          map: { _ in () },
        )
      }

      /// An asynchronous stream of session-activation confirmations.
      public var sessionDidBecomeActive: AsyncSignalStream<Void> {
        AsyncSignalStream<Void>(
          source: center.notifications(named: AVAudioSession.didBecomeActiveNotification),
          map: { _ in
            log.info("Environment: audio session did become active")
            return ()
          },
        )
      }

      /// An asynchronous stream of session deactivations, carrying who
      /// deactivated the session and why.
      public var sessionDidBecomeInactive: AsyncSignalStream<AudioSessionDeactivation> {
        AsyncSignalStream<AudioSessionDeactivation>(
          source: center.notifications(named: AVAudioSession.didBecomeInactiveNotification),
          compactMap: { (notification: Notification) -> AudioSessionDeactivation? in
            guard
              let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext
            else {
              log.error(
                """
                didBecomeInactive notification inapplicable:
                info: \(String(dump: notification.userInfo), privacy: .public)
                """,
              )
              return nil
            }
            let deactivation = AudioSessionDeactivation(platformContext: context)
            log.warning(
              "env, session did become inactive: \(deactivation.userLabel, privacy: .public)",
            )
            return deactivation
          },
        )
      }

      /// An asynchronous stream of the system's resumption recommendations.
      ///
      /// The element is `true` when the system recommends resuming.
      public var resumptionRecommendation: AsyncSignalStream<Bool> {
        AsyncSignalStream<Bool>(
          source: center.notifications(
            named: AVAudioSession.resumptionRecommendationNotification,
          ),
          compactMap: { (notification: Notification) -> Bool? in
            guard
              let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                as? AVAudioSession.ResumptionContext
            else {
              log.error(
                """
                resumptionRecommendation notification inapplicable:
                info: \(String(dump: notification.userInfo), privacy: .public)
                """,
              )
              return nil
            }
            let shouldResume = context.recommendation == .shouldResume
            log.warning(
              "env, resumption recommendation: \(shouldResume ? "resume" : "do not resume", privacy: .public)",
            )
            return shouldResume
          },
        )
      }

      /// An asynchronous stream of notifications for when the media services are lost.
      public var mediaServicesLost: AsyncSignalStream<Void> {
        AsyncSignalStream<Void>(
          source: center.notifications(named: AVAudioSession.mediaServicesWereLostNotification),
          map: { _ in
            log.warning("Environment: media services were lost")
            return ()
          },
        )
      }

      /// An asynchronous stream of notifications for when the media services are reset.
      public var mediaServicesReset: AsyncSignalStream<Void> {
        AsyncSignalStream<Void>(
          source: center.notifications(named: AVAudioSession.mediaServicesWereResetNotification),
          map: { _ in
            log.warning("Environment: media services were reset")
            return ()
          },
        )
      }

      /// An asynchronous stream of notifications for when secondary audio should be silenced.
      public var silenceSecondaryAudioHint: AsyncSignalStream<Void> {
        AsyncSignalStream<Void>(
          source: center.notifications(named: AVAudioSession.silenceSecondaryAudioHintNotification),
          map: { _ in
            log.warning("Environment: silence secondary audio")
            return ()
          },
        )
      }
    }
  }

  extension AVAudioSession.CategoryOptions {
    var description: String {
      if self == AVAudioSession.CategoryOptions.mixWithOthers {
        "mixWithOthers"
      } else if self == AVAudioSession.CategoryOptions.duckOthers {
        "duckOthers"
      } else if self == AVAudioSession.CategoryOptions.allowBluetoothHFP {
        "allowBluetoothHFP"
      } else if self == AVAudioSession.CategoryOptions.defaultToSpeaker {
        "defaultToSpeaker"
      } else if self == AVAudioSession.CategoryOptions.interruptSpokenAudioAndMixWithOthers {
        "interruptSpokenAudioAndMixWithOthers"
      } else if self == AVAudioSession.CategoryOptions.allowBluetoothA2DP {
        "allowBluetoothA2DP"
      } else if self == AVAudioSession.CategoryOptions.allowAirPlay {
        "allowAirPlay"
      } else if self == AVAudioSession.CategoryOptions.overrideMutedMicrophoneInterruption {
        "overrideMutedMicrophoneInterruption"
      } else {
        #if os(iOS)
          if self == AVAudioSession.CategoryOptions.bluetoothHighQualityRecording {
            "bluetoothHighQualityRecording"
          } else {
            "unknown"
          }
        #else
          "unknown"
        #endif
      }
    }
  }
#else
  import Foundation
  import Tools

  /// Native macOS does not expose `AVAudioSession`; this placeholder keeps API surface available
  /// while higher-level call sites use platform-specific backends.
  public struct AudioEnvironment: Sendable {
    public init() {}
  }
#endif
