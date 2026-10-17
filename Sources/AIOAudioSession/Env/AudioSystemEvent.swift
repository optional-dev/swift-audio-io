// © GoodHatsLLC

public import Foundation

/// A platform-neutral audio-system event that may require engine recovery.
public enum AudioSystemEvent: Sendable, Hashable {
  case routeChanged(AudioRouteChange)
  case interruptionBegan
  case interruptionEnded(shouldResume: Bool)
  case mediaServicesLost
  case mediaServicesReset
  /// The platform reported that the session became active.
  ///
  /// This is a confirmation and reconciliation signal, not a recovery trigger.
  case sessionActivated
  /// The platform reported that the session became inactive, and why.
  case sessionDeactivated(AudioSessionDeactivation)
  /// The system's recommendation on whether interrupted audio should resume.
  ///
  /// It is advice about *playback*: recording recovery
  /// is never driven by it.
  case resumptionRecommended(Bool)
}

/// A captured explanation of why the platform audio session became inactive.
public struct AudioSessionDeactivation: Sendable, Hashable {
  public init(
    source: AudioSessionDeactivationSource,
    interruptionReason: AudioInterruptionReason? = nil,
  ) {
    self.source = source
    self.interruptionReason = interruptionReason
  }

  /// Who deactivated the session.
  public let source: AudioSessionDeactivationSource

  /// Why the system interrupted, when the deactivation came from a system
  /// interruption. `nil` for an app-requested deactivation.
  public let interruptionReason: AudioInterruptionReason?

  public var userLabel: String {
    switch source {
    case .app:
      "Audio session released by this app"
    case .system:
      if let interruptionReason {
        "Audio session interrupted: \(interruptionReason.userLabel)"
      } else {
        "Audio session deactivated by the system"
      }
    case .unknown:
      "Audio session deactivated"
    }
  }
}

/// Who deactivated the platform audio session.
public enum AudioSessionDeactivationSource: Sendable, Hashable {
  /// This app asked for the deactivation.
  case app
  /// The system deactivated the session, typically an interruption.
  case system
  /// The platform reported a source this version does not model.
  case unknown
}

/// Why the system interrupted the audio session.
public enum AudioInterruptionReason: Sendable, Hashable {
  case `default`
  case builtInMicMuted
  case routeDisconnected
  case unknown

  public var userLabel: String {
    switch self {
    case .default: "Another app took the audio session"
    case .builtInMicMuted: "Built-in microphone muted"
    case .routeDisconnected: "Audio route disconnected"
    case .unknown: "Unknown reason"
    }
  }
}

/// A captured route transition with no live platform-session dependency.
public struct AudioRouteChange: Sendable, Hashable {
  public init(
    reason: AudioRouteChangeReason,
    previousRoute: AudioRouteSnapshot?,
    currentRoute: AudioRouteSnapshot,
    session: AudioSessionSnapshot? = nil,
  ) {
    self.reason = reason
    self.previousRoute = previousRoute
    self.currentRoute = currentRoute
    self.session = session
  }

  public let reason: AudioRouteChangeReason
  public let previousRoute: AudioRouteSnapshot?
  public let currentRoute: AudioRouteSnapshot
  public let session: AudioSessionSnapshot?

  public var isInputAvailable: Bool {
    session?.isInputAvailable ?? !currentRoute.inputs.isEmpty
  }

  /// The capture-relevant facts this transition reports, or `nil` when the
  /// event carries no session snapshot to read them from.
  ///
  /// `nil` means "unknown", which is not the same as "unchanged": a consumer
  /// that cannot observe the facts cannot prove nothing moved, and must
  /// reconfigure.
  public var inputFacts: AudioInputFacts? {
    guard let session else { return nil }
    return AudioInputFacts(
      inputs: currentRoute.inputs,
      isInputAvailable: session.isInputAvailable,
      sampleRate: session.sampleRate,
      inputChannelCount: session.inputNumberOfChannels,
      mode: session.mode,
    )
  }

  public var userMessage: String {
    var lines = ["Audio route changed: \(reason.userLabel)"]

    if let previousRoute {
      let inputLine =
        if previousRoute.inputs != currentRoute.inputs {
          "Input: \(previousRoute.inputsDescription) → \(currentRoute.inputsDescription)"
        } else {
          "Input: \(currentRoute.inputsDescription)"
        }
      let outputLine =
        if previousRoute.outputs != currentRoute.outputs {
          "Output: \(previousRoute.outputsDescription) → \(currentRoute.outputsDescription)"
        } else {
          "Output: \(currentRoute.outputsDescription)"
        }
      lines.append(inputLine)
      lines.append(outputLine)
    } else {
      lines.append("Input: \(currentRoute.inputsDescription)")
      lines.append("Output: \(currentRoute.outputsDescription)")
    }

    if let session, reason.includesSessionSummary {
      lines.append("Session: \(session.summary)")
    }

    return lines.joined(separator: "\n")
  }
}

/// The facts about a route that a live capture graph actually depends on.
///
/// Two route notifications carrying equal facts describe the same capture
/// reality: the same input endpoints, the same availability, and the same
/// format the engine's input node will report. Notifications that differ only
/// in ``AudioRouteChangeReason`` — most importantly the `.categoryChanged` that
/// an `AVAudioSession` preference write posts back at the process that made it
/// — carry no new fact, and are not grounds to tear down a running tap.
///
/// Deliberately excluded: the session's category and options, and the I/O
/// buffer duration. None of them changes what the input node produces, and
/// including the category would make the very event this type exists to
/// discount look material.
public struct AudioInputFacts: Hashable, Sendable {
  public init(
    inputs: [AudioPortSnapshot],
    isInputAvailable: Bool,
    sampleRate: Double,
    inputChannelCount: Int,
    mode: String,
  ) {
    self.inputs = inputs
    self.isInputAvailable = isInputAvailable
    self.sampleRate = sampleRate
    self.inputChannelCount = inputChannelCount
    self.mode = mode
  }

  /// The route's input endpoints, by identity and channel count. A swap
  /// between two endpoints that happen to share a format is still a swap.
  public let inputs: [AudioPortSnapshot]
  public let isInputAvailable: Bool
  public let sampleRate: Double
  public let inputChannelCount: Int
  /// The session mode, which selects the input processing chain — measurement
  /// versus the default processed path — and so changes the samples captured.
  public let mode: String

  /// Whether an audio format could serve as the capture format for these facts.
  ///
  /// Used to tell "nothing changed" apart from "nothing changed *and* the graph
  /// already reflects it". A tap built against a different rate or channel
  /// count needs rebuilding even when the route itself has been still.
  public func matchesCaptureFormat(sampleRate: Double, channelCount: Int) -> Bool {
    abs(self.sampleRate - sampleRate) < 0.5 && inputChannelCount == channelCount
  }
}

/// Why the system's active audio route changed.
public enum AudioRouteChangeReason: Sendable, Hashable {
  case deviceDisconnected
  case deviceConnected
  case categoryChanged
  case overridden
  case configurationChanged
  case wokeFromSleep
  case noSuitableRoute
  case unknown

  public var userLabel: String {
    switch self {
    case .deviceDisconnected: "Device disconnected"
    case .deviceConnected: "New device connected"
    case .categoryChanged: "Category changed"
    case .overridden: "Overridden"
    case .configurationChanged: "Route configuration changed"
    case .wokeFromSleep: "Woke from sleep"
    case .noSuitableRoute: "No suitable route"
    case .unknown: "Unknown"
    }
  }

  var includesSessionSummary: Bool {
    switch self {
    case .categoryChanged, .overridden, .configurationChanged, .noSuitableRoute:
      true
    case .deviceDisconnected, .deviceConnected, .wokeFromSleep, .unknown:
      false
    }
  }
}

/// The input and output endpoints captured for one audio route.
public struct AudioRouteSnapshot: Sendable, Hashable {
  public init(inputs: [AudioPortSnapshot], outputs: [AudioPortSnapshot]) {
    self.inputs = inputs
    self.outputs = outputs
  }

  public let inputs: [AudioPortSnapshot]
  public let outputs: [AudioPortSnapshot]

  public var inputsDescription: String {
    describePorts(inputs)
  }

  public var outputsDescription: String {
    describePorts(outputs)
  }

  private func describePorts(_ ports: [AudioPortSnapshot]) -> String {
    guard !ports.isEmpty else { return "none" }
    return ports.map(\.userLabel).joined(separator: ", ")
  }
}

/// A captured audio endpoint.
public struct AudioPortSnapshot: Sendable, Hashable {
  public init(name: String, uid: String, type: String, channelCount: Int) {
    self.name = name
    self.uid = uid
    self.type = type
    self.channelCount = channelCount
  }

  public let name: String
  public let uid: String
  public let type: String
  public let channelCount: Int

  public var userLabel: String {
    if channelCount > 0 {
      return "\(name) (\(type), \(channelCount)ch)"
    }
    return "\(name) (\(type))"
  }
}

/// Captured session facts relevant to recovery decisions and diagnostics.
public struct AudioSessionSnapshot: Sendable, Hashable {
  public init(
    category: String,
    mode: String,
    options: [String],
    sampleRate: Double,
    ioBufferDuration: TimeInterval,
    inputNumberOfChannels: Int,
    isInputAvailable: Bool,
  ) {
    self.category = category
    self.mode = mode
    self.options = options
    self.sampleRate = sampleRate
    self.ioBufferDuration = ioBufferDuration
    self.inputNumberOfChannels = inputNumberOfChannels
    self.isInputAvailable = isInputAvailable
  }

  public let category: String
  public let mode: String
  public let options: [String]
  public let sampleRate: Double
  public let ioBufferDuration: TimeInterval
  public let inputNumberOfChannels: Int
  public let isInputAvailable: Bool

  public var summary: String {
    var parts = [category]
    if !mode.isEmpty, mode != "default" {
      parts.append("mode=\(mode)")
    }
    if !options.isEmpty {
      parts.append("options=\(options.joined(separator: ","))")
    }
    if !isInputAvailable {
      parts.append("inputUnavailable")
    }
    parts.append("\(inputNumberOfChannels)ch@\(Int(sampleRate))Hz")
    parts.append("buffer=\(ioBufferDuration)s")
    return parts.joined(separator: "\n")
  }
}
