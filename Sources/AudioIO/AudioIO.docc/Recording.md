# Recording

Configure inputs and outputs, drive the engine, and observe lifecycle events.

## Configuration

Recording is configured by ``RecordingConfiguration``: a capture source, an
output encoding, and a destination.

### Capture sources

``RecordingConfiguration/input`` is a ``RecordingInput`` — the capture source and
its source-specific options:

- ``MicrophoneRecordingInput`` — the `AVAudioEngine` input tap (iOS and macOS).
  Owns the `tapInterval`.
- `SystemAudioRecordingInput` — a macOS Core Audio process tap that records what
  other apps are playing. See <doc:SystemAudioCapture>.

Each input carries a ``CaptureFormat`` — a ``RecordingSampleRate`` intent plus
a ``ChannelCount`` — which you read source-agnostically via
``RecordingConfiguration/requestedFormat``. ``RecordingSampleRate/hardware``
records at whatever rate the route actually runs (no resampling);
``RecordingSampleRate/exact(_:)`` names a rate the file always gets, by
conversion when the route differs. See <doc:SampleRates> for the whole story,
including the ``ResolvedCaptureFormat`` provenance reported at start. For
microphone recording with an exact rate you can use the convenience
initializer
``RecordingConfiguration/init(inputConfiguration:outputConfiguration:tapInterval:outputDestination:)``,
which builds a ``MicrophoneRecordingInput`` for you.

### Output

- ``OutputConfiguration`` chooses the ``FileFormat``, ``BitDepth``, and ``EncodingQuality``.
- `outputDestination` selects a temporary file, a directory, or an explicit file URL.

Bit depth and encoding quality are not universal. Each format reports which of
them reaches its writer, and a value the writer ignores is rejected rather than
silently accepted:

| Format | ``FileFormat/usesBitDepth`` | ``FileFormat/usesEncodingQuality`` |
|---|---|---|
| WAV, CAF, AIFF | yes — the written sample width | no |
| FLAC | yes — `AVEncoderBitDepthHintKey` | no |
| AAC (`m4a`), ADTS | **no** — pass `nil` | yes |

AAC is a lossy transform codec with no PCM sample width to choose, so
``OutputConfiguration/bitDepth`` must be `nil` for it. ``EncodingQuality`` is an
`AVAudioQuality` *level*, not a bitrate — AudioIO does not set
`AVEncoderBitRateKey`, so the encoder picks whatever bitrate serves the level.

### Validating a configuration

The capture format and the output encoding are chosen through independent APIs,
so a combination that is reasonable on each side can still be impossible — a
96 kHz microphone request written to `m4a`, for instance, since AAC tops out at
48 kHz. ``RecordingConfiguration/validate()`` decides this without touching an
audio session, so a caller can reject or grey out the combination before
activation rather than at the writer:

```swift
let validation = configuration.validate()
guard validation.isValid else {
  // Each issue describes exactly what cannot be written.
  throw MyError.badConfiguration(validation.description)
}
```

``OutputConfigurationManager`` exposes the same check against a capture format
with `validate(against:)`, plus `availableOutputFormats(for:)` for building a
picker that only offers writable combinations. This matters because the output
selection is remembered per input device while the requested input sample rate
is a single global intent, so the two can drift apart across a route change.

The engine enforces the declared channel matrix:

| Source / format | Max channels |
|---|---|
| AAC, ADTS | 8 (AAC channel layouts) |
| FLAC | 8 |
| WAV, CAF, AIFF | 32 (PCM) |
| System audio (any format) | 2 (mono / stereo mixdown) |

Unsupported channel counts fail with ``RecordingError/unsupportedChannelCount(requested:maximum:)`` before the engine installs a recording tap.

## Driving the engine

The canonical entry point is single-shot and typed-throws:

```swift
let url = try await engine.startRecording(configuration: configuration)
// …record for some duration…
let savedURL = try await engine.stopRecording().completedURL
```

Stopping drains the writer and releases audio-session demand even when the calling
task is cancelled. The drain timeout remains active. Await the stop before
reusing or discarding the engine.

``AIOEngine/startRecording(configuration:)`` returns the destination URL once
the engine is producing output. It performs bounded retry for transient
audio-session and capture-source readiness failures. The deadline defaults to
two seconds and can be configured when creating the engine:

```swift
let engine = AIOEngine(recordingStartTimeout: .seconds(5))
```

Cancel the task awaiting `startRecording` to withdraw startup intent. A second
start while one is pending throws ``RecordingError/startInProgress``; a start
while capture is active throws ``RecordingError/alreadyRecording``.
``AIOEngine/stopRecording()`` returns a ``RecordingCompletion`` carrying the
final saved URL.

## Segmented recording

``AIOEngine/rotateRecordingFile()`` closes the current file and continues capture into a new file without reinstalling the tap. The closed file appears in the events stream as a `.recordingStarted(url:, format:)` for the *new* URL. Capture is never interrupted, and nothing about the capture path changes at a rotation: the tap keeps writing into the same buffers, and only the writer draining them is replaced. The completed writer stops at exactly the reported boundary, leaving the frames past it for the writer that takes over, so no frame is dropped or written twice. That drain finishes in the background — the rotation does not wait for it — so a just-completed file may still be growing for a moment after the call returns.

Rotation reports where the split happened, which is what lets a consumer treat
the files as one recording:

```swift
var boundaries: [Int64] = []

let rotation = try await engine.rotateRecordingFile()
boundaries.append(rotation.boundaryFramePosition)   // where `rotation.completedURL` ends

let completion = try await engine.stopRecording()
boundaries.append(completion.boundaryFramePosition) // total frames of the capture
```

``RecordingRotation/boundaryFramePosition`` is the cumulative persisted-frame
position at which the completed file ends and the next one begins, measured
from the start of the capture. Consecutive rotations produce a strictly
increasing sequence, so each file's frame length is the difference between
adjacent boundaries, and the sequence closes on
``RecordingCompletion/boundaryFramePosition`` — the capture's total.

The value is sampled where the split is decided, so it already accounts for
frames still queued for the completed file. Do not try to reconstruct it from
``AIOEngine/recordingTimingSnapshot()``: that counter is cumulative for the
whole capture, is not reset by a rotation, and races the capture callback while
recording is active.

Whether a boundary difference equals the file's *decoded* frame count depends
on the format. ``FileFormat/preservesExactFrameCount`` reports it: the PCM
containers and FLAC are frame-exact, while AAC adds encoder priming and pads
the tail. ``FileFormat/toleratesTruncation`` reports the companion fact — for
crash-safety rotation, the interesting formats are the ones where a file cut
off mid-write is *not* readable.

## Observing lifecycle

Subscribe to ``AIOEngine/events`` for every recording lifecycle transition:

| Event | When |
|---|---|
| ``AudioIOEvent/recordingStarted(url:format:capture:)`` | Initial start or segment rotation; carries the ``ResolvedCaptureFormat`` provenance. |
| ``AudioIOEvent/recordingCompleted`` | User-initiated stop completed cleanly. |
| ``AudioIOEvent/recordingFailed`` | Engine-side failure stopped recording. |
| ``AudioIOEvent/recordingInterruption(_:)`` | Route change continuation, or an interruption-driven stop. |
| ``AudioIOEvent/error(_:)`` | Tap-thread or drain failure surfaced asynchronously. |

See <doc:Events> for the full subscription pattern.

## Topics

### Configuration

- ``RecordingConfiguration``
- ``RecordingInput``
- ``MicrophoneRecordingInput``
- ``CaptureFormat``
- ``RecordingSampleRate``
- ``ResolvedCaptureFormat``
- ``InputConfiguration``
- ``OutputConfiguration``
- ``SampleRate``
- ``ChannelCount``
- <doc:SampleRates>
- ``FileFormat``
- ``BitDepth``
- ``EncodingQuality``
- ``RecordingConfiguration/validate()``
- ``CaptureConfigurationValidation``
- ``CaptureConfigurationIssue``

### System audio (macOS)

- <doc:SystemAudioCapture>
- ``SystemAudioRecordingInput``
- ``SystemAudioProcessSelection``
- ``SystemAudioProcessCatalog``
- ``SystemAudioProcess``
- ``SystemAudioProcessObjectID``

### Engine surface

- ``AIOEngine/startRecording(configuration:)``
- ``AIOEngine/stopRecording()``
- ``AIOEngine/rotateRecordingFile()``
- ``AIOEngine/isRecording``

### Segment boundaries

- ``RecordingRotation``
- ``RecordingCompletion``
- ``FileFormat/preservesExactFrameCount``
- ``FileFormat/toleratesTruncation``

### Errors

- ``RecordingError``
- <doc:ErrorHandling>
