// © GoodHatsLLC

#if canImport(AVFoundation)
  import AudioSignals
  import Foundation
  import Testing

  struct LODPublicationTimelineTests {
    @Test(arguments: [1, 6, 11])
    func `published timeline follows LOD commits across taps and ring wraps`(swapInterval: Int) {
      let configuration = MultiBandLODConfiguration(
        bandCount: 1, lodRatio: 128, bufferSeconds: 1, sampleRate: 48_000,
        snapshotSwapInterval: swapInterval, rawBufferLengthOverride: 2_050,
      )
      let processor = unsafe MultiBandLODProcessor(configuration: configuration)
      var processed = 0
      var publishedCount = 0
      var publishedRawIndex = 0
      for count in [1_024, 1_024, 1_024, 37, 2_111, 7_000, 128] {
        unsafe processor.process([Float](repeating: 0.5, count: count))
        processed += count
        let snapshot = unsafe processor.snapshotRef()
        if processed / 128 - publishedCount >= swapInterval {
          publishedCount = processed / 128
          publishedRawIndex = processed % configuration.rawBufferLength
        }
        #expect(snapshot.committedLODCount == publishedCount)
        #expect(snapshot.writeIndex == publishedCount % configuration.lodBufferLength)
        #expect(snapshot.rawWriteIndexSnapshot == publishedRawIndex)
        let values = snapshot.copyContiguousLODChannel(.max)
        #expect(
          values.prefix(min(publishedCount, configuration.lodBufferLength)).allSatisfy { $0 == 0.5 }
        )
      }
      unsafe processor.reset()
      #expect(unsafe processor.snapshotRef().committedLODCount == 0)
      unsafe processor.process([Float](repeating: 0.25, count: 128 * swapInterval))
      #expect(unsafe processor.snapshotRef().committedLODCount == swapInterval)
    }

    @Test
    func `unpublished raw progress leaves the LOD timeline unchanged`() {
      let processor = unsafe MultiBandLODProcessor(
        configuration: MultiBandLODConfiguration(
          bandCount: 1, lodRatio: 128, bufferSeconds: 1, sampleRate: 48_000,
          snapshotSwapInterval: 6,
        ))
      unsafe processor.process([Float](repeating: 0.5, count: 768))
      let before = unsafe processor.snapshotRef().committedLODCount
      unsafe processor.process([Float](repeating: 0, count: 700))
      let after = unsafe processor.snapshotRef()
      #expect(before == 6)
      #expect(after.committedLODCount == before)
      #expect(after.rawWriteIndexSnapshot == 768)
    }

    @Test(arguments: [16, 64, 375])
    func `burst publication matches a single write slot across wraps`(ringLength: Int) {
      func configuration(interval: Int) -> MultiBandLODConfiguration {
        MultiBandLODConfiguration(
          bandCount: 5, lodRatio: 128, bufferSeconds: 1,
          sampleRate: 48_000, snapshotSwapInterval: interval,
          rawBufferLengthOverride: ringLength * 128)
      }
      let processor = unsafe MultiBandLODProcessor(configuration: configuration(interval: 6))
      let reference = unsafe MultiBandLODProcessor(configuration: configuration(interval: Int.max))
      var processed = 0
      var lastPublishedCount = 0
      var generation: UInt64 = 0
      for count in Array(repeating: [4_800, 512, 512], count: 20).flatMap({ $0 }) {
        let samples = (processed..<(processed + count)).map { Float(sin(Double($0) * 0.071)) }
        unsafe processor.process(samples)
        unsafe reference.process(samples)
        processed += count
        let snapshot = unsafe processor.snapshotRef()
        if processed / 128 - lastPublishedCount >= 6 {
          generation += 1
          lastPublishedCount = processed / 128
          let expected = unsafe reference.snapshotLocking()
          #expect(snapshot.writeIndex == expected.writeIndex)
          for channel in [LODChannel.min, .max, .rms] {
            #expect(
              snapshot.copyContiguousLODChannel(channel)
                == expected.copyContiguousLODChannel(channel))
          }
        }
        #expect(snapshot.publicationGeneration == generation)
        #expect(snapshot.committedLODCount == lastPublishedCount)
        #expect(snapshot.isStillPublished)
      }
    }

    @Test
    func `ref survives one burst and expires before second reuse with immutable metadata`() {
      let processor = unsafe MultiBandLODProcessor(
        configuration: .init(rawBufferLengthOverride: 2_048))
      unsafe processor.process([Float](repeating: 0.25, count: 4_800))
      let ref = unsafe processor.snapshotRef()
      let index = ref.writeIndex
      let count = ref.committedLODCount
      let rawIndex = ref.rawWriteIndexSnapshot
      let values = ref.copyContiguousLODChannel(.max)
      unsafe processor.process([Float](repeating: 0.5, count: 4_800))
      #expect(ref.isStillPublished)
      #expect(ref.copyContiguousLODChannel(.max) == values)
      unsafe processor.process([Float](repeating: 0.75, count: 4_800))
      #expect(!ref.isStillPublished)
      #expect(ref.toSnapshot() == nil)
      #expect(ref.writeIndex == index)
      #expect(ref.committedLODCount == count)
      #expect(ref.rawWriteIndexSnapshot == rawIndex)
    }

    @Test(arguments: [128, 129, 768, 769])
    func `finalize publishes full and partial pending windows`(count: Int) {
      let processor = unsafe MultiBandLODProcessor(configuration: .init(bandCount: 1))
      unsafe processor.process([Float](repeating: 0.5, count: count))
      unsafe processor.finalize()
      let ref = unsafe processor.snapshotRef()
      #expect(ref.committedLODCount == (count + 127) / 128)
      #expect(unsafe processor.snapshot().writeIndex == ref.writeIndex)
      let generation = ref.publicationGeneration
      unsafe processor.finalize()
      #expect(unsafe processor.snapshotRef().publicationGeneration == generation)
    }
  }
#endif
