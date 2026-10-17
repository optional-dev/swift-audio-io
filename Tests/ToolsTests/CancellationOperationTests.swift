// © GoodHatsLLC

import Testing

@testable import Tools

struct CancellationOperationTests {
  @Test(arguments: [true, false])
  func cleanupFinishesBeforeReturningToCancelledCaller(cancelBeforeWaiting: Bool) async {
    let entered = AsyncContinuation<Void>()
    let work = Task {
      if cancelBeforeWaiting { unsafe withUnsafeCurrentTask { unsafe $0?.cancel() } }
      try? entered.yield()
      let cleaned = await withCancellationOperation {
        await withTaskGroup(of: Bool.self) { group in
          group.addTask {
            do {
              try await Task.sleep(for: .milliseconds(10))
              return !Task.isCancelled
            } catch {
              return false
            }
          }
          return await group.next() ?? false
        }
      }
      #expect(Task.isCancelled)
      return cleaned
    }
    await entered()
    if !cancelBeforeWaiting { work.cancel() }
    #expect(await work.value)
  }

  @Test
  func throwingCleanupPreservesItsTypedFailure() async {
    let work = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      do throws(CleanupFailure) {
        try await withCancellationOperation { () async throws(CleanupFailure) -> Void in
          #expect(!Task.isCancelled)
          throw .expected
        }
        Issue.record("cleanup should throw")
      } catch {
        #expect(error == .expected)
      }
      #expect(Task.isCancelled)
    }
    await work.value
  }

  @Test
  func cancellationAwaitOverloadsShieldCleanup() async {
    let work = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      let result: CancellationAwaitResult<Bool> = await awaitCancellation {
        !Task.isCancelled
      }
      switch result {
      case .cancelled(let cleaned): #expect(cleaned)
      }
      var cleaned = false
      do {
        try await awaitCancellation {
          cleaned = !Task.isCancelled
        }
        Issue.record("Void overload should throw CancellationError after cleanup")
      } catch {
        #expect(cleaned)
      }
      #expect(Task.isCancelled)
    }
    await work.value
  }
}

private enum CleanupFailure: AudioError {
  case expected
  var description: String { "expected cleanup failure" }
}
