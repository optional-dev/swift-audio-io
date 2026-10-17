// © GoodHatsLLC

/// Suspend until cancellation, then await the operation with cancellation shielded.
public func withCancellationOperation<T: Sendable>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async -> T,
) async -> T {
  let didCancel = AwaitableBox<Void>()
  return await withTaskCancellationHandler(
    operation: {
      _ = await didCancel()
      return await withTaskCancellationShield { await operation() }
    },
    onCancel: {
      try? didCancel.yield(())
    },
    isolation: isolation,
  )
}

/// Suspend until cancellation, then await the operation with cancellation shielded.
public func withCancellationOperation<T: Sendable, Failure: AudioError>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws(Failure) -> T,
) async throws(Failure) -> T {
  let didCancel = AwaitableBox<Void>()
  do {
    return try await withTaskCancellationHandler(
      operation: {
        _ = await didCancel()
        return try await withTaskCancellationShield { try await operation() }
      },
      onCancel: {
        try? didCancel.yield(())
      },
      isolation: isolation,
    )
  } catch let error as Failure {
    throw error
  } catch {
    preconditionFailure("Unexpected error type: \(error)")
  }
}

/// Backward-compatible name for the shared exactly-once async value primitive.
public typealias AwaitableBox<Value: Sendable> = AsyncContinuation<Value>
