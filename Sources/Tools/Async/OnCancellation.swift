// © GoodHatsLLC

import Synchronization

public enum CancellationAwaitResult<T> {
  case cancelled(T)
}

/// Waits for cancellation, then awaits a shielded cleanup action.
public func awaitCancellation<T>(
  isolation _: (any Actor)? = #isolation,
  then action: () async -> T,
) async -> CancellationAwaitResult<T> {
  let mutex: Mutex<CheckedContinuation<Void, Never>?> = .init(nil)
  await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      mutex.withLock {
        if Task.isCancelled {
          continuation.resume()
          return
        }
        $0 = continuation
      }
    }
  } onCancel: {
    let continuation = mutex.withLock { $0.take() }
    continuation?.resume()
  }
  return await .cancelled(withTaskCancellationShield { await action() })
}

/// Waits for cancellation, awaits shielded cleanup, then throws cancellation.
public func awaitCancellation(
  isolation _: (any Actor)? = #isolation,
  then action: () async -> Void,
) async throws(CancellationError) {
  let mutex: Mutex<CheckedContinuation<Void, Never>?> = .init(nil)

  await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      mutex.withLock {
        if Task.isCancelled {
          continuation.resume()
        } else {
          $0 = continuation
        }
      }
    }
  } onCancel: {
    mutex.withLock { $0.take() }?.resume()
  }

  await withTaskCancellationShield { await action() }
  throw CancellationError()
}

public func withCancellationSideEffect<T>(
  isolation _: (any Actor)? = #isolation,
  _ operation: () async throws -> T,
  onCancel action: @Sendable () -> Void,
) async rethrows -> T {
  try await withTaskCancellationHandler {
    try await operation()
  } onCancel: {
    action()
  }
}
