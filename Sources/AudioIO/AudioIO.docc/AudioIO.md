# ``AudioIO``

A Swift audio I/O package for recording, playback, audio-session coordination, and real-time visualization on iOS and macOS.

## Overview

AudioIO ships three SwiftPM library products:

- **`AudioIO`** — the public umbrella. Recording, playback, audio-session management, real-time visualization, and the unified events stream. Import this for almost everything.
- **`AudioSignals`** — pure signal-domain types and offline LOD extraction. Use standalone if you want waveform-data shapes without the recording/playback stack.
- **`Tools`** — utility primitives (`AsyncBroadcaster`, `Subject`, `SPSCRingBuffer`) intentionally surfaced because they appear in AudioIO's public contracts.

Recording, playback, visualization, and the audio-session surface are all driven through a single ``AIOEngine`` instance, with notifications flowing through one unified ``AIOEngine/events`` stream.

## Requirements and stability

AudioIO 1.0 requires Swift 6.4, Xcode 27, and iOS 27 or macOS 27. Public APIs follow SemVer: breaking API changes or a higher platform floor require a major release.

## Topics

### Start here

- <doc:GettingStarted>

### Concept topics

- <doc:PlatformMatrix>
- <doc:ThreadingModel>
- <doc:ErrorHandling>
- <doc:Events>

### API surfaces

- <doc:Recording>
- <doc:SampleRates>
- <doc:SystemAudioCapture>
- <doc:Playback>
- <doc:AudioSession>
- <doc:Visualization>

### The engine

- ``AIOEngine``
- ``AudioVisualizationEngine``
- ``AudioEnvironmentManager``

### The events stream

- ``AudioIOEvent``

### Error types

- ``AudioIOError``
- ``RecordingError``
- ``PlaybackError``
- ``SessionError``
