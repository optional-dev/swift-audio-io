// © GoodHatsLLC

#if canImport(AVFoundation)
  import AudioSignals
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
      for count in [1_024, 1_024, 1_024, 37, 2_111, 7_000, 128] {
        unsafe processor.process([Float](repeating: 0.5, count: count))
        processed += count
        let snapshot = unsafe processor.snapshotRef()
        let publishedCount = (processed / 128 / swapInterval) * swapInterval
        #expect(snapshot.committedLODCount == publishedCount)
        #expect(snapshot.writeIndex == publishedCount % configuration.lodBufferLength)
        #expect(snapshot.rawWriteIndexSnapshot == processed % configuration.rawBufferLength)
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
      #expect(after.rawWriteIndexSnapshot == 1_468)
    }
  }
#endif
