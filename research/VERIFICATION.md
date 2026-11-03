# Verification, 2026-10-30

Primary delivered artifact: `build/Clippy.app`, native AppKit island with transparent WKWebView drawing overlay. The user corrected the initial browser UI direction; that page is now a development harness only.

## Passed

- REA 6.8.0 desktop artifact inventory and selected packaged JavaScript analysis. See AI-BOUNDARIES.md for evidence IDs, scope and limitations.
- Seven backend tests: invalid requests/scenes, image magic/size, API-key exclusion, SDK model/schema/image/cancellation forwarding, temporary-file cleanup, failed turns, localhost HTTP access controls, client-disconnect cancellation.
- JavaScript syntax checks for backend, browser harness and transparent overlay.
- Swift native app compilation, plist validation, ad-hoc signature verification.
- Real SDK standard request: `live-standard.json`, GPT-6.1 Sol, five-part molecule, 13,867 ms.
- Real SDK Ultrafast-requested turn: `live-ultrafast.json`, five-part molecule, 24,449 ms. The response does not independently expose the delivered service tier; this is not a latency benchmark or proof of account tier entitlement.
- Native launch shows only the collapsed black `Clippy island`, Ready state, no initial sample or regular app window.
- Native island expansion, typed question, Send, Thinking state and completed answer were observed through CUA.
- Rebuilt native app generated a real labeled water molecule. Command-D focused the transparent drawing, whose accessibility tree exposed five selectable parts. Clicking Oxygen showed its description and follow-up button.
- Escape dismissed the drawing and left the island running in Ready state.
- Source and documentation whitespace check passed.

## Implemented but not fully runtime-verified

- Microphone/on-device dictation and screen attachment: permissions were not requested or granted during QA. No private screenshot was sent to the model.
- Global Ctrl-Option-Space: Carbon registration and native build pass, but CUA's synthetic shortcut did not establish physical global-hotkey behavior. Clicking the island was verified.
- Empty-area click-through: native 20 Hz polling and JavaScript mesh/DOM hit testing are implemented; an underlying application interaction was not verified. Actual mesh/label selection was verified.
- Automatic local-server startup: configured and compiled; native QA reused the already-running project server.
- Fullscreen/Spaces and physical-notch placement on other monitors were not separately tested.

## Limits

This reproduces the native island and floating visual interaction, not the entire HeyClicky product. Scenes use bounded primitives and diagrams. The streaming update below supersedes the original completed-output-only behavior; visuals are not synchronized with token-streamed speech. Connected apps, arbitrary desktop automation and photorealistic custom mesh generation are outside this version.

HeyClicky was never installed or executed. Its read-only inspection disk image was unmounted after analysis. Source code and original app assets were not copied into the replacement runtime.

## Selected-text editing (2026-10-30)

- 10 automated tests pass, including strict edit inputs, no client model override, fixed Sol/high for both actions, isolated read-only tool-free SDK use, and authenticated local edit routing.
- Native build, plist and ad-hoc signature checks pass.
- CLI 0.154.0 rejected Sol for the current ChatGPT login; the SDK-bundled 0.166.0 succeeded. The app now uses the bundled runtime.
- Live synthetic proofreading and rewrite requests succeeded with model `gpt-6.1-sol`, reasoning `high`, standard tier. Proofread 18.347 seconds; rewrite 5.175 seconds. These are individual observations, not a benchmark. Receipt: `research/evidence/live-sol-high-edit.json`.
- Running HTTP /api/edit returned 200 and corrected synthetic text using Sol/high in 11.544 seconds.
- Native Accessibility permission and actual cross-app replacement still require interactive verification. CUA’s targeted synthetic Control-Option-D inserted a control character in the disposable TextEdit document instead of reaching Carbon’s global shortcut handler; this does not establish physical hotkey behavior. TextEdit cleanup was attempted but the UI tool timed out.

## Island appearance and collapse (2026-10-30)

- Native build, plist and signature checks passed.
- CUA visually inspected the 192×28 resting pill and 400×144 composer with coral activity mark, icon controls, send button and collapse chevron.
- Verified: click opens, chevron collapses, reopening preserves an unsent draft, … menu opens, New conversation clears the test draft, Escape collapses. Left app running in its compact state.
- Removed hover-to-expand. Outside-click collapse is implemented with local/global mouse monitors; physical outside-click behavior was not separately established in CUA.

## Realtime voice (feature branch)

- Securely provisioned a local, Git-ignored API credential. No credentials are included in source, tests, receipts or logs.
- All 17 automated tests, JavaScript syntax checks, native build, plist validation and ad-hoc signature verification passed.
- Tests cover session authorization, credential isolation, call cleanup, microphone cancellation and voice-to-Codex tool routing.
- A live Realtime client-secret request accepted the complete session configuration with HTTP 200 and model gpt-realtime-2.1. The ephemeral value was not displayed or persisted. No microphone audio was recorded or transmitted by this check.
- Native microphone permission, end-to-end WebRTC audio, echo cancellation and interruption still require user testing. Configuration acceptance is not proof of those interactions.
- Final inspection of the rebuilt Talk control was blocked because the Mac was locked. Earlier island appearance checks above predate this voice change.

## Progressive visuals and native voice connection (2026-10-30)

- A live SDK probe emitted only one completed agent message. Visuals now use the same bundled CLI via app-server, which exposes incremental agent-message deltas. Editing remains on the SDK.
- A real Terra low/Fast water-molecule request emitted five validated previews at 15.524, 15.974, 16.176, 16.560 and 16.762 seconds; the final result completed at 18.247 seconds. This is one cold-start observation, not a speed guarantee.
- 25 automated tests pass, including every-character JSON chunk boundaries, escaped text, bounded NDJSON decoding, fixed model/tier, temporary configuration isolation, cancellation and voice-preview rollback.
- Native testing caught and fixed a WebKit fetch receiver error that Node mocks did not reveal. A regression test covers the receiver.
- On the Mac, Talk reached Listening after microphone approval. Escape returned the island to Ready and stopped Talk. The user was unavailable for a spoken test, so playback, interruption and spoken drawing remain unverified.
- Screen Recording permission and actual screenshot sharing have not been verified; no private screen was sent during this check.
- A second live check through the authenticated HTTP route delivered previews at 14.380, 14.753, 14.986, 15.328 and 15.794 seconds, then the final result at 17.459 seconds. Local receipt: `research/evidence/progressive-visuals.json` (excluded from Git).
- The native app generated and displayed a real solar-system visual. This established the typed request/rendering path; individual native preview frames were not separately captured.
- Native build, plist/signature validation and JavaScript syntax checks passed. Left the app compact in Ready state, Talk stopped, with the original spoken-reply preference restored.
