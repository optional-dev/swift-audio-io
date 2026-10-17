// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AVFoundation

  /// Bridges the OS 27 `installAudioTap` provider's `AVReadOnlyAudioPCMBuffer`
  /// into the `AVAudioPCMBuffer` the capture path consumes, without copying
  /// samples.
  ///
  /// `AVReadOnlyAudioPCMBuffer` is a `Sendable` struct that owns its sample
  /// storage (its span-based `channelData` borrows from `self`), so holding a
  /// copy of the struct keeps the samples alive. The view built here exploits
  /// that: its deallocator captures the read-only buffer, tying the storage's
  /// lifetime to the view's own. That closes the one hazard a bare pointer
  /// wrap would have — `AVAudioConverter`'s C core is permitted to hold its
  /// previous input buffer until the next input-proc callback, and with the
  /// lifetime tie even a held view still points at live memory.
  ///
  /// The other half of the safety argument is `processAudio` itself: its
  /// input buffer is read only inside the synchronous `converter.convert`
  /// call and is never stored in state, rings, or an escaping closure, so
  /// nothing on our side outlives the callback either.
  package enum ReadOnlyTapBufferBridge {
    /// Returns an `AVAudioPCMBuffer` view of `buffer`'s samples in place, or
    /// `nil` when the buffer's layout cannot back one (callers fall back to
    /// `AVAudioPCMBuffer(copying:)`).
    ///
    /// The buffer-list *header* is copied into a `malloc` allocation whose
    /// ownership passes to the view — `-[AVAudioBuffer dealloc]` `free`s a
    /// `bufferListNoCopy` list itself, which is why the header must come
    /// from `malloc` and why the deallocator must never free it. The sample
    /// memory the header points at stays the read-only buffer's own, kept
    /// alive by the deallocator's capture.
    package static func pcmView(of buffer: AVReadOnlyAudioPCMBuffer) -> AVAudioPCMBuffer? {
      let ownedList: UnsafeMutablePointer<AudioBufferList>? =
        unsafe buffer.withUnsafeAudioBufferList { source in
          let bufferCount = Int(unsafe source.pointee.mNumberBuffers)
          guard bufferCount > 0 else { return nil }
          let byteCount = AudioBufferList.sizeInBytes(maximumBuffers: bufferCount)
          guard let raw = unsafe malloc(byteCount) else { return nil }
          unsafe raw.copyMemory(from: UnsafeRawPointer(source), byteCount: byteCount)
          return unsafe raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        }
      guard let ownedList = unsafe ownedList else { return nil }

      guard
        let view = unsafe AVAudioPCMBuffer(
          pcmFormat: buffer.format,
          bufferListNoCopy: ownedList,
          deallocator: { _ in
            // The view frees the header on dealloc; this block's whole job
            // is the capture — the lifetime tie that keeps the read-only
            // storage the header's mData pointers reference alive for as
            // long as the view is, even if a converter holds the view past
            // the tap callback.
            withExtendedLifetime(buffer) {}
          },
        )
      else {
        unsafe free(ownedList)
        return nil
      }
      view.frameLength = AVAudioFrameCount(buffer.frameLength)
      return view
    }
  }
#endif
