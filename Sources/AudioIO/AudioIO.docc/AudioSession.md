# Audio Session

``AudioEnvironmentManager`` coordinates audio-session activation, requested
and applied input configuration, route changes, and interruption handling. The
engine consumes this surface through narrow contracts so feature code never
has to reach for `AVAudioSession` directly.

## What it owns

On iOS, ``AudioEnvironmentManager`` wraps `AVAudioSession` activation,
category/mode configuration, available-input enumeration, and the route-change
/ interruption / media-services notification surface. On macOS, the same type
provides a tap-reinstall-driven equivalent for route changes (macOS has no
`AVAudioSession`-style interruption notifications).

## Requested, applied, and settled input

``AudioInputConfigurationState/requested`` is durable user intent. It is
updated immediately even when the environment is inactive or the requested
device is absent. ``AudioInputConfigurationState/applied`` is separate: it is
an exact active-route readback and is `nil` while inactive.

```swift
var request = envManager.inputConfigurationState.requested
request.channels = .stereo

let state = await envManager.requestInputConfiguration(request)
// state.requested.channels is Stereo immediately.
// state.reconciliation may still be deferred while inactive.
```

Activation and route changes reconcile the unchanged request. Exact choices
never fall back silently: if Stereo reads back as Mono, the request remains
Stereo and reconciliation becomes unsatisfied with the actual Mono readback.
Automatic channel selection prefers Stereo when the effective input exposes a
valid Stereo option and otherwise selects Mono.

Capture starts from a *contract*, never from a refusal:

```swift
try await envManager.setAudioSessionActive(true)
let contract = try await envManager.resolveCaptureInputContract()

let input = MicrophoneRecordingInput(
  format: contract.settled.format,
  preferredInput: contract.settled.preferredInput
)
```

``AudioEnvironmentManager/resolveCaptureInputContract()`` reconciles the
latest request and derives the layout the capture is started with: an
explicit channel choice is the contract whether or not the route can supply
it (a mono route is replicated into a stereo file), an automatic choice takes
what the platform applied. `contract.reconciliation` and `contract.applied`
travel with it so a caller can say "Stereo · using mono" without treating
that as a reason not to start. The stricter
``AudioEnvironmentManager/settleInputConfiguration()`` still exists for
callers that want a typed throw on a deferred or unsatisfied request.

A configuration surface that shows these facts should keep the session
engaged while it is visible, so every value it renders is read from the route
the recording will run on:

```swift
let hold = try await envManager.acquireAudioSessionHold()
// … the surface is visible; `refreshInputConfiguration()` re-reads on demand …
await hold.release()
```

While a hold exists, the engine's release of session demand after a stop is
deferred until the last hold goes.

## Audio system events

Route transitions, interruptions, and media-services changes share one
platform-neutral value interface:

```swift
let subscriberID = envManager.addAudioSystemEventSubscriber { event in
  await engine.handleAudioSystemEvent(event)
}

envManager.removeSubscriber(subscriberID)
```

These subscribers are fan-out by design — registering multiple subscribers does not displace existing ones, and unsubscribing is per-id.

``AudioSystemEvent`` contains captured values rather than a live platform
session. A caller can forward it to the engine, inspect it for UI, persist it
for diagnostics, or replay it in a deterministic test.

## Activation

Activation is asynchronous and completes only when the platform has actually
finished the transition:

```swift
try await envManager.setAudioSessionActive(true)
```

The platform implementation uses `AVAudioSession.activate(options:)` and
`deactivate(options:)`. Deactivation passes `.notifyOthersOnDeactivation` so
an interrupted app is told it may resume. Synchronous session reads and
preference writes still use the session-access gate.

Three rules govern overlapping requests:

- A request that duplicates the newest *intent* and already matches applied
  state returns immediately.
- Requests are serialized. A request that reaches the front of the queue and
  finds the platform already in the requested state makes no platform call.
- ``AudioEnvironmentManager/isAudioSessionActive`` is written only from a
  completed platform transition, so it mirrors the platform rather than the
  request. A superseded request drops its follow-on input reconciliation and
  lets the newer request perform it.

Completion is evidence that the operation finished, not that capture is ready.
Callers still read back the route and settled input configuration before
starting a capture.

## iOS 27 session lifecycle signals

On iOS 27 the platform adds a session-state channel alongside the interruption
notifications, surfaced as three more ``AudioSystemEvent`` cases:

- ``AudioSystemEvent/sessionActivated`` — a confirmation. If applied state
  disagrees (an activation the manager did not perform), it is reconciled to
  follow the platform.
- ``AudioSystemEvent/sessionDeactivated(_:)`` — carries an
  ``AudioSessionDeactivation`` with the ``AudioSessionDeactivationSource``
  (`.app` or `.system`) and, for a system interruption, the
  ``AudioInterruptionReason``. Applied state is forced inactive on receipt: the
  platform has already deactivated regardless of what the manager believed.
- ``AudioSystemEvent/resumptionRecommended(_:)`` — the system's advice on
  whether to resume.

One interruption can surface on *both* channels. The dedup rule: interruption
events are the recovery trigger, and `sessionDeactivated` stages recovery only
when nothing is staged yet. An `.app`-sourced deactivation never stages
recovery — whoever asked for it owns what happens next.

`resumptionRecommended` is advice about **playback only**. A positive
recommendation may resume pending playback; it never restarts a recording,
because a recording that was left is stopped and only the pending-recording
flow — which requires the caller to still want recording — can bring it back. A
negative recommendation suppresses the automatic playback restart that
`interruptionEnded(shouldResume: true)` would otherwise perform, and leaves
recording recovery untouched.

## Narrow protocol contracts

Feature code typically depends on one of these narrow contracts rather than the concrete `AudioEnvironmentManager`:

- ``AudioEnvironmentDriving`` — run the environment, activate it, and settle
  the latest input request for capture.
- ``AudioEnvironmentConfiguring`` — observe requested/applied state and submit
  complete input requests.
- ``AudioEnvironmentEventSubscribing`` — subscribe to audio-system events.

These contracts let feature code stay testable without a real `AVAudioSession` and keep the platform asymmetries (iOS vs macOS) handled at the implementation, not the call site.

## Interruption interplay with recording

When the audio session reports an interruption while recording is active:

1. ``AudioEnvironmentManager`` translates the native notification into an ``AudioSystemEvent``.
2. The consumer forwards the value to ``AIOEngine/handleAudioSystemEvent(_:)``.
3. The engine's shared recovery policy decides whether to continue, stop, defer, or restart recording or playback.
4. Recoverable: the engine reinstalls the tap and emits ``AudioIOEvent/recordingInterruption(_:)`` with a `.routeChangeContinuing(...)` payload.
5. Unrecoverable: the engine stops recording, emits `.recordingInterruption(.stoppedByInterruption(reason:))`, then `.recordingFailed`.

The application's role is to subscribe to the events stream and drive UI. The engine's role is to make the right reconfiguration decision.

## Topics

### Manager

- ``AudioEnvironmentManager``

### Contracts

- ``AudioEnvironmentDriving``
- ``AudioEnvironmentConfiguring``
- ``AudioEnvironmentEventSubscribing``

### Input + route types

- ``AudioInput``
- ``AudioSource``
- ``AudioInputConfigurationRequest-struct``
- ``AudioInputConfigurationState-struct``
- ``AppliedAudioInputConfiguration-struct``
- ``AudioInputConfigurationCapabilities-struct``
- ``AudioInputEndpointCapabilities-struct``
- ``AudioInputFeatureCapability-struct``
- ``BluetoothMicrophoneCapabilities-struct``
- ``AudioSampleRateRange-struct``
- ``AudioInputConfigurationReconciliation-enum``
- ``AudioInputConfigurationDeferral-enum``
- ``AudioInputConfigurationIssue-enum``
- ``AudioSourceConfigurationOption-struct``
- ``SettledMicrophoneInputConfiguration-struct``
- ``AudioSystemEvent``
- ``AudioSessionDeactivation``
- ``AudioSessionDeactivationSource``
- ``AudioInterruptionReason``
- ``AudioRouteChange``
- ``AudioRouteChangeReason``
- ``AudioRouteSnapshot``
- ``AudioPortSnapshot``
- ``AudioSessionSnapshot``
- ``PolarPattern``

### Errors

- ``SessionError``
- <doc:ErrorHandling>
