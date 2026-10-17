// © GoodHatsLLC

#if os(iOS)
  package import AVFoundation

  extension AudioRouteChange {
    package init(
      platformReason: AVAudioSession.RouteChangeReason,
      previousRoute: AVAudioSessionRouteDescription?,
      session: AVAudioSession,
    ) {
      self.init(
        reason: AudioRouteChangeReason(platformReason),
        previousRoute: previousRoute.map(AudioRouteSnapshot.init(platformRoute:)),
        currentRoute: AudioRouteSnapshot(platformRoute: session.currentRoute),
        session: AudioSessionSnapshot(platformSession: session),
      )
    }
  }

  extension AudioSessionDeactivation {
    /// Converts the iOS 27 deactivation context into the neutral value the
    /// recovery policy consumes. Per ADR 0002 the raw platform type never
    /// leaves this adapter.
    package init(platformContext context: AVAudioSession.DeactivationContext) {
      self.init(
        source: AudioSessionDeactivationSource(context.source),
        interruptionReason: context.interruptionContext.map {
          AudioInterruptionReason($0.reason)
        },
      )
    }
  }

  extension AudioSessionDeactivationSource {
    package init(_ source: AVAudioSession.DeactivationSource) {
      switch source {
      case .app: self = .app
      case .system: self = .system
      @unknown default: self = .unknown
      }
    }
  }

  extension AudioInterruptionReason {
    package init(_ reason: AVAudioSession.InterruptionReason) {
      switch reason {
      case .default: self = .default
      case .builtInMicMuted: self = .builtInMicMuted
      case .routeDisconnected: self = .routeDisconnected
      // `.appWasSuspended` is deprecated and no longer posted from iOS 16.
      default: self = .unknown
      }
    }
  }

  extension AudioRouteChangeReason {
    package init(_ reason: AVAudioSession.RouteChangeReason) {
      switch reason {
      case .oldDeviceUnavailable: self = .deviceDisconnected
      case .newDeviceAvailable: self = .deviceConnected
      case .categoryChange: self = .categoryChanged
      case .override: self = .overridden
      case .routeConfigurationChange: self = .configurationChanged
      case .wakeFromSleep: self = .wokeFromSleep
      case .noSuitableRouteForCategory: self = .noSuitableRoute
      case .unknown: self = .unknown
      @unknown default: self = .unknown
      }
    }
  }

  extension AudioRouteSnapshot {
    package init(platformRoute route: AVAudioSessionRouteDescription) {
      inputs = route.inputs.map(AudioPortSnapshot.init(platformPort:))
      outputs = route.outputs.map(AudioPortSnapshot.init(platformPort:))
    }
  }

  extension AudioPortSnapshot {
    package init(platformPort port: AVAudioSessionPortDescription) {
      name = port.portName
      uid = port.uid
      type = port.portType.rawValue
      channelCount = port.channels?.count ?? 0
    }
  }

  extension AudioSessionSnapshot {
    package init(platformSession session: AVAudioSession) {
      category = session.category.rawValue
      mode = session.mode.rawValue
      options = AVAudioSession.CategoryOptions.userLabels(for: session.categoryOptions)
      sampleRate = session.sampleRate
      ioBufferDuration = session.ioBufferDuration
      inputNumberOfChannels = session.inputNumberOfChannels
      isInputAvailable = session.isInputAvailable
    }
  }

  extension AVAudioSession.CategoryOptions {
    fileprivate static func userLabels(for options: AVAudioSession.CategoryOptions) -> [String] {
      var labels: [String] = []
      if options.contains(.mixWithOthers) { labels.append("mixWithOthers") }
      if options.contains(.duckOthers) { labels.append("duckOthers") }
      if options.contains(.allowBluetoothHFP) { labels.append("allowBluetoothHFP") }
      if options.contains(.defaultToSpeaker) { labels.append("defaultToSpeaker") }
      if options.contains(.interruptSpokenAudioAndMixWithOthers) {
        labels.append("interruptSpokenAudioAndMixWithOthers")
      }
      if options.contains(.allowBluetoothA2DP) { labels.append("allowBluetoothA2DP") }
      if options.contains(.allowAirPlay) { labels.append("allowAirPlay") }
      if options.contains(.overrideMutedMicrophoneInterruption) {
        labels.append("overrideMutedMicrophoneInterruption")
      }
      return labels
    }
  }
#endif
