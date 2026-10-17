// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOEngineCore
  import AVFoundation
  import Testing

  /// The OS 27 `installAudioTap` provider hands out `AVReadOnlyAudioPCMBuffer`;
  /// the capture path bridges it back into an `AVAudioPCMBuffer` — zero-copy
  /// via `ReadOnlyTapBufferBridge.pcmView(of:)`, falling back to
  /// `AVAudioPCMBuffer(copying:)`. This verifies both bridges preserve format,
  /// length, and samples, that the view really aliases the read-only samples
  /// instead of copying them, and that nothing downstream of the tap retains
  /// the view past conversion — the contracts the tap bridge in
  /// `AIOEngine+TapSetup` relies on.
  struct ReadOnlyBufferBridgeTests {
    @Test
    func `read-only buffer round-trip preserves format and samples`() throws {

      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
      source.frameLength = 256
      let channel = try #require(source.floatChannelData?[0])
      for frame in 0..<256 {
        unsafe channel[frame] = Float(frame) / 256
      }

      let readOnly = AVReadOnlyAudioPCMBuffer(copying: source)
      #expect(readOnly.frameLength == 256)
      #expect(readOnly.format == format)

      let bridged = AVAudioPCMBuffer(copying: readOnly)
      #expect(bridged.frameLength == 256)
      #expect(bridged.format == format)
      let bridgedChannel = try #require(bridged.floatChannelData?[0])
      for frame in 0..<256 {
        #expect(unsafe bridgedChannel[frame] == Float(frame) / 256)
      }
    }

    @Test
    func `zero-copy view aliases the read-only samples and preserves metadata`() throws {

      // Stereo, so the bridge's buffer-list header copy has to carry more
      // than the first AudioBuffer.
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
      )
      let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
      source.frameLength = 240
      for channel in 0..<2 {
        let samples = try #require(source.floatChannelData?[channel])
        for frame in 0..<240 {
          unsafe samples[frame] = (channel == 0 ? 1 : -1) * Float(frame) / 240
        }
      }

      let readOnly = AVReadOnlyAudioPCMBuffer(copying: source)
      let view = try #require(ReadOnlyTapBufferBridge.pcmView(of: readOnly))
      #expect(view.format == format)
      #expect(view.frameLength == 240)

      // Zero-copy means the view's channel pointers are the read-only
      // buffer's own sample memory, not a duplicate of it.
      unsafe readOnly.withUnsafeAudioBufferList { list in
        let buffers = unsafe UnsafeMutableAudioBufferListPointer(
          UnsafeMutablePointer(mutating: list),
        )
        for channel in 0..<2 {
          let viewChannel = view.floatChannelData
            .map { unsafe UnsafeMutableRawPointer($0[channel]) }
          #expect(unsafe viewChannel == buffers[channel].mData)
        }
      }

      for channel in 0..<2 {
        let samples = try #require(view.floatChannelData?[channel])
        for frame in 0..<240 {
          #expect(unsafe samples[frame] == (channel == 0 ? 1 : -1) * Float(frame) / 240)
        }
      }
    }

    @Test
    func `zero-copy view converts identically to the copy bridge`() throws {

      // The same downsampling conversion processAudio performs, fed once by
      // each bridge. Identical converters over identical samples must yield
      // bit-identical output — the view is a drop-in for the copy.
      let inputFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      let outputFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      )
      let source = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
      source.frameLength = 480
      let sourceChannel = try #require(source.floatChannelData?[0])
      for frame in 0..<480 {
        unsafe sourceChannel[frame] = sin(Float(frame) * 0.05)
      }
      let readOnly = AVReadOnlyAudioPCMBuffer(copying: source)

      func convertOnce(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))
        let output = try #require(
          AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 160),
        )
        var provided = false
        var error: NSError?
        let status = unsafe converter.convert(to: output, error: &error) { _, outStatus in
          if provided {
            unsafe outStatus.pointee = .noDataNow
            return nil
          }
          provided = true
          unsafe outStatus.pointee = .haveData
          return input
        }
        #expect(status != .error)
        return output
      }

      let view = try #require(ReadOnlyTapBufferBridge.pcmView(of: readOnly))
      let fromView = try convertOnce(view)
      let fromCopy = try convertOnce(AVAudioPCMBuffer(copying: readOnly))

      #expect(fromView.frameLength == fromCopy.frameLength)
      #expect(fromView.frameLength > 0)
      let viewChannel = try #require(fromView.floatChannelData?[0])
      let copyChannel = try #require(fromCopy.floatChannelData?[0])
      for frame in 0..<Int(fromView.frameLength) {
        #expect(unsafe viewChannel[frame] == copyChannel[frame])
      }
    }

    @Test
    func `zero-copy view is released once conversion completes`() throws {

      // The plan gated zero-copy adoption on processAudio not retaining its
      // input past return. The view's deallocator keeps the read-only
      // storage alive even if AVAudioConverter held its last input buffer
      // across calls, but this documents the observed behavior: once the
      // converter is gone, so is the view — no retention accumulates.
      let inputFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      let outputFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      )
      let source = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
      source.frameLength = 480
      let readOnly = AVReadOnlyAudioPCMBuffer(copying: source)

      weak var weakView: AVAudioPCMBuffer?
      try autoreleasepool {
        let view = try #require(ReadOnlyTapBufferBridge.pcmView(of: readOnly))
        weakView = view
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))
        let output = try #require(
          AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 160),
        )
        var provided = false
        var error: NSError?
        _ = unsafe converter.convert(to: output, error: &error) { _, outStatus in
          if provided {
            unsafe outStatus.pointee = .noDataNow
            return nil
          }
          provided = true
          unsafe outStatus.pointee = .haveData
          return view
        }
      }
      #expect(weakView == nil)
    }
  }
#endif
