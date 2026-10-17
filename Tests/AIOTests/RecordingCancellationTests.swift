// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOContracts
  import AIOAudioSession
  import Atomics
  import AIOTestSupport
  import AVFoundation
  import Foundation
  import Testing
  import Tools
  @testable import AIOEngineCore
  @testable import AudioIO

  @Suite(.serialized)
  struct RecordingCancellationTests {
    @MainActor
    @Test
    func `cancelled startup releases its claim before deactivating`() async {
      let authority = CancellationCheckingAuthority()
      let entered = AsyncContinuation<Void>()
      let finishAttempt = AsyncContinuation<Void>()
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-start.caf")
      let engine = AIOEngine(
        audioSessionAuthority: authority,
        recordingEnvironment: RecordingEnvironment(attemptRecordingStart: { _ in
          try? entered.yield()
          await finishAttempt()
          return url
        }),
      )
      let start = Task {
        try await engine.startRecording(
          configuration: RecordingConfiguration(
            inputConfiguration: InputConfiguration(sampleRate: .dvd, channels: .mono),
            outputConfiguration: OutputConfiguration(
              fileFormat: .caf, bitDepth: .pcmFloat32, quality: .high,
            ),
          ))
      }
      await entered()
      start.cancel()
      try? finishAttempt.yield()
      do {
        _ = try await start.value
        Issue.record("start must preserve cancellation")
      } catch {
        #expect(error as? RecordingError == .cancelled)
      }
      #expect(engine.recordingLifecycleState.startOperationID == nil)
      #expect(authority.deactivations == 1)
    }

    @MainActor
    @Test
    func `cancelled playback stop releases its session`() async {
      let authority = CancellationCheckingAuthority()
      let engine = AIOEngine(audioSessionAuthority: authority)
      let stop = Task { @MainActor in
        unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
        await engine.stopPlayback()
        #expect(Task.isCancelled)
      }
      await stop.value
      #expect(authority.deactivations == 1)
      #expect(!engine.isPlayback)
    }

    @MainActor
    @Test
    func `cancelled stop still times out a writer that never drains`() async {
      let authority = CancellationCheckingAuthority()
      let (engine, _, _) = AIOEngine.fakeRecording(audioSessionAuthority: authority)
      let control = WriterControl()
      let writer = DrainCheckingWriter()
      engine.recordingLifecycleState.writerSession = WriterSession(
        id: UUID(), control: control, writer: writer, fileURL: writer.fileURL,
        startFramePosition: 0,
      )
      engine.recordingSampleTimeAtomic.store(128, ordering: .relaxed)
      engine.isRecording = true
      let started = ContinuousClock.now
      let stop = Task { @MainActor in
        unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
        await engine.recording.gracefulStop()
      }
      await stop.value
      let elapsed = started.duration(to: .now)
      #expect(elapsed >= engine.writerDrainTimeout)
      #expect(elapsed < engine.stopDrainTimeout + .seconds(2))
      #expect(engine.recordingLifecycleState.lastWriteFailure != nil)
      #expect(engine.recordingLifecycleState.writerSession == nil)
      #expect(authority.deactivations == 1)
      #expect(!engine.isRecording)
    }

    @MainActor
    @Test
    func `cancelled session hold release finishes once`() async {
      var releases = 0
      let hold = AudioSessionHold {
        do {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(10))
          releases += 1
        } catch {
          Issue.record("session release observed caller cancellation")
        }
      }
      let release = Task { @MainActor in
        unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
        await hold.release()
        await hold.release()
        #expect(Task.isCancelled)
      }
      await release.value
      #expect(releases == 1)
      #expect(!hold.isHeld)
    }

    @MainActor
    @Test(arguments: [true, false])
    func `cancelled stop waits for writer drain and releases the session`(
      cancelBeforeStop: Bool
    ) async throws {
      let authority = CancellationCheckingAuthority()
      let (engine, backend, _) = AIOEngine.fakeRecording(audioSessionAuthority: authority)
      let control = WriterControl()
      let writer = DrainCheckingWriter()
      let session = WriterSession(
        id: UUID(), control: control, writer: writer, fileURL: writer.fileURL,
        startFramePosition: 0,
      )
      // A pending writer with frames left to drain, without a hardware graph.
      engine.recordingLifecycleState.writerSession = session
      engine.recordingSampleTimeAtomic.store(128, ordering: .relaxed)
      engine.state.withLock {
        $0.recordingWriter = writer
        $0.captureBackend = backend
      }
      engine.isRecording = true
      var completed = false
      let stop = Task { @MainActor in
        if cancelBeforeStop { unsafe withUnsafeCurrentTask { unsafe $0?.cancel() } }
        await engine.recording.gracefulStop()
        completed = true
        return Task.isCancelled
      }
      defer {
        await control.drainSignal.signal()
        _ = await stop.value
      }

      let deadline = ContinuousClock.now.advanced(by: .seconds(1))
      while !control.stopRequested.load(ordering: .relaxed), !completed,
        ContinuousClock.now < deadline
      {
        await Task.yield()
      }
      let stopRequested = control.stopRequested.load(ordering: .relaxed)
      #expect(stopRequested)
      #expect(!completed, "stop must wait for the writer's completion")
      if !cancelBeforeStop { stop.cancel() }

      // Leave cancellation a scheduling opportunity before acknowledging drain.
      for _ in 0..<20 { await Task.yield() }
      #expect(!completed, "cancellation must not finish a pending drain")
      writer.didDrain.withLock { $0 = true }
      await control.drainSignal.signal()
      let remainedCancelled = await stop.value

      #expect(remainedCancelled)
      #expect(!writer.closedBeforeDrain.withLock { $0 })
      #expect(authority.deactivations == 1)
      #expect(!engine.isRecording)
      #expect(engine.recordingLifecycleState.writerSession == nil)
      #expect(backend.cleanupCalls == 1)
      #expect(engine.recordingLifecycleState.lastWriteFailure == nil)
    }
  }

  private final class DrainCheckingWriter: RecordingFileWriter {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cancelled-drain-\(UUID()).caf")
    let didDrain = Synchronized(false)
    let closedBeforeDrain = Synchronized(false)

    func write(_: AVAudioPCMBuffer) {}

    func close() {
      if !didDrain.withLock({ $0 }) {
        closedBeforeDrain.withLock { $0 = true }
      }
    }
  }

  @MainActor
  private final class CancellationCheckingAuthority: AudioSessionAuthority {
    var deactivations = 0

    func setAudioSessionActive(_ active: Bool) async throws {
      try Task.checkCancellation()
      if !active { deactivations += 1 }
    }
  }
#endif
