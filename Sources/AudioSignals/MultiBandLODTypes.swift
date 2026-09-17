// © GoodHatsLLC

#if canImport(AVFAudio)
  import Foundation

  // MARK: - Configuration

  /// Configuration for multi-band Level-of-Detail visualization processing.
  ///
  /// This configuration controls how audio is split into frequency bands and
  /// downsampled for efficient GPU-based waveform rendering.
  public struct MultiBandLODConfiguration: Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
      case bandCountOutOfRange(actual: Int, valid: ClosedRange<Int>)
      case lodRatioMustBePositive(actual: Int)
      case bufferSecondsMustBePositive(actual: Int)
      case sampleRateMustBePositive(actual: Int)
      case snapshotSwapIntervalMustBePositive(actual: Int)
      case rawBufferLengthOverrideMustBePositive(actual: Int)
      case rawBufferLengthOverflow(sampleRate: Int, bufferSeconds: Int)

      public var description: String {
        switch self {
        case .bandCountOutOfRange(let actual, let valid):
          "bandCount must be in \(valid), got \(actual)"
        case .lodRatioMustBePositive(let actual):
          "lodRatio must be > 0, got \(actual)"
        case .bufferSecondsMustBePositive(let actual):
          "bufferSeconds must be > 0, got \(actual)"
        case .sampleRateMustBePositive(let actual):
          "sampleRate must be > 0, got \(actual)"
        case .snapshotSwapIntervalMustBePositive(let actual):
          "snapshotSwapInterval must be > 0, got \(actual)"
        case .rawBufferLengthOverrideMustBePositive(let actual):
          "rawBufferLengthOverride must be > 0, got \(actual)"
        case .rawBufferLengthOverflow(let sampleRate, let bufferSeconds):
          "rawBufferLength overflow: sampleRate=\(sampleRate) bufferSeconds=\(bufferSeconds)"
        }
      }
    }

    public static let validBandCountRange: ClosedRange<Int> = 1...128

    /// Number of frequency bands to split audio into (3-8 recommended).
    public let bandCount: Int

    /// Level-of-detail reduction ratio (samples per LOD bucket).
    /// Default is 128, meaning 128 raw samples become 1 LOD sample.
    public let lodRatio: Int

    /// Maximum buffer duration in seconds.
    /// Default is 300 (5 minutes).
    public let bufferSeconds: Int

    /// Optional override for the raw buffer length in samples.
    ///
    /// When set, this value is used instead of `sampleRate * bufferSeconds` for
    /// buffer sizing and shader mapping. This is primarily intended for offline
    /// (file-based) generation where the exact file frame count is known and
    /// rounding to whole seconds would introduce extra empty space.
    public let rawBufferLengthOverride: Int?

    /// Audio sample rate in Hz.
    /// Default is 44100.
    public let sampleRate: Int

    /// How to split frequencies across bands.
    public let crossoverMode: CrossoverMode

    /// Minimum number of LOD commits between snapshot slot swaps.
    /// Controls how frequently the render thread sees updated data.
    /// Default is 6. Publication occurs at the end of a process call, at most
    /// once per call, and includes every commit in that call.
    /// Lower values = more frequent updates but more atomic operations.
    /// Higher values = less frequent updates but lower overhead.
    public let snapshotSwapInterval: Int

    /// Computed property: number of raw samples in the buffer.
    public var rawBufferLength: Int {
      if let rawBufferLengthOverride {
        return max(rawBufferLengthOverride, 1)
      }
      return Self.rawBufferLength(sampleRate: sampleRate, bufferSeconds: bufferSeconds)
    }

    /// Computed property: number of LOD samples per band.
    public var lodBufferLength: Int {
      let rawBufferLength = rawBufferLength
      let lodRatio = max(lodRatio, 1)
      return (rawBufferLength / lodRatio) + (rawBufferLength.isMultiple(of: lodRatio) ? 0 : 1)
    }

    /// Creates a new multi-band LOD configuration.
    ///
    /// - Parameters:
    ///   - bandCount: Number of frequency bands (3-8 recommended, 1...128 valid). Default: 5.
    ///   - lodRatio: Samples per LOD bucket. Default: 128.
    ///   - bufferSeconds: Maximum buffer duration. Default: 300.
    ///   - sampleRate: Audio sample rate. Default: 44100.
    ///   - crossoverMode: Frequency splitting mode. Default: Mel scale.
    ///   - snapshotSwapInterval: Minimum LOD commits before publication. Default: 6.
    public init(
      bandCount: Int = 5,
      lodRatio: Int = 128,
      bufferSeconds: Int = 300,
      sampleRate: Int = 44100,
      crossoverMode: CrossoverMode = .mel(minFreq: 40, maxFreq: 15000),
      snapshotSwapInterval: Int = 6,
      rawBufferLengthOverride: Int? = nil,
    ) {
      let normalized = Self.clampedParameters(
        bandCount: bandCount,
        lodRatio: lodRatio,
        bufferSeconds: bufferSeconds,
        sampleRate: sampleRate,
        snapshotSwapInterval: snapshotSwapInterval,
        rawBufferLengthOverride: rawBufferLengthOverride,
      )
      self.bandCount = normalized.bandCount
      self.lodRatio = normalized.lodRatio
      self.bufferSeconds = normalized.bufferSeconds
      self.sampleRate = normalized.sampleRate
      self.crossoverMode = crossoverMode
      self.snapshotSwapInterval = normalized.snapshotSwapInterval
      self.rawBufferLengthOverride = normalized.rawBufferLengthOverride
    }

    /// Creates a configuration from untrusted values and throws on invalid input.
    public init(
      validatingBandCount bandCount: Int,
      lodRatio: Int = 128,
      bufferSeconds: Int = 300,
      sampleRate: Int = 44100,
      crossoverMode: CrossoverMode = .mel(minFreq: 40, maxFreq: 15000),
      snapshotSwapInterval: Int = 6,
      rawBufferLengthOverride: Int? = nil,
    ) throws(ValidationError) {
      guard Self.validBandCountRange.contains(bandCount) else {
        throw .bandCountOutOfRange(actual: bandCount, valid: Self.validBandCountRange)
      }
      guard lodRatio > 0 else {
        throw .lodRatioMustBePositive(actual: lodRatio)
      }
      guard bufferSeconds > 0 else {
        throw .bufferSecondsMustBePositive(actual: bufferSeconds)
      }
      guard sampleRate > 0 else {
        throw .sampleRateMustBePositive(actual: sampleRate)
      }
      guard snapshotSwapInterval > 0 else {
        throw .snapshotSwapIntervalMustBePositive(actual: snapshotSwapInterval)
      }
      if let rawBufferLengthOverride, rawBufferLengthOverride <= 0 {
        throw .rawBufferLengthOverrideMustBePositive(actual: rawBufferLengthOverride)
      }
      let (_, overflow) = sampleRate.multipliedReportingOverflow(by: bufferSeconds)
      guard !overflow else {
        throw .rawBufferLengthOverflow(sampleRate: sampleRate, bufferSeconds: bufferSeconds)
      }
      self.init(
        uncheckedBandCount: bandCount,
        lodRatio: lodRatio,
        bufferSeconds: bufferSeconds,
        sampleRate: sampleRate,
        crossoverMode: crossoverMode,
        snapshotSwapInterval: snapshotSwapInterval,
        rawBufferLengthOverride: rawBufferLengthOverride,
      )
    }

    /// Convenience initializer that clamps out-of-range values.
    public init(
      clamping bandCount: Int,
      lodRatio: Int = 128,
      bufferSeconds: Int = 300,
      sampleRate: Int = 44100,
      crossoverMode: CrossoverMode = .mel(minFreq: 40, maxFreq: 15000),
      snapshotSwapInterval: Int = 6,
      rawBufferLengthOverride: Int? = nil,
    ) {
      self.init(
        bandCount: min(
          max(bandCount, Self.validBandCountRange.lowerBound), Self.validBandCountRange.upperBound,
        ),
        lodRatio: max(1, lodRatio),
        bufferSeconds: max(1, bufferSeconds),
        sampleRate: max(1, sampleRate),
        crossoverMode: crossoverMode,
        snapshotSwapInterval: max(1, snapshotSwapInterval),
        rawBufferLengthOverride: rawBufferLengthOverride.map { max(1, $0) },
      )
    }

    /// Default configuration optimized for real-time recording visualization.
    public static let `default` = MultiBandLODConfiguration()

    /// Configuration for shorter recordings (1 minute buffer).
    public static let shortRecording = MultiBandLODConfiguration(
      bandCount: 5,
      lodRatio: 128,
      bufferSeconds: 60,
    )

    /// High-detail configuration with more bands.
    public static let highDetail = MultiBandLODConfiguration(
      bandCount: 8,
      lodRatio: 64,
      bufferSeconds: 300,
    )

    private init(
      uncheckedBandCount bandCount: Int,
      lodRatio: Int,
      bufferSeconds: Int,
      sampleRate: Int,
      crossoverMode: CrossoverMode,
      snapshotSwapInterval: Int,
      rawBufferLengthOverride: Int?,
    ) {
      self.bandCount = bandCount
      self.lodRatio = lodRatio
      self.bufferSeconds = bufferSeconds
      self.sampleRate = sampleRate
      self.crossoverMode = crossoverMode
      self.snapshotSwapInterval = snapshotSwapInterval
      self.rawBufferLengthOverride = rawBufferLengthOverride
    }

    private static func clampedParameters(
      bandCount: Int,
      lodRatio: Int,
      bufferSeconds: Int,
      sampleRate: Int,
      snapshotSwapInterval: Int,
      rawBufferLengthOverride: Int?,
    ) -> (
      bandCount: Int,
      lodRatio: Int,
      bufferSeconds: Int,
      sampleRate: Int,
      snapshotSwapInterval: Int,
      rawBufferLengthOverride: Int?
    ) {
      (
        bandCount: min(
          max(bandCount, validBandCountRange.lowerBound), validBandCountRange.upperBound,
        ),
        lodRatio: max(1, lodRatio),
        bufferSeconds: max(1, bufferSeconds),
        sampleRate: max(1, sampleRate),
        snapshotSwapInterval: max(1, snapshotSwapInterval),
        rawBufferLengthOverride: rawBufferLengthOverride.map { max(1, $0) },
      )
    }

    private static func rawBufferLength(sampleRate: Int, bufferSeconds: Int) -> Int {
      let (rawBufferLength, overflow) = sampleRate.multipliedReportingOverflow(by: bufferSeconds)
      return overflow ? Int.max : max(rawBufferLength, 1)
    }
  }

  // MARK: - Crossover Mode

  /// Defines how frequencies are split across bands.
  public enum CrossoverMode: Sendable, Equatable {
    /// Mel scale splitting (perceptually uniform).
    /// Places more bands in lower frequencies where human hearing is more sensitive.
    case mel(minFreq: Float, maxFreq: Float)

    /// Linear frequency splitting.
    /// Each band covers an equal frequency range.
    case linear(minFreq: Float, maxFreq: Float)

    /// Custom crossover frequencies.
    /// Specify exact cutoff frequencies between bands.
    case custom(frequencies: [Float])

    /// Compute crossover frequencies for the bands.
    ///
    /// - Parameters:
    ///   - bandCount: Number of bands to split into.
    ///   - sampleRate: Audio sample rate.
    /// - Returns: Array of crossover frequencies (Hz). Count is `max(bandCount - 1, 0)`.
    public func computeCrossoverFrequencies(bandCount: Int, sampleRate: Int) -> [Float] {
      let nyquist = Float(sampleRate) * 0.5

      func clampFrequency(_ f: Float) -> Float {
        let maxF = max(1.0, nyquist * 0.98)
        return min(max(f, 1.0), maxF)
      }

      let desiredCutoffCount = max(bandCount - 1, 0)
      var cutoffFrequencies: [Float] = []
      cutoffFrequencies.reserveCapacity(desiredCutoffCount)

      switch self {
      case .mel(let minFreq, let maxFreq):
        /// Mel scale conversion functions
        func hzToMel(_ hz: Float) -> Float {
          2595 * log10(1 + hz / 700)
        }
        func melToHz(_ mel: Float) -> Float {
          700 * (pow(10, mel / 2595) - 1)
        }

        let minHz = clampFrequency(min(minFreq, maxFreq))
        let maxHz = clampFrequency(max(minFreq, maxFreq))
        let minMel = hzToMel(minHz)
        let maxMel = hzToMel(maxHz)

        for i in 1..<(desiredCutoffCount + 1) {
          let t = Float(i) / Float(bandCount)
          let mel = minMel + (t * (maxMel - minMel))
          let freq = melToHz(mel)
          cutoffFrequencies.append(freq)
        }

      case .linear(let minFreq, let maxFreq):
        let minHz = clampFrequency(min(minFreq, maxFreq))
        let maxHz = clampFrequency(max(minFreq, maxFreq))
        let range = maxHz - minHz
        for i in 1..<(desiredCutoffCount + 1) {
          let t = Float(i) / Float(bandCount)
          cutoffFrequencies.append(minHz + (t * range))
        }

      case .custom(let frequencies):
        let cleaned =
          frequencies
          .map(clampFrequency)
          .sorted()

        cutoffFrequencies = Array(cleaned.prefix(desiredCutoffCount))

        if cutoffFrequencies.count < desiredCutoffCount {
          #if DEBUG
            assertionFailure(
              "CrossoverMode.custom expected \(desiredCutoffCount) frequencies, got \(frequencies.count). Padding to fit bandCount.",
            )
          #endif
          let start = cutoffFrequencies.last ?? clampFrequency(40)
          let end = clampFrequency(nyquist * 0.98)
          let remaining = desiredCutoffCount - cutoffFrequencies.count
          if remaining > 0 {
            let step = (end - start) / Float(remaining + 1)
            for i in 1...remaining {
              cutoffFrequencies.append(start + (Float(i) * step))
            }
          }
        }
      }

      cutoffFrequencies = cutoffFrequencies.map(clampFrequency)

      // Ensure strictly ascending cutoffs (avoid accidental duplicates after clamping).
      if cutoffFrequencies.count >= 2 {
        for i in 1..<cutoffFrequencies.count {
          if cutoffFrequencies[i] <= cutoffFrequencies[i - 1] {
            cutoffFrequencies[i] = min(cutoffFrequencies[i - 1] + 1.0, nyquist * 0.98)
          }
        }
      }

      return cutoffFrequencies
    }
  }

  // MARK: - LOD Snapshot Protocol

  /// Channel selector for contiguous LOD data access.
  public enum LODChannel: Sendable, CaseIterable {
    case min
    case max
    case rms
  }

  /// Describes how LOD buckets map onto their source timeline.
  public enum LODTimelineLayout: Sendable, Equatable {
    /// A live ring buffer whose write index advances and wraps.
    case liveCircular

    /// An immutable, zero-based file timeline.
    ///
    /// `availableRawSampleCount` is the prefix represented by committed LOD
    /// buckets. `totalRawSampleCount` excludes any allocation padding in
    /// ``LODSnapshot/rawBufferLength``.
    case staticLinear(
      availableRawSampleCount: Int,
      totalRawSampleCount: Int,
    )
  }

  /// Protocol defining the interface for LOD snapshot data sources.
  ///
  /// This protocol is implemented by both `LODSnapshotRef` (for live streaming
  /// data) and `MultiBandLODSnapshot` (for copied or pre-computed file data),
  /// allowing renderers to consume either type uniformly.
  public protocol LODSnapshot: Sendable {
    /// Number of frequency bands.
    var bandCount: Int { get }

    /// Next write position in LOD storage.
    ///
    /// Consult ``timelineLayout`` to determine whether this position wraps or
    /// represents the end of a linear prefix.
    var writeIndex: Int { get }

    /// LOD reduction ratio used.
    var lodRatio: Int { get }

    /// Raw buffer length (for shader calculations).
    var rawBufferLength: Int { get }

    /// LOD buffer length per band.
    var lodBufferLength: Int { get }

    /// Mapping between LOD storage and its source timeline.
    var timelineLayout: LODTimelineLayout { get }

    /// Direct access to one channel for a specific band.
    ///
    /// This is the zero-copy primitive API. Existing per-channel helpers
    /// (`withMinBuffer`, `withMaxBuffer`, `withRMSBuffer`) are wrappers.
    func withContiguousLODChannel<R>(
      band: Int,
      channel: LODChannel,
      _ body: (UnsafeBufferPointer<Float>) -> R,
    ) -> R

    /// Direct access to a band's min buffer.
    func withMinBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R

    /// Direct access to a band's max buffer.
    func withMaxBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R

    /// Direct access to a band's RMS buffer.
    func withRMSBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R

    /// Direct access to a band's raw sample buffer (if available).
    func withRawBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R
  }

  extension LODSnapshot {
    /// Existing conformers represent live circular storage unless they opt in
    /// to static timeline metadata.
    public var timelineLayout: LODTimelineLayout {
      .liveCircular
    }

    /// Returns `true` when `band` is within `0..<bandCount`.
    public func isValidBand(_ band: Int) -> Bool {
      band >= 0 && band < bandCount
    }

    /// Checked variant of `withContiguousLODChannel`.
    public func withContiguousLODChannelIfValid<R>(
      band: Int,
      channel: LODChannel,
      _ body: (UnsafeBufferPointer<Float>) -> R,
    ) -> R? {
      guard isValidBand(band) else { return nil }
      return unsafe withContiguousLODChannel(band: band, channel: channel, body)
    }

    public func withMinBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe withContiguousLODChannel(band: band, channel: .min, body)
    }

    public func withMaxBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe withContiguousLODChannel(band: band, channel: .max, body)
    }

    public func withRMSBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe withContiguousLODChannel(band: band, channel: .rms, body)
    }

    public func withMinBufferIfValid<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R)
      -> R?
    {
      unsafe withContiguousLODChannelIfValid(band: band, channel: .min, body)
    }

    public func withMaxBufferIfValid<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R)
      -> R?
    {
      unsafe withContiguousLODChannelIfValid(band: band, channel: .max, body)
    }

    public func withRMSBufferIfValid<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R)
      -> R?
    {
      unsafe withContiguousLODChannelIfValid(band: band, channel: .rms, body)
    }

    /// Creates a flat copy for one LOD channel.
    public func copyContiguousLODChannel(_ channel: LODChannel) -> [Float] {
      guard bandCount > 0, lodBufferLength > 0 else { return [] }
      var flat = Array(repeating: Float(0), count: bandCount * lodBufferLength)
      for band in 0..<bandCount {
        let base = band * lodBufferLength
        unsafe withContiguousLODChannel(band: band, channel: channel) { src in
          guard let srcBase = src.baseAddress else { return }
          flat.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            unsafe (dstBase + base).update(
              from: srcBase,
              count: min(src.count, lodBufferLength),
            )
          }
        }
      }
      return flat
    }

    public func withRawBuffer<R>(band _: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      unsafe body(UnsafeBufferPointer(start: nil, count: 0))
    }
  }

  // MARK: - LOD Data Types

  /// LOD (Level-of-Detail) data for a single frequency band.
  ///
  /// Contains min, max, and RMS values computed over LOD windows.
  /// Data is stored in circular buffers for efficient streaming.
  public struct BandLODData: Sendable, Equatable {
    /// Index of this band (0 = lowest frequency).
    public let bandIndex: Int

    /// Minimum amplitude values per LOD window.
    /// Values are in the range [-1.0, 1.0] (linear amplitude).
    public var minBuffer: [Float]

    /// Maximum amplitude values per LOD window.
    /// Values are in the range [-1.0, 1.0] (linear amplitude).
    public var maxBuffer: [Float]

    /// RMS (Root Mean Square) amplitude values per LOD window.
    /// Values are in the range [0.0, 1.0] (linear amplitude).
    public var rmsBuffer: [Float]

    /// Raw sample buffer (optional, for high-zoom visualization).
    public var rawBuffer: [Float]?

    /// Creates a new band LOD data container.
    ///
    /// - Parameters:
    ///   - bandIndex: Index of this band.
    ///   - capacity: Number of LOD samples to allocate.
    public init(bandIndex: Int, capacity: Int) {
      self.bandIndex = max(0, bandIndex)
      minBuffer = Array(repeating: 0, count: max(0, capacity))
      maxBuffer = Array(repeating: 0, count: max(0, capacity))
      rmsBuffer = Array(repeating: 0, count: max(0, capacity))
      rawBuffer = nil
    }
  }

  /// Complete multi-band LOD snapshot ready for GPU rendering.
  ///
  /// Contains all band data plus metadata needed by Metal shaders.
  /// Conforms to `LODSnapshot` for use with `MetalWaveformView`.
  public struct MultiBandLODSnapshot: Sendable, Equatable, SnapshotProvider, LODSnapshot {
    /// LOD data for each frequency band (indexed by band number).
    public let bands: [BandLODData]

    /// Current write position in circular buffers.
    public let writeIndex: Int

    /// LOD reduction ratio used.
    public let lodRatio: Int

    /// Raw buffer length (for shader calculations).
    public let rawBufferLength: Int

    /// Mapping between LOD storage and its source timeline.
    public let timelineLayout: LODTimelineLayout

    /// Number of bands.
    public var bandCount: Int {
      bands.count
    }

    /// LOD buffer length per band.
    public var lodBufferLength: Int {
      bands.first?.minBuffer.count ?? 0
    }

    /// Creates a new multi-band LOD snapshot.
    public init(
      bands: [BandLODData],
      writeIndex: Int,
      lodRatio: Int,
      rawBufferLength: Int,
      timelineLayout: LODTimelineLayout = .liveCircular,
    ) {
      self.bands = bands
      self.writeIndex = writeIndex
      self.lodRatio = lodRatio
      self.rawBufferLength = rawBufferLength
      self.timelineLayout = Self.normalizedTimelineLayout(timelineLayout)
    }

    /// Empty snapshot with no data.
    public static let empty = MultiBandLODSnapshot(
      bands: [],
      writeIndex: 0,
      lodRatio: 128,
      rawBufferLength: 0,
    )

    private static func normalizedTimelineLayout(
      _ timelineLayout: LODTimelineLayout,
    ) -> LODTimelineLayout {
      switch timelineLayout {
      case .liveCircular:
        .liveCircular
      case .staticLinear(let availableRawSampleCount, let totalRawSampleCount):
        .staticLinear(
          availableRawSampleCount: min(
            max(availableRawSampleCount, 0),
            max(totalRawSampleCount, 0),
          ),
          totalRawSampleCount: max(totalRawSampleCount, 0),
        )
      }
    }

    public func toSnapshot() -> MultiBandLODSnapshot? {
      self
    }

    // MARK: - GPU Buffer Helpers

    // MARK: - LODSnapshot Protocol Conformance

    public func withContiguousLODChannel<R>(
      band: Int,
      channel: LODChannel,
      _ body: (UnsafeBufferPointer<Float>) -> R,
    ) -> R {
      precondition(
        (0..<bands.count).contains(band),
        "LODSnapshot band index out of range: \(band), valid range: 0..<\(bands.count)",
      )
      switch channel {
      case .min:
        return bands[band].minBuffer.withUnsafeBufferPointer(body)
      case .max:
        return bands[band].maxBuffer.withUnsafeBufferPointer(body)
      case .rms:
        return bands[band].rmsBuffer.withUnsafeBufferPointer(body)
      }
    }

    /// Direct access to a band's raw buffer.
    public func withRawBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      precondition(
        (0..<bands.count).contains(band),
        "LODSnapshot band index out of range: \(band), valid range: 0..<\(bands.count)",
      )
      if let raw = bands[band].rawBuffer {
        return raw.withUnsafeBufferPointer(body)
      } else {
        return unsafe body(UnsafeBufferPointer(start: nil, count: 0))
      }
    }
  }

#endif
