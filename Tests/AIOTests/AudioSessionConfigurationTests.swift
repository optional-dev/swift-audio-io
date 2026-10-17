// © GoodHatsLLC

import Testing

@testable import AIOAudioSession

#if os(iOS)
  import AVFAudio
#endif

struct AudioSessionConfigurationTests {
  @Test
  func `recording configuration derives measurement mode from its input`() {
    let standard = AudioSessionConfiguration.recordingConfiguration(useMeasurement: false)
    let measurement = AudioSessionConfiguration.recordingConfiguration(useMeasurement: true)

    #expect(standard.mode == .default)
    #expect(measurement.mode == .measurement)
    #expect(AudioSessionConfiguration.recordingConfiguration.mode == .default)
  }

  @Test
  func `bluetooth microphone policy maps to category options`() {
    #if os(iOS)
      let handsFree = AudioSessionConfiguration.recordingConfiguration(
        useMeasurement: false, bluetoothMicrophone: .handsFree,
      )
      #expect(handsFree.options.contains(.allowBluetoothHFP))
      #expect(handsFree.options.contains(.allowBluetoothA2DP))

      // The default is behavior-preserving: exactly the hands-free option set.
      #expect(
        AudioSessionConfiguration.recordingConfiguration(useMeasurement: false) == handsFree,
      )

      let never = AudioSessionConfiguration.recordingConfiguration(
        useMeasurement: false, bluetoothMicrophone: .never,
      )
      #expect(!never.options.contains(.allowBluetoothHFP))
      #expect(never.options.contains(.allowBluetoothA2DP))

      let highQuality = AudioSessionConfiguration.recordingConfiguration(
        useMeasurement: false, bluetoothMicrophone: .highQualityWhenAvailable,
      )
      #expect(highQuality.options.contains(.allowBluetoothHFP))
      #expect(highQuality.options.contains(.bluetoothHighQualityRecording))
      // High-quality Bluetooth recording is default-mode only; measurement
      // configurations must not carry the option.
      let measurement = AudioSessionConfiguration.recordingConfiguration(
        useMeasurement: true, bluetoothMicrophone: .highQualityWhenAvailable,
      )
      #expect(!measurement.options.contains(.bluetoothHighQualityRecording))
    #else
      // macOS has no AVAudioSession; the parameter is accepted and ignored.
      let a = AudioSessionConfiguration.recordingConfiguration(
        useMeasurement: false, bluetoothMicrophone: .never,
      )
      let b = AudioSessionConfiguration.recordingConfiguration(useMeasurement: false)
      #expect(a == b)
    #endif
  }
}
