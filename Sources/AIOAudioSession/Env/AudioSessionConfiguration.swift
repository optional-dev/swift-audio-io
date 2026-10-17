// © GoodHatsLLC

/// How a recording session treats Bluetooth microphones.
///
/// On iOS this decision *is* a sample-rate decision: routing input through a
/// classic Bluetooth (HFP) microphone collapses the whole session to the HFP
/// codec rate — 8–16 kHz for headsets, 24 kHz for modern AirPods — while the
/// A2DP output path has no microphone at all. Making the choice a named policy
/// keeps the biggest silent quality downgrade on the platform explicit.
///
/// macOS has no `AVAudioSession`; the policy is accepted and ignored there.
public enum BluetoothMicrophonePolicy: Hashable, Sendable {
  /// Use high-quality Bluetooth capture where the route supports it — iOS 26
  /// with H2-class AirPods records at 48 kHz — falling back to classic HFP
  /// everywhere else.
  ///
  /// High-quality Bluetooth recording adds input latency and requires the
  /// session's default mode, so it is not applied to measurement-mode
  /// configurations; it is also unavailable in some regions, where the route
  /// silently falls back to HFP. ``ResolvedCaptureFormat`` reports the rate
  /// that was actually delivered either way.
  case highQualityWhenAvailable

  /// Classic HFP duplex: Bluetooth microphones work, and the session runs at
  /// the HFP codec rate while one is routed. The default, matching the
  /// behavior this package has always had.
  case handsFree

  /// Never capture from a Bluetooth microphone: output stays on high-quality
  /// A2DP and input stays on the built-in (or wired) microphone at the full
  /// hardware rate.
  case never
}

#if os(iOS)
  public import AVFoundation

  public struct AudioSessionConfiguration: Sendable, Hashable {
    public var category: AVAudioSession.Category
    public var mode: AVAudioSession.Mode
    public var options: AVAudioSession.CategoryOptions
    public var allowsHapticsAndSystemSoundsDuringRecording: Bool
    public var prefersNoInterruptionsFromSystemAlerts: Bool
    public var prefersInterruptionOnRouteDisconnect: Bool

    public init(
      category: AVAudioSession.Category,
      mode: AVAudioSession.Mode,
      options: AVAudioSession.CategoryOptions,
      allowsHapticsAndSystemSoundsDuringRecording: Bool = true,
      prefersNoInterruptionsFromSystemAlerts: Bool = true,
      prefersInterruptionOnRouteDisconnect: Bool = false,
    ) {
      self.category = category
      self.mode = mode
      self.options = options
      self.allowsHapticsAndSystemSoundsDuringRecording = allowsHapticsAndSystemSoundsDuringRecording
      self.prefersNoInterruptionsFromSystemAlerts = prefersNoInterruptionsFromSystemAlerts
      self.prefersInterruptionOnRouteDisconnect = prefersInterruptionOnRouteDisconnect
    }

    public static func recordingConfiguration(
      useMeasurement: Bool,
      bluetoothMicrophone: BluetoothMicrophonePolicy = .handsFree,
    ) -> AudioSessionConfiguration {
      var options: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .allowBluetoothA2DP,
        .allowAirPlay,
        .overrideMutedMicrophoneInterruption,
      ]
      switch bluetoothMicrophone {
      case .never:
        break
      case .handsFree:
        options.insert(.allowBluetoothHFP)
      case .highQualityWhenAvailable:
        options.insert(.allowBluetoothHFP)
        // High-quality Bluetooth recording is default-mode only; combining it
        // with measurement mode would be rejected at category set.
        if !useMeasurement {
          options.insert(.bluetoothHighQualityRecording)
        }
      }

      return AudioSessionConfiguration(
        category: .playAndRecord,
        mode: useMeasurement ? .measurement : .default,
        options: options,
        allowsHapticsAndSystemSoundsDuringRecording: true,
        prefersNoInterruptionsFromSystemAlerts: true,
        prefersInterruptionOnRouteDisconnect: false,
      )
    }

    public static let recordingConfiguration = recordingConfiguration(useMeasurement: false)

    public static var playbackConfiguration: AudioSessionConfiguration {
      let options: AVAudioSession.CategoryOptions = [
        .allowAirPlay,
        .allowBluetoothA2DP,
      ]

      return AudioSessionConfiguration(
        category: .playback,
        mode: .default,
        options: options,
        allowsHapticsAndSystemSoundsDuringRecording: false,
        prefersNoInterruptionsFromSystemAlerts: false,
        prefersInterruptionOnRouteDisconnect: false,
      )
    }
  }

  extension AudioSessionConfiguration {
    public static func == (
      lhs: AudioSessionConfiguration,
      rhs: AudioSessionConfiguration,
    ) -> Bool {
      lhs.category == rhs.category
        && lhs.mode == rhs.mode
        && lhs.options.rawValue == rhs.options.rawValue
        && lhs.allowsHapticsAndSystemSoundsDuringRecording
          == rhs.allowsHapticsAndSystemSoundsDuringRecording
        && lhs.prefersNoInterruptionsFromSystemAlerts
          == rhs.prefersNoInterruptionsFromSystemAlerts
        && lhs.prefersInterruptionOnRouteDisconnect
          == rhs.prefersInterruptionOnRouteDisconnect
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(category)
      hasher.combine(mode)
      hasher.combine(options.rawValue)
      hasher.combine(allowsHapticsAndSystemSoundsDuringRecording)
      hasher.combine(prefersNoInterruptionsFromSystemAlerts)
      hasher.combine(prefersInterruptionOnRouteDisconnect)
    }
  }
#else
  import Foundation

  /// Native macOS compatibility shape for call sites that configure audio session semantics.
  /// macOS does not expose `AVAudioSession`, so this type models equivalent intent-only values.
  public struct AudioSessionConfiguration: Sendable, Hashable {
    public struct Category: RawRepresentable, Sendable, Hashable {
      public var rawValue: String
      public init(rawValue: String) {
        self.rawValue = rawValue
      }

      public static let playAndRecord = Category(rawValue: "playAndRecord")
      public static let playback = Category(rawValue: "playback")
    }

    public struct Mode: RawRepresentable, Sendable, Hashable {
      public var rawValue: String
      public init(rawValue: String) {
        self.rawValue = rawValue
      }

      public static let `default` = Mode(rawValue: "default")
      public static let measurement = Mode(rawValue: "measurement")
    }

    public struct CategoryOptions: OptionSet, Sendable, Hashable {
      public let rawValue: UInt
      public init(rawValue: UInt) {
        self.rawValue = rawValue
      }
    }

    public var category: Category
    public var mode: Mode
    public var options: CategoryOptions
    public var allowsHapticsAndSystemSoundsDuringRecording: Bool
    public var prefersNoInterruptionsFromSystemAlerts: Bool
    public var prefersInterruptionOnRouteDisconnect: Bool

    public init(
      category: Category,
      mode: Mode,
      options: CategoryOptions,
      allowsHapticsAndSystemSoundsDuringRecording: Bool = true,
      prefersNoInterruptionsFromSystemAlerts: Bool = true,
      prefersInterruptionOnRouteDisconnect: Bool = false,
    ) {
      self.category = category
      self.mode = mode
      self.options = options
      self.allowsHapticsAndSystemSoundsDuringRecording = allowsHapticsAndSystemSoundsDuringRecording
      self.prefersNoInterruptionsFromSystemAlerts = prefersNoInterruptionsFromSystemAlerts
      self.prefersInterruptionOnRouteDisconnect = prefersInterruptionOnRouteDisconnect
    }

    /// `bluetoothMicrophone` is accepted for call-site parity with iOS and
    /// ignored — macOS has no `AVAudioSession` to apply it to.
    public static func recordingConfiguration(
      useMeasurement: Bool,
      bluetoothMicrophone: BluetoothMicrophonePolicy = .handsFree,
    ) -> AudioSessionConfiguration {
      _ = bluetoothMicrophone
      return AudioSessionConfiguration(
        category: .playAndRecord,
        mode: useMeasurement ? .measurement : .default,
        options: [],
      )
    }

    public static let recordingConfiguration = recordingConfiguration(useMeasurement: false)

    public static var playbackConfiguration: AudioSessionConfiguration {
      AudioSessionConfiguration(
        category: .playback,
        mode: .default,
        options: [],
      )
    }
  }
#endif
