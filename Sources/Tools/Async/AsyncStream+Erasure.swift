// © GoodHatsLLC

public import AsyncAlgorithms
public import Foundation

/// Type erasure of async sequences with a failure type.
///
/// The erased stream owns a forwarding task. Normal upstream completion
/// finishes the erased stream; downstream termination requests cancellation of
/// that forwarding task. The erased layer uses an unbounded buffer so it does
/// not change the upstream sequence's buffering semantics.
extension AsyncThrowingStream where Failure == any Error, Element: Sendable {
  /// Type erasure of a failable async sequence. (iOS 17 compatible)
  ///
  /// - Note: The erased layer uses an unbounded buffer and relies on the
  ///   upstream sequence for producer-side buffer control.
  public init<S: AsyncSequence>(isolation: isolated (any Actor)? = #isolation, _ source: S)
  where S.Element == Element {
    let (stream, cont) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)

    self = stream
    let work = ActorOwnedWork(inheriting: isolation) {
      do {
        for try await element in source {
          cont.yield(element)
        }
        cont.finish()
      } catch {
        cont.yield(with: .failure(error))
      }
    }
    cont.onTermination = { _ in
      work.cancelNow()
    }
  }
}

extension AsyncStream {
  /// Type erasure of non-failing async sequence.
  public init<S: AsyncSequence>(isolation: isolated (any Actor)? = #isolation, _ source: S)
  where S.Element == Element, S.Failure == Never, Element: Sendable {
    let (stream, cont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

    self = stream
    let work = ActorOwnedWork(inheriting: isolation) {
      for await element in source {
        cont.yield(element)
      }
      cont.finish()
    }
    cont.onTermination = { _ in
      work.cancelNow()
    }
  }

  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses an
  /// `AsyncStream.AsyncIterator`. It is a thin wrapper which does not modify the
  /// upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    map transform: @escaping (S.Element) -> Element,
  ) where S.AsyncIterator == AsyncStream<S.Element>.AsyncIterator, Element: Sendable {
    let (stream, cont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

    self = stream
    let work = ActorOwnedWork(inheriting: isolation) {
      for await element in source {
        cont.yield(transform(element))
      }
      cont.finish()
    }
    cont.onTermination = { _ in
      work.cancelNow()
    }
  }

  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses an
  /// `AsyncStream.AsyncIterator`. It is a thin wrapper which does not modify the
  /// upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    compactMap transform: @escaping (S.Element) -> Element?,
  ) where S.AsyncIterator == AsyncStream<S.Element>.AsyncIterator, Element: Sendable {
    let (stream, cont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

    self = stream
    let work = ActorOwnedWork(inheriting: isolation) {
      for await element in source {
        if let element = transform(element) {
          cont.yield(element)
        }
      }
      cont.finish()
    }
    cont.onTermination = { _ in
      work.cancelNow()
    }
  }
}

extension AsyncStream {
  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses a
  /// notification iterator. It is a thin wrapper which does not modify the
  /// upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    map transform: @escaping (S.Element) -> Element,
  ) where S.AsyncIterator == NotificationCenter.Notifications.AsyncIterator, Element: Sendable {
    let (stream, cont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

    self = stream
    let work = ActorOwnedWork(inheriting: isolation) {
      for await element in source {
        let mappedElement = transform(element)
        cont.yield(mappedElement)
      }
      cont.finish()
    }
    cont.onTermination = { _ in
      work.cancelNow()
    }
  }

  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses a
  /// notification iterator. It is a thin wrapper which does not modify the
  /// upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    compactMap transform: @escaping (S.Element) -> Element?,
  ) where S.AsyncIterator == NotificationCenter.Notifications.AsyncIterator, Element: Sendable {
    let (stream, cont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

    self = stream
    let work = ActorOwnedWork(inheriting: isolation) {
      for await element in source {
        if let mappedElement = transform(element) {
          cont.yield(mappedElement)
        }
      }
      cont.finish()
    }
    cont.onTermination = { _ in
      work.cancelNow()
    }
  }
}

public typealias AsyncInitiallyNilSequence<Source: AsyncSequence> = AsyncChain2Sequence<
  AsyncSyncSequence<[Source.Element?]>,
  AsyncMapSequence<Source, Source.Element?>,
>
public typealias AsyncInitiallyNilOptionalSequence<Source: AsyncSequence> = AsyncChain2Sequence<
  AsyncSyncSequence<[Source.Element]>,
  AsyncMapSequence<Source, Source.Element>,
>
public typealias InitiallyNilFiringCombineLatest2<Source1: AsyncSequence, Source2: AsyncSequence> =
  AsyncCombineLatest2Sequence<
    AsyncInitiallyNilSequence<Source1>,
    AsyncInitiallyNilSequence<Source2>,
  >

extension AsyncSequence {
  public func optionalized<Wrapped>(_: Wrapped.Type = Wrapped.self) -> Self
  where Self.Element == Wrapped? {
    self
  }

  @_disfavoredOverload
  public func optionalized() -> AsyncMapSequence<Self, Self.Element?> where Self.Element: Sendable {
    map(Optional.init)
  }

  /// Make the elements of the sequence optional and add a `Optional<Element>.none` prefix.
  ///
  @_disfavoredOverload
  public func withNilPrefix() -> AsyncChain2Sequence<
    AsyncSyncSequence<[Self.Element?]>,
    AsyncMapSequence<
      Self,
      Self.Element?,
    >,
  > where Self.Element: Sendable {
    chain([Self.Element?(nil)].async, map(Optional.init))
  }

  /// Add an `Optional<Element>.none` prefix element to a sequence which already has an optional element type
  public func withNilPrefix<WrappedElement>()
    -> AsyncChain2Sequence<
      AsyncSyncSequence<[Self.Element]>,
      AsyncMapSequence<
        Self,
        Self.Element,
      >,
    > where Self.Element == WrappedElement?
  {
    chain([.none].async, map(\.self))
  }
}
