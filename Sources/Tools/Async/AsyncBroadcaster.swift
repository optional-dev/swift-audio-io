// © GoodHatsLLC

import Foundation
import OrderedCollections
import Synchronization
import os

public final class AsyncBroadcaster<Element: Sendable>: AsyncSequence, Sendable {
  public typealias Element = Element

  public init<S: AsyncSequence>(
    replay: AsyncBuffer,
    subscriberBuffer: AsyncBuffer = .unbounded,
    sequence: sending S,
  )
  where S.Element == Element {
    let controller = MulticastController<Element>(
      sequence.map(MulticastController.Event.publish), replay: replay,
    )
    self.controller = controller
    memory = replay
    self.subscriberBuffer = subscriberBuffer
  }

  let controller: MulticastController<Element>
  let memory: AsyncBuffer
  let subscriberBuffer: AsyncBuffer

  public func makeAsyncIterator() -> Iterator {
    Iterator(underlying: subscribe().events.makeAsyncIterator())
  }

  /// A synchronously registered subscriber with explicit cancellation.
  public struct Subscription: Sendable {
    fileprivate let controller: MulticastController<Element>
    fileprivate let id: UUID
    public let events: AsyncSignalStream<Element>

    /// Unregisters this subscriber and finishes its event stream.
    public func cancel() {
      controller.handle(.unsubscribe(id: id))
    }
  }

  /// Registers a subscriber before returning it.
  ///
  /// Use this when an owned consumer starts asynchronously but events emitted
  /// immediately after setup must not be lost while that consumer is waiting
  /// to be scheduled. The owner must call `cancel()` during teardown.
  public func subscribe() -> Subscription {
    let underlying = AsyncSignalStream<Element>
      .makeStream(
        of: Element.self,
        bufferingPolicy: .init(subscriberBuffer),
      )
    let id = UUID()
    controller.handle(.subscribe(id: id, underlying.continuation))
    return Subscription(controller: controller, id: id, events: underlying.stream)
  }

  public struct Iterator: AsyncIteratorProtocol {
    init(underlying: AsyncSignalStream<Element>.Iterator) {
      self.underlying = underlying
    }

    private var underlying: AsyncSignalStream<Element>.Iterator

    public mutating func next(isolation: isolated (any Actor)?) async
      -> Element?
    {
      await underlying.next(isolation: isolation)
    }
  }
}

extension AsyncSequence where Self: Sendable, Self.Element: Sendable {
  public func broadcast(
    replay: AsyncBuffer = .none,
    subscriberBuffer: AsyncBuffer = .unbounded,
  ) -> AsyncBroadcaster<Element> {
    AsyncBroadcaster(replay: replay, subscriberBuffer: subscriberBuffer, sequence: self)
  }
}

final class MulticastController<Element: Sendable>: Sendable {
  enum Event {
    case subscribe(id: UUID, _ continuation: AsyncSignalContinuation<Element>)
    case unsubscribe(id: UUID)
    case publish(Element)
    case finish
  }

  init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation, _ sequence: S, replay: AsyncBuffer,
  ) where S.Element == Event {
    let state = StateBox(
      .available(.init(replayCapacity: replay, replay: [], continuations: [:])),
    )
    self.state = state
    upstreamWork = ActorOwnedWork(priority: .high, inheriting: isolation) {
      _ = isolation
      do {
        for try await event in sequence {
          Self.handle(event, state: state)
        }
        Self.handle(.finish, state: state)
      } catch {
        Self.handle(.finish, state: state)
      }
    }
  }

  private let state: StateBox
  private let upstreamWork: ActorOwnedWork<Void>

  deinit {
    upstreamWork.cancelNow()
    Self.handle(.finish, state: state)
  }

  func handle(_ event: Event) {
    Self.handle(event, state: state)
  }

  private static func handle(_ event: Event, state stateBox: StateBox) {
    let action: @Sendable () -> Void = stateBox.value.withLock { state in
      switch event {
      case .finish:
        state.finish()
        return {}
      case .subscribe(let id, let continuation):
        switch state {
        case .available(var storage):
          storage.continuations[id] = continuation
          state = .available(storage)
          storage.recite(to: continuation)
          return {
            continuation.onTermination = { c in
              switch c {
              case .finished:
                break
              case .cancelled:
                Self.handle(.unsubscribe(id: id), state: stateBox)
              @unknown default:
                break
              }
            }
          }
        case .finished(let elements):
          for element in elements {
            continuation.yield(element)
          }
          continuation.finish()
          return {}
        }
      case .unsubscribe(let id):
        switch state {
        case .available(var storage):
          storage.finish(id: id)
          state = .available(storage)
        case .finished:
          break
        }
        return {}
      case .publish(let element):
        switch state {
        case .available(var storage):
          storage.remember(element)
          state = .available(storage)
          for (_, continuation) in storage.continuations {
            continuation.yield(element)
          }
        default: break
        }
        return {}
      }
    }
    action()
  }

  private final class StateBox: Sendable {
    init(_ state: State) {
      value = .init(state)
    }

    let value: Mut<State>
  }
}

extension MulticastController {
  enum State {
    struct InvalidTransition: AudioError {
      var description: String {
        "Invalid transition"
      }
    }

    case available(Storage)
    case finished([Element])

    mutating func finish() {
      switch self {
      case .finished:
        return
      case .available(var storage):
        let replay = storage.replay
        storage.finishAll()
        self = .finished(replay)
      }
    }
  }
}

extension MulticastController {
  struct Storage {
    let replayCapacity: AsyncBuffer
    var replay: [Element] = []
    var continuations: OrderedDictionary<UUID, AsyncSignalContinuation<Element>> = [:]
    mutating func finish(id: UUID) {
      if let continuation = continuations[id] {
        continuations[id] = nil
        continuation.finish()
      }
    }

    mutating func finishAll() {
      let continuations = continuations
      self.continuations.removeAll()
      for (_, continuation) in continuations {
        continuation.finish()
      }
    }

    mutating func remember(_ element: Element) {
      replay.append(element)
      replayCapacity.prune(elements: &replay)
    }

    func recite(to continuation: AsyncSignalContinuation<Element>) {
      for element in replay {
        continuation.yield(element)
      }
    }
  }
}

public enum AsyncBuffer: Sendable {
  case none
  case latest(Int)
  case unbounded

  public func prune(elements: inout [some Any]) {
    switch self {
    case .none:
      elements.removeAll()
    case .latest(let count):
      elements = elements.suffix(count)
    case .unbounded:
      break
    }
  }
}

extension AsyncStream.Continuation.BufferingPolicy {
  init(_ asyncBuffer: AsyncBuffer) {
    switch asyncBuffer {
    case .none:
      self = .bufferingNewest(0)
    case .latest(let count):
      self = .bufferingNewest(count)
    case .unbounded:
      self = .unbounded
    }
  }
}
