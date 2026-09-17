// © GoodHatsLLC

#if canImport(AVFAudio)
  import Atomics
  public import AVFAudio
  import Foundation
  import os
  public import Tools

  private let log = SystemLog.make()

  // MARK: - Triple-Buffered LOD Storage

  /// Pre-allocated storage for one complete LOD buffer set.
  ///
  /// ## Thread Safety
  ///
  /// This class is marked `@unchecked Sendable` because thread safety is guaranteed
  /// by the triple-buffering protocol in `MultiBandLODProcessor`, NOT by internal
  /// synchronization. The safety invariants are:
  ///
  /// 1. **Single writer**: Only the audio thread writes to slots; there is no lock.
  /// 2. **Slot rotation**: The processor maintains 3 slots that rotate through states:
  ///    - Writing: Audio thread actively mutates this slot
  ///    - Current: Published for readers via atomic index, never written
  ///    - Retiring: Previous current, may still be read, never written
  /// 3. **Atomic publication**: `currentSlotIndex` is updated atomically after writes complete
  /// 4. At most one publication per `process(_:)` call. A current ref survives
  ///    the next full call as current or retiring. Readers must validate after
  ///    copying; the second subsequent publication invalidates it before reuse.
  ///    Reset requires readers and the writer to be quiescent.
  ///
  /// **Do not** access `LODBufferSlot` directly outside of `MultiBandLODProcessor`.
  /// Use `snapshotRef()` to obtain a safe `LODSnapshotRef` for reading.
  // SAFETY: Slot writes are single-writer with atomic publication; readers never see write slot.
  final class LODBufferSlot: @unchecked Sendable {
    let bands: [MutableBandBuffers]
    var writeIndex: Int = 0
    var committedLODCount: Int = 0
    var rawWriteIndex: Int = 0
    let generation = ManagedAtomic<UInt64>(0)
    let lodRatio: Int
    let rawBufferLength: Int
    let bandCount: Int

    /// Mutable band buffer storage - arrays are pre-allocated and mutated in place.
    ///
    /// Thread safety is provided by the parent `LODBufferSlot`'s triple-buffer protocol.
    /// See `LODBufferSlot` documentation for safety invariants.
    final class MutableBandBuffers {
      let bandIndex: Int
      var minBuffer: ContiguousArray<Float>
      var maxBuffer: ContiguousArray<Float>
      var rmsBuffer: ContiguousArray<Float>

      init(bandIndex: Int, capacity: Int) {
        self.bandIndex = bandIndex
        minBuffer = ContiguousArray(repeating: 0, count: capacity)
        maxBuffer = ContiguousArray(repeating: 0, count: capacity)
        rmsBuffer = ContiguousArray(repeating: 0, count: capacity)
      }

      func reset() {
        for i in minBuffer.indices {
          minBuffer[i] = 0
          maxBuffer[i] = 0
          rmsBuffer[i] = 0
        }
      }
    }

    init(configuration: MultiBandLODConfiguration) {
      lodRatio = configuration.lodRatio
      rawBufferLength = configuration.rawBufferLength
      bandCount = configuration.bandCount
      bands = (0..<configuration.bandCount).map { bandIndex in
        MutableBandBuffers(bandIndex: bandIndex, capacity: configuration.lodBufferLength)
      }
    }

    func reset() {
      writeIndex = 0
      committedLODCount = 0
      rawWriteIndex = 0
      generation.store(0, ordering: .relaxed)
      for band in bands {
        band.reset()
      }
    }

    /// Creates a snapshot by copying data (use sparingly, e.g., for file export).
    func toSnapshot() -> MultiBandLODSnapshot {
      MultiBandLODSnapshot(
        bands: bands.map { band in
          BandLODData(
            bandIndex: band.bandIndex,
            minBuffer: Array(band.minBuffer),
            maxBuffer: Array(band.maxBuffer),
            rmsBuffer: Array(band.rmsBuffer),
          )
        },
        writeIndex: writeIndex,
        lodRatio: lodRatio,
        rawBufferLength: rawBufferLength,
      )
    }
  }

  // MARK: - Raw Band Storage

  /// Shared storage for raw audio samples (single circular buffer per band).
  ///
  /// This storage is shared across all snapshots and updated lock-free by the audio thread.
  /// Readers (render thread) read from `buffers` up to `rawWriteIndex`.
  // SAFETY: Storage lifetime is processor-owned; writes are single-writer and reads are published-only.
  @unsafe final class RawBandStorage: @unchecked Sendable {
    let memory: UnsafeMutableBufferPointer<Float>
    let buffers: [UnsafeMutableBufferPointer<Float>]
    let length: Int
    let bandCount: Int

    init(bandCount: Int, length: Int) {
      unsafe self.bandCount = bandCount
      unsafe self.length = length
      let totalCount = bandCount * length
      unsafe memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: totalCount)
      unsafe memory.initialize(repeating: 0)

      var slices: [UnsafeMutableBufferPointer<Float>] = unsafe []
      for i in 0..<bandCount {
        let start = i * length
        // Create a slice (view) into the memory
        let slice = unsafe UnsafeMutableBufferPointer(
          start: memory.baseAddress! + start, count: length,
        )
        unsafe slices.append(slice)
      }
      unsafe buffers = unsafe slices
    }

    deinit {
      unsafe memory.deallocate()
    }
  }

  // MARK: - Zero-Copy Snapshot Reference

  /// A reference to LOD data for GPU rendering.
  ///
  /// This class provides access to pre-allocated buffers. Per-band access via
  /// `withContiguousLODChannel(band:channel:_:)` is zero-copy. Flat copies via
  /// `copyContiguousLODChannel(_:)` allocate.
  ///
  /// ## Thread Safety
  ///
  /// Scalar metadata is captured together at acquisition. LOD storage remains
  /// readable through one full subsequent `process(_:)` call (one publication),
  /// but can be recycled on the second publication. Check `isStillPublished`
  /// after copying and discard invalid copies. Acquire a fresh ref each frame.
  /// Reset requires quiescent readers. Raw sample storage is independently live;
  /// the captured raw cursor describes the LOD publication, not later raw writes.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// let ref = processor.snapshotRef()
  ///
  /// // Zero-copy per-band access (preferred for Metal)
  /// for band in 0..<ref.bandCount {
  ///   ref.withContiguousLODChannel(band: band, channel: .min) { ptr in
  ///     metalBuffer.contents().copyMemory(from: ptr.baseAddress!, byteCount: ...)
  ///   }
  /// }
  ///
  /// // Allocating flat access (convenience for simple cases)
  /// let flat = ref.copyContiguousLODChannel(.min)
  /// // `flat` contains all bands concatenated
  /// ```
  // SAFETY: References target atomically published non-writing slots and are frame-scoped.
  @safe public struct LODSnapshotRef: @unchecked Sendable, SnapshotProvider, LODSnapshot {
    fileprivate let slot: LODBufferSlot
    fileprivate let rawStorage: RawBandStorage?
    public let rawWriteIndexSnapshot: Int
    public let writeIndex: Int
    public let committedLODCount: Int
    public let publicationGeneration: UInt64
    private let liveGeneration: ManagedAtomic<UInt64>

    public var isStillPublished: Bool {
      liveGeneration.load(ordering: .acquiring) &- publicationGeneration < 2
    }

    /// Stable identity of this processor's publications, independent of slot rotation.
    public var sourceIdentity: ObjectIdentifier { ObjectIdentifier(liveGeneration) }

    fileprivate init(
      _ slot: LODBufferSlot, rawStorage: RawBandStorage?,
      generation: UInt64, liveGeneration: ManagedAtomic<UInt64>,
    ) {
      self.slot = slot
      unsafe self.rawStorage = rawStorage
      rawWriteIndexSnapshot = slot.rawWriteIndex
      writeIndex = slot.writeIndex
      committedLODCount = slot.committedLODCount
      publicationGeneration = generation
      self.liveGeneration = liveGeneration
    }

    public var bandCount: Int {
      slot.bandCount
    }

    public var lodRatio: Int {
      slot.lodRatio
    }

    public var rawBufferLength: Int {
      slot.rawBufferLength
    }

    public var lodBufferLength: Int {
      slot.bands.first?.minBuffer.count ?? 0
    }

    public func withContiguousLODChannel<R>(
      band: Int,
      channel: LODChannel,
      _ body: (UnsafeBufferPointer<Float>) -> R,
    ) -> R {
      precondition(
        (0..<slot.bands.count).contains(band),
        "LODSnapshotRef band index out of range: \(band), valid range: 0..<\(slot.bands.count)",
      )
      switch channel {
      case .min:
        return slot.bands[band].minBuffer.withUnsafeBufferPointer(body)
      case .max:
        return slot.bands[band].maxBuffer.withUnsafeBufferPointer(body)
      case .rms:
        return slot.bands[band].rmsBuffer.withUnsafeBufferPointer(body)
      }
    }

    /// Direct access to a band's raw buffer.
    public func withRawBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      guard let storage = unsafe rawStorage, unsafe (0..<storage.buffers.count).contains(band)
      else {
        return unsafe body(UnsafeBufferPointer(start: nil, count: 0))
      }
      return unsafe body(UnsafeBufferPointer(storage.buffers[band]))
    }

    /// Access the flat contiguous raw buffer (containing all bands).
    /// Used for single-copy upload to GPU.
    public func withFlatRawBuffer<R>(_ body: (UnsafeBufferPointer<Float>?) -> R) -> R {
      guard let storage = unsafe rawStorage else { return body(nil) }
      return unsafe body(UnsafeBufferPointer(storage.memory))
    }

    /// Convert to a copying snapshot (for compatibility or file export).
    public func toSnapshot() -> MultiBandLODSnapshot? {
      guard isStillPublished else { return nil }
      let copy = MultiBandLODSnapshot(
        bands: slot.bands.map { band in
          BandLODData(
            bandIndex: band.bandIndex, minBuffer: Array(band.minBuffer),
            maxBuffer: Array(band.maxBuffer), rmsBuffer: Array(band.rmsBuffer))
        }, writeIndex: writeIndex, lodRatio: lodRatio, rawBufferLength: rawBufferLength)
      return isStillPublished ? copy : nil
    }
  }

  public protocol SnapshotProvider {
    func toSnapshot() -> MultiBandLODSnapshot?
  }

  // MARK: - MultiBandLODProcessor

  /// Processes audio samples into multi-band Level-of-Detail data for GPU visualization.
  ///
  /// This processor implements:
  /// 1. Cascading lowpass filter bank to split audio into frequency bands
  /// 2. LOD reduction (e.g., 128:1) computing min/max/RMS per window
  /// 3. Circular buffer storage for streaming visualization
  ///
  /// Uses triple-buffering to provide lock-free snapshot access for 60fps rendering.
  /// Readers validate copies without blocking audio processing.
  // SAFETY: The processor enforces a single audio-writer model with atomic publication to readers.
  @unsafe public final class MultiBandLODProcessor: @unchecked Sendable {
    // MARK: - Configuration

    private let configuration: MultiBandLODConfiguration
    private let filterCoefficients: [BiquadCoefficients]

    // MARK: - Filter Types

    private struct BiquadCoefficients {
      let b0, b1, b2, a1, a2: Float
    }

    private struct BiquadState {
      var x1: Float = 0
      var x2: Float = 0
      var y1: Float = 0
      var y2: Float = 0

      mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
      }
    }

    // MARK: - State (Single-writer: audio thread)

    /// Filter states for cascading lowpass (one per crossover)
    private var filterStates: [BiquadState]

    private struct RunningStats {
      var minV: Float = 0
      var maxV: Float = 0
      var sumSq: Float = 0
      var count: Int = 0

      mutating func reset() {
        minV = 0
        maxV = 0
        sumSq = 0
        count = 0
      }

      mutating func add(_ v: Float) {
        if count == 0 {
          minV = v
          maxV = v
          sumSq = v * v
          count = 1
          return
        }
        if v < minV { minV = v }
        if v > maxV { maxV = v }
        sumSq += (v * v)
        count += 1
      }
    }

    /// Per-band running stats for LOD computation (current window).
    private var windowStats: [RunningStats]

    /// Raw band storage (single circular buffer per band).
    private let rawBandStorage: RawBandStorage?

    /// Current write index for raw storage (atomic).
    private let rawWriteIndex: ManagedAtomic<Int>

    // MARK: - Triple-Buffered Snapshot (Lock-free read access)

    /// Three pre-allocated buffer slots for triple buffering.
    /// Slot 0, 1, 2 rotate through: writing → current → retiring
    private let bufferSlots: [LODBufferSlot]

    /// Index of the slot currently being written to (only audio thread accesses).
    private var writeSlotIndex: Int = 0

    /// Index of the slot that's "retiring" (previously current, may still be read).
    /// This slot is never written to; it becomes the next write slot after a publish.
    private var retiringSlotIndex: Int = 2

    /// Index of the slot that's current for reading (atomic for lock-free access).
    private let currentSlotIndex: ManagedAtomic<Int>
    private let publicationGeneration = ManagedAtomic<UInt64>(0)

    /// Counter for LOD commits since last slot swap.
    private var commitsSinceSlotSwap: Int = 0

    /// Number of LOD commits between slot swaps (configurable).
    private let slotSwapInterval: Int

    /// Write index at the start of the current publish interval.
    /// Used to copy only the delta indices into the next write slot.
    private var deltaStartWriteIndex: Int = 0

    /// Number of LOD indices written since the last publish.
    private var deltaWrittenCount: Int = 0

    /// Delta from the previous swap interval. The new write slot has been inactive for 2
    /// intervals (it was retiring), so it needs both the previous and current deltas to be
    /// fully coherent. Without this, bars/discrete renderers see stale data every 3rd publish.
    private var previousDeltaStartWriteIndex: Int = 0
    private var previousDeltaWrittenCount: Int = 0

    /// Direct reference to write slot's bands for fast access.
    private var writeSlot: LODBufferSlot {
      unsafe bufferSlots[writeSlotIndex]
    }

    /// The writer's current write index (diagnostics only).
    private let writerWriteIndexAtomic: ManagedAtomic<Int>

    // MARK: - Initialization

    /// Creates a new multi-band LOD processor.
    ///
    /// - Parameters:
    ///   - configuration: Processing configuration.
    ///   - allocateRawStorage: Whether to allocate per-sample raw band storage.
    ///     Pass `false` for offline/file-based generation where only LOD data is
    ///     needed. This avoids a large allocation (bandCount × sampleRate × duration
    ///     × 4 bytes) that is unused in the offline snapshot path. Default is `true`.
    public init(
      configuration: MultiBandLODConfiguration = .default,
      allocateRawStorage: Bool = true,
    ) {
      unsafe self.configuration = configuration

      // Compute crossover frequencies
      let frequencies = configuration.crossoverMode.computeCrossoverFrequencies(
        bandCount: configuration.bandCount,
        sampleRate: configuration.sampleRate,
      )

      // Calculate Biquad coefficients for each crossover (Linkwitz-Riley 2nd Order Lowpass)
      // LR2 = Q of 0.5
      unsafe filterCoefficients = frequencies.map { freq in
        let w0 = 2.0 * Float.pi * freq / Float(configuration.sampleRate)
        let cosW = cos(w0)
        let sinW = sin(w0)
        let q: Float = 0.5
        let alpha = sinW / (2.0 * q)

        let a0 = 1.0 + alpha
        let b0 = (1.0 - cosW) / 2.0
        let b1 = 1.0 - cosW
        let b2 = (1.0 - cosW) / 2.0
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha

        return BiquadCoefficients(
          b0: b0 / a0,
          b1: b1 / a0,
          b2: b2 / a0,
          a1: a1 / a0,
          a2: a2 / a0,
        )
      }

      // Initialize filter states (one per crossover)
      // Note: frequencies.count is bandCount - 1
      unsafe filterStates = Array(repeating: BiquadState(), count: frequencies.count)

      unsafe windowStats = Array(repeating: RunningStats(), count: configuration.bandCount)
      unsafe rawBandStorage =
        unsafe allocateRawStorage
        ? RawBandStorage(
          bandCount: configuration.bandCount,
          length: configuration.rawBufferLength,
        )
        : nil
      unsafe rawWriteIndex = ManagedAtomic(0)

      // Initialize triple-buffered LOD slots (pre-allocated, never reallocated)
      unsafe bufferSlots = [
        LODBufferSlot(configuration: configuration),
        LODBufferSlot(configuration: configuration),
        LODBufferSlot(configuration: configuration),
      ]

      // Slot 0 starts as write, slot 1 starts as current for reading, slot 2 is retiring.
      unsafe writeSlotIndex = 0
      unsafe currentSlotIndex = ManagedAtomic(1)
      unsafe retiringSlotIndex = 2
      unsafe slotSwapInterval = configuration.snapshotSwapInterval
      unsafe deltaStartWriteIndex = unsafe bufferSlots[writeSlotIndex].writeIndex
      unsafe deltaWrittenCount = 0
      unsafe writerWriteIndexAtomic = unsafe ManagedAtomic(
        bufferSlots[writeSlotIndex].writeIndex,
      )

      log.info(
        "Initialized with \(configuration.bandCount) bands, LOD ratio \(configuration.lodRatio), buffer \(configuration.bufferSeconds) seconds (triple-buffered)",
      )
    }

    // MARK: - Processing

    /// Process raw audio samples through the multi-band filter bank.
    ///
    /// Samples are filtered into frequency bands, accumulated, and when
    /// enough samples are collected, LOD values (min/max/RMS) are computed
    /// and written to circular buffers.
    ///
    /// - Parameter samples: Raw audio samples (mono, normalized to [-1, 1]).
    public func process(_ samples: UnsafeBufferPointer<Float>) {
      guard !samples.isEmpty else { return }

      let bandCount = unsafe configuration.bandCount
      let lodRatio = unsafe configuration.lodRatio

      // Cache raw storage pointer outside the loop. When nil (offline path),
      // we skip per-sample raw writes entirely — only LOD data is needed.
      let rawStorage = unsafe rawBandStorage
      let rawLength = unsafe rawStorage != nil ? configuration.rawBufferLength : 1
      // Get current raw write index
      var currentRawWriteIndex = unsafe rawWriteIndex.load(ordering: .relaxed)

      for i in 0..<samples.count {
        let x = unsafe samples[i]

        // Cascading lowpass filter bank (Linkwitz-Riley 2nd Order)
        // Each band gets: (lowpass at cutoff) - (lowpass at previous cutoff)
        // Final band gets: input - (lowpass at highest cutoff)
        var lowerBoundSignal: Float = 0

        for b in 0..<bandCount {
          let part: Float
          if b == bandCount - 1 {
            // Highest band: everything above the last crossover
            part = x - lowerBoundSignal
          } else {
            // Apply Biquad lowpass filter
            let coeffs = unsafe filterCoefficients[b]
            // We use `withUnsafeMutablePointer` or just direct access since strict aliasing isn't an issue here with structs.
            // Direct access to struct members in array is fast.

            var state = unsafe filterStates[b]

            // Direct Form 1:
            // y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
            let lp =
              coeffs.b0 * x + coeffs.b1 * state.x1 + coeffs.b2 * state.x2
              - coeffs.a1 * state.y1 - coeffs.a2 * state.y2

            // Shift state
            state.x2 = state.x1
            state.x1 = x
            state.y2 = state.y1
            state.y1 = lp

            unsafe filterStates[b] = state  // Write back

            // This band's contribution
            part = lp - lowerBoundSignal
            lowerBoundSignal = lp
          }

          unsafe windowStats[b].add(part)

          // Write to raw buffer (skipped in offline mode)
          if let rawStorage = unsafe rawStorage {
            unsafe rawStorage.buffers[b][currentRawWriteIndex] = part
          }
        }

        currentRawWriteIndex = (currentRawWriteIndex + 1) % rawLength

        // Check if we have enough samples for an LOD commit
        if unsafe windowStats[0].count >= lodRatio {
          unsafe commitLOD()
        }
      }

      unsafe rawWriteIndex.store(currentRawWriteIndex, ordering: .relaxed)
      if unsafe commitsSinceSlotSwap >= slotSwapInterval {
        unsafe swapSlots()
      }
    }

    /// Process samples from a contiguous array.
    ///
    /// - Parameter samples: Raw audio samples.
    public func process(_ samples: [Float]) {
      samples.withUnsafeBufferPointer { buffer in
        unsafe process(buffer)
      }
    }

    /// Process samples from an AVAudioPCMBuffer (first channel only).
    ///
    /// - Parameter buffer: Audio buffer to process.
    @available(iOS 13.0, macOS 10.15, *)
    public func process(_ buffer: AVFAudio.AVAudioPCMBuffer) {
      guard let floatData = unsafe buffer.floatChannelData?[0] else { return }
      let bufferPointer = unsafe UnsafeBufferPointer(
        start: floatData,
        count: Int(buffer.frameLength),
      )
      unsafe process(bufferPointer)
    }

    // MARK: - LOD Commit

    private func commitLOD() {
      // Write directly to pre-allocated triple-buffered slot (zero allocation)
      let slot = unsafe writeSlot
      let wIdx = slot.writeIndex
      let bandCount = unsafe configuration.bandCount

      for b in 0..<bandCount {
        let stats = unsafe windowStats[b]
        guard stats.count != 0 else { continue }
        let count = Float(stats.count)

        // Write directly to pre-allocated buffers (no allocation)
        slot.bands[b].minBuffer[wIdx] = stats.minV
        slot.bands[b].maxBuffer[wIdx] = stats.maxV
        slot.bands[b].rmsBuffer[wIdx] = sqrt(stats.sumSq / count)
      }

      slot.writeIndex = unsafe (wIdx + 1) % configuration.lodBufferLength
      slot.committedLODCount += 1
      unsafe deltaWrittenCount += 1
      unsafe writerWriteIndexAtomic.store(slot.writeIndex, ordering: .relaxed)

      for i in unsafe windowStats.indices {
        unsafe windowStats[i].reset()
      }

      // Publication happens once, after the complete process call.
      unsafe commitsSinceSlotSwap += 1
    }

    /// Swaps the write slot to become current, picks a new write slot.
    /// Called by the single writer after a process call or by finalize; no lock.
    private func swapSlots() {
      // Current slot is safe for readers; write slot contains freshly committed data.
      let oldCurrent = unsafe currentSlotIndex.load(ordering: .acquiring)
      let oldWrite = unsafe writeSlotIndex
      let oldRetiring = unsafe retiringSlotIndex

      let newCurrent = oldWrite
      let newRetiring = oldCurrent
      let newWrite = oldRetiring

      let publishedSlot = unsafe bufferSlots[newCurrent]
      let nextWriteSlot = unsafe bufferSlots[newWrite]

      publishedSlot.rawWriteIndex = unsafe rawWriteIndex.load(ordering: .relaxed)
      publishedSlot.generation.store(
        unsafe publicationGeneration.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
      // Invalidate old retiring refs BEFORE touching their storage. Readers
      // also match the slot generation to avoid acquiring between these stores.
      unsafe currentSlotIndex.store(newCurrent, ordering: .releasing)
      unsafe publicationGeneration.wrappingIncrement(ordering: .acquiringAndReleasing)
      unsafe commitsSinceSlotSwap = 0

      // The new write slot (old retiring) has been inactive for 2 swap intervals.
      // Copy both the previous interval's delta AND the current interval's delta
      // so it has a fully coherent history buffer. Without this, discrete renderers
      // (e.g. bar-style waveforms) see stale data every 3rd publish cycle.
      unsafe copyDeltaIndices(
        from: publishedSlot,
        to: nextWriteSlot,
        startWriteIndex: previousDeltaStartWriteIndex,
        count: previousDeltaWrittenCount,
      )
      unsafe copyDeltaIndices(
        from: publishedSlot,
        to: nextWriteSlot,
        startWriteIndex: deltaStartWriteIndex,
        count: deltaWrittenCount,
      )

      // Continue writing at the same circular index.
      nextWriteSlot.writeIndex = publishedSlot.writeIndex
      nextWriteSlot.committedLODCount = publishedSlot.committedLODCount

      // Rotate roles.
      unsafe retiringSlotIndex = newRetiring
      unsafe writeSlotIndex = newWrite

      // Save current delta as previous, then reset for the next interval.
      unsafe previousDeltaStartWriteIndex = deltaStartWriteIndex
      unsafe previousDeltaWrittenCount = deltaWrittenCount
      unsafe deltaStartWriteIndex = nextWriteSlot.writeIndex
      unsafe deltaWrittenCount = 0
      unsafe writerWriteIndexAtomic.store(nextWriteSlot.writeIndex, ordering: .relaxed)
    }

    private func copyDeltaIndices(
      from source: LODBufferSlot,
      to destination: LODBufferSlot,
      startWriteIndex: Int,
      count: Int,
    ) {
      let lodLength = unsafe configuration.lodBufferLength
      guard lodLength > 0 else { return }

      let copyCount = min(max(count, 0), lodLength)
      guard copyCount > 0 else { return }

      if count >= lodLength {
        for idx in 0..<lodLength {
          for b in unsafe 0..<configuration.bandCount {
            destination.bands[b].minBuffer[idx] = source.bands[b].minBuffer[idx]
            destination.bands[b].maxBuffer[idx] = source.bands[b].maxBuffer[idx]
            destination.bands[b].rmsBuffer[idx] = source.bands[b].rmsBuffer[idx]
          }
        }
      } else {
        var idx = startWriteIndex % lodLength
        if idx < 0 { idx += lodLength }

        for _ in 0..<copyCount {
          for b in unsafe 0..<configuration.bandCount {
            destination.bands[b].minBuffer[idx] = source.bands[b].minBuffer[idx]
            destination.bands[b].maxBuffer[idx] = source.bands[b].maxBuffer[idx]
            destination.bands[b].rmsBuffer[idx] = source.bands[b].rmsBuffer[idx]
          }
          idx += 1
          if idx == lodLength { idx = 0 }
        }
      }
    }

    // MARK: - Snapshot

    /// Returns a zero-copy reference to current LOD data for rendering.
    ///
    /// This method is lock-free and returns a reference to pre-allocated buffers.
    /// No memory allocation or copying occurs. The next process call can retire
    /// this slot but cannot recycle it. Validate `isStillPublished` after upload.
    ///
    /// - Returns: Zero-copy reference to LOD data for GPU rendering.
    public func snapshotRef() -> LODSnapshotRef {
      while true {
        let generation = unsafe publicationGeneration.load(ordering: .acquiring)
        let index = unsafe currentSlotIndex.load(ordering: .acquiring)
        let slot = unsafe bufferSlots[index]
        guard slot.generation.load(ordering: .acquiring) == generation else { continue }
        let ref = unsafe LODSnapshotRef(
          slot, rawStorage: rawBandStorage,
          generation: generation, liveGeneration: publicationGeneration)
        guard unsafe publicationGeneration.load(ordering: .acquiring) == generation else {
          continue
        }
        return ref
      }
    }

    /// Provides a frame-scoped zero-copy snapshot reference.
    ///
    /// Prefer this in render loops to avoid retaining `LODSnapshotRef` across frames.
    public func withCurrentLODSnapshotRef<R>(_ body: (LODSnapshotRef) -> R) -> R {
      unsafe body(snapshotRef())
    }

    /// Creates a snapshot of current LOD data for rendering.
    ///
    /// This method is lock-free but does create a copy of the data.
    /// For zero-copy access, use `snapshotRef()` instead.
    ///
    /// - Returns: Complete LOD snapshot ready for GPU rendering.
    public func snapshot() -> MultiBandLODSnapshot {
      while true {
        if let copy = unsafe snapshotRef().toSnapshot() { return copy }
      }
    }

    /// Creates a snapshot with explicit locking (for diagnostics).
    ///
    /// Use this method only when you need the absolute latest data
    /// and can tolerate potential blocking.
    ///
    /// - Returns: Most up-to-date LOD snapshot.
    public func snapshotLocking() -> MultiBandLODSnapshot {
      return unsafe writeSlot.toSnapshot()
    }

    /// Flushes any partially-accumulated LOD window into the buffers.
    ///
    /// `process(_:)` only commits when it has seen a full `lodRatio` samples.
    /// For offline/file-based workflows (e.g. rendering a waveform for an exact
    /// time range), you typically want the final partial window to be included.
    ///
    /// Commits any partial window and publishes all pending commits, including
    /// a final full window below the normal publication threshold.
    public func finalize() {
      if unsafe windowStats.first?.count ?? 0 > 0 {
        unsafe commitLOD()
      }
      if unsafe commitsSinceSlotSwap > 0 { unsafe swapSlots() }
    }

    // MARK: - Reset

    /// Resets all buffers and filter states.
    ///
    /// Call this when starting a new recording.
    /// swift-format-ignore
    public func reset() {
      // Reset filter states
      for i in unsafe filterStates.indices {
        unsafe filterStates[i].reset()
      }

      for i in unsafe windowStats.indices {
        unsafe windowStats[i].reset()
      }

      // Reset all triple-buffered slots (in-place, no allocation)
      for slot in unsafe bufferSlots {
        slot.reset()
      }

      // Reset slot indices
      unsafe writeSlotIndex = 0
      unsafe currentSlotIndex.store(1, ordering: .releasing)
      unsafe publicationGeneration.store(0, ordering: .releasing)
      unsafe retiringSlotIndex = 2
      unsafe commitsSinceSlotSwap = 0
      unsafe deltaStartWriteIndex = unsafe bufferSlots[writeSlotIndex].writeIndex
      unsafe deltaWrittenCount = 0
      unsafe previousDeltaStartWriteIndex = unsafe bufferSlots[writeSlotIndex].writeIndex
      unsafe previousDeltaWrittenCount = 0
      unsafe writerWriteIndexAtomic.store(
        bufferSlots[writeSlotIndex].writeIndex, ordering: .relaxed,
      )

      unsafe rawWriteIndex.store(0, ordering: .relaxed)
      // Zero out raw buffers
      if let rawBandStorage = unsafe rawBandStorage {
        unsafe rawBandStorage.buffers.forEach {
          unsafe $0.initialize(repeating: 0)
        }
      }

      log.info("Reset all buffers (triple-buffered)")
    }

    // MARK: - Diagnostics

    /// The published write index (safe for renderers).
    public var publishedWriteIndex: Int {
      let index = unsafe currentSlotIndex.load(ordering: .acquiring)
      return unsafe bufferSlots[index].writeIndex
    }

    /// The writer's current write index (diagnostics only).
    public var writerWriteIndex: Int {
      unsafe writerWriteIndexAtomic.load(ordering: .relaxed)
    }

    /// Current write index in the circular buffer.
    ///
    /// This is the published write index (safe for renderers).
    public var currentWriteIndex: Int {
      unsafe publishedWriteIndex
    }
  }

  // MARK: - Offline Generation

  extension MultiBandLODProcessor {
    /// Errors that can occur during LOD generation.
    public enum LODGenerationError: AudioError, LocalizedError {
      case cancelled
      case bufferCreationFailed
      case invalidAudioFormat
      case audioFileOpenFailed(url: URL, error: ErrorContext)
      case audioFileReadFailed(url: URL, error: ErrorContext)

      public var errorDescription: String? {
        switch self {
        case .cancelled:
          "LOD generation was cancelled"
        case .bufferCreationFailed:
          "Failed to create audio buffer for processing"
        case .invalidAudioFormat:
          "Audio file has an unsupported format"
        case .audioFileOpenFailed(let url, let error):
          "Failed to open audio file \(url.lastPathComponent): \(error)"
        case .audioFileReadFailed(let url, let error):
          "Failed to read audio file \(url.lastPathComponent): \(error)"
        }
      }

      public var description: String {
        errorDescription ?? String(describing: self)
      }
    }
  }

  // MARK: - BandLODData Extension

  extension BandLODData {
    /// Creates a band LOD data container with explicit buffer data.
    ///
    /// - Parameters:
    ///   - bandIndex: Index of this band.
    ///   - minBuffer: Pre-populated minimum values.
    ///   - maxBuffer: Pre-populated maximum values.
    ///   - rmsBuffer: Pre-populated RMS values.
    init(bandIndex: Int, minBuffer: [Float], maxBuffer: [Float], rmsBuffer: [Float]) {
      self.bandIndex = bandIndex
      self.minBuffer = minBuffer
      self.maxBuffer = maxBuffer
      self.rmsBuffer = rmsBuffer
    }
  }

#endif
