// swift-tools-version: 6.4

import Foundation
import PackageDescription

func swiftSettings(_ settings: PackageDescription.SwiftSetting...) -> [PackageDescription
  .SwiftSetting]
{
  [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    .defaultIsolation(.none),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  ] + settings
}

let package = Package(
  name: "swift-audio-io",
  platforms: [.iOS(.v27), .macOS(.v27)],
  products: [
    .library(
      name: "Tools",
      targets: ["Tools"],
    ),
    .library(
      name: "AudioSignals",
      targets: ["AudioSignals"],
    ),
    .library(
      name: "AudioIO",
      targets: ["AudioIO"],
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-collections.git",
      from: "1.3.0",
    ),
    .package(
      url: "https://github.com/apple/swift-async-algorithms.git",
      from: "1.1.1",
    ),
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      from: "1.3.0",
    ),
    // Build-time only: provides `swift package generate-documentation` so CI
    // can compile the DocC catalogue in Sources/AudioIO/AudioIO.docc and fail
    // on broken symbol links. Not linked into any product.
    .package(
      url: "https://github.com/apple/swift-docc-plugin.git",
      from: "1.4.0",
    ),
  ],
  targets: [
    .target(
      name: "Tools",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "ToolsTests",
      dependencies: ["Tools"],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AudioSignals",
      dependencies: [
        "Tools",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOContracts",
      dependencies: [],
      swiftSettings: swiftSettings(),
    ),
    // Objective-C is the only language here that can catch an `NSException`.
    // AVFoundation's audio graph raises them for precondition violations, and
    // a raise that unwinds into Swift aborts the process. Wrapped for Swift by
    // `AIOSupport.ObjCException`; nothing else should import this directly.
    .target(
      name: "AIOObjCException",
      dependencies: [],
    ),
    .target(
      name: "AIOSupport",
      dependencies: ["AIOObjCException"],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOAudioSession",
      dependencies: [
        "AIOContracts",
        "AIOSupport",
        "Tools",
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOVisualization",
      dependencies: [
        "AIOContracts",
        "AIOSupport",
        "AudioSignals",
        "Tools",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    // The engine: AIOEngine plus the recording and playback lifecycles that
    // implement its surface. These were three targets split by file rather
    // than by type — AIOEngine lived here while the behaviour over its state
    // lived in AIORecording, which depended on this module, so the state types
    // had to be exiled to a third target (AIORecordingSupport) purely to break
    // the resulting cycle. Merging lets each lifecycle own its own state.
    .target(
      name: "AIOEngineCore",
      dependencies: [
        "AIOAudioSession",
        "AIOContracts",
        "AIOSupport",
        "Tools",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOMicHealth",
      dependencies: [
        "AIOAudioSession",
        "Tools",
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AudioIO",
      dependencies: [
        "AIOAudioSession",
        "AIOContracts",
        "AIOEngineCore",
        "AIOMicHealth",
        "AIOSupport",
        "AIOVisualization",
        "Tools",
        "AudioSignals",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      // Do NOT add `exclude: ["AudioIO.docc"]` to silence SwiftPM's
      // "found 1 file(s) which are unhandled" warning for the catalogue.
      // Excluding it removes the catalogue from the target's source list, so
      // swift-docc-plugin stops finding it: `generate-documentation` still
      // succeeds, but every article is dropped and the landing page falls
      // back to auto-generated symbol groups. The warning is cosmetic; the
      // silent doc loss is not.
      swiftSettings: swiftSettings(),
    ),
    // Fakes and helpers shared by the test targets. Deliberately not listed in
    // `products`, so it is never vended to consumers of this package.
    .target(
      name: "AIOTestSupport",
      dependencies: [
        "AIOAudioSession",
        "AIOContracts",
        "AIOEngineCore",
        "AudioIO",
        "Tools",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AIOTests",
      dependencies: [
        "AIOAudioSession",
        "AIOSupport",
        "AIOTestSupport",
        "AudioIO",
      ],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AIOPlatformIntegrationTests",
      dependencies: ["AIOTestSupport", "AudioIO", "Tools"],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AudioVisualizationTests",
      dependencies: ["AudioIO", "AudioSignals"],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AIOMicHealthTests",
      dependencies: ["AIOAudioSession", "AIOMicHealth"],
      swiftSettings: swiftSettings(),
    ),
  ],
)
