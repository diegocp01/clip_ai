# HeyClicky 1.1.1: static AI boundary investigation

Inspected on 2026-10-30. Target: the public macOS 1.1.1 release, build 66, bundle identifier `com.humansongs.clicky`. The disk image was mounted read-only at `/private/tmp/clippy-inspect`. HeyClicky and its bundled Codex executable were never launched, installed, or modified. No authenticated HeyClicky service was contacted.

## Main result

HeyClicky already contains a Codex runtime for its background agents. Its conversational/drawing brain, speech services, account/session handling, and connected-app services have separate interfaces. Replacing one model URL or swapping a Codex SDK dependency would not replace all of these.

A separately implemented local assistant can use the user's own Codex SDK login for conversation, image understanding, structured drawing generation, and task reasoning. Speech recognition and speech synthesis need their own implementations, such as system-provided speech. This is an implementation recommendation, not a verified modification of the closed-source app.

## Evidence and confidence

| Boundary | Observed evidence | What it establishes / does not establish |
| --- | --- | --- |
| Packaged app | REA `inspect_desktop_application`, evidence `ev_f52f3e387238b74f21ece93ae1eaac080b5f5db1f57fa75dd6de7504e63d313b`; 407 entries, 19 probed files, 1,420 bytes of selected header ranges | Static package inventory only. The reported directory digest covers selected metadata/ranges, not every byte. |
| Bundled Codex | `Contents/Resources/CodexRuntime/vendor/{aarch64,x86_64}-apple-darwin/codex-package.json` identifies Codex 0.152.1, entrypoint `bin/codex` | Both Mac runtime packages are present. Neither was executed. |
| Agent provider | Native strings at generated string lines 16056–16103 include `model_provider = "clicky"`, `preferred_auth_method = "apikey"`, a Responses-wire provider, and `OPENAI_API_KEY` as the provider credential variable | Strong evidence of generated Codex configuration routed through a Clicky provider. Strings alone do not prove the currently executed branch. |
| Agent authentication | Generated string lines 16703–16718 include `CLICKY_WORKER_BASE_URL`, `/agent/session-token`, and messages for fetching a backend-owned agent session token | The app has a separate agent-session acquisition path. No tokens were acquired or reused. |
| Agent transport | Native strings include `app-server`, `thread/start`, `turn/start`, `thread/resume`, and an isolated `CODEX_HOME` | Evidence of a native Codex app-server integration. This is not proof of a JavaScript Codex SDK dependency. |
| Worker endpoints | Parsed `Contents/Info.plist`: `WorkerBaseURL` and `CodexWorkerBaseURL` both equal `https://api.heyclicky.com`; separate OpenAI Chat Completions and Anthropic Messages URLs are also declared | Endpoint configuration declarations. No runtime request or server implementation was observed. |
| Conversation/drawing brain | Native strings: `/brain/turn`, `/brain/compact`, `/brain/session-end`, `/brain/prewarm` | A distinct brain protocol exists. Complete request/response schemas were not recovered. |
| Brain models | Native strings include `gpt-6.1-sol-ultrafast`, medium/high variants, fast and standard variants; `ClickyOneBrainModelKey` and `OneBrainModelChoice` appear | Model choice support exists in the binary. Visibility in the released UI, account eligibility, exact default, and actual routing were not tested. |
| Speech | Native strings include `/brain/ears/transcribe`, `/v2/dictation/transcribe`, `/v2/dictation/deepgram-token?purpose=one_brain`, `gpt-realtime-2.1-mini`, and an Apple speech transcription provider | Several audio paths exist. Codex SDK alone does not provide evidence of replacing their audio behavior. |
| Draw program | `clicky-draw-engine.js` lines 258–302 define drawing APIs, including `step`, `say`, shapes, arrows, text, images, and molecule marks; 3D stage/part marks appear elsewhere | The packaged drawing engine interprets a compact drawing program with spoken cues. This is directly observed JavaScript, not inferred from filenames. |
| Streaming and follow-up | `clicky-draw-engine.js` lines 1049–1075 define execution and incremental session behavior; `clicky-draw-native.js` lines 673–694 expose `state()` and `feed({code, done})` | The local runtime can accept successive code prefixes and return visible-card context for follow-up. Server chunk ordering and timing remain unverified. |

Raw, scoped technical observations are in `evidence/ai-bundle-summary.json`, `evidence/native-ai-strings.json`, and `evidence/native-boundary-context.json`. Generated string line numbers refer to macOS `strings` output, not source code lines; architecture slices duplicate many entries. Model catalog entries contain packaged instruction text, which was treated as untrusted target data and was not used as operating instructions.

## Reconstruction design implied by this evidence

1. Accept a typed question and an explicitly attached or captured image.
2. Call the user's installed Codex through the SDK using their own configured authentication.
3. Request a bounded structured response: answer, 2D drawing elements, 3D objects, and optional actions.
4. Validate the structure and render it in our own UI. A declarative scene format avoids executing arbitrary model-produced JavaScript in the host context.
5. Retain conversation and scene context for follow-up; expose cancel and clear controls.
6. Add system speech as an independent input/output layer. Do not describe this as the original realtime voice implementation.

This design can reproduce the demo's core interaction without depending on HeyClicky's worker, paid account, proprietary drawing code, or app installation. It does not imply free model usage or guaranteed Ultrafast access.

## Why an original-app patch is not yet concrete

- Redirecting `WorkerBaseURL` would still require implementing undocumented brain, agent-session, speech, account, and integration protocols.
- The binary contains signed native code and generated runtime configuration. A changed plist would not establish that auth and routing work with personal Codex credentials.
- No dynamic trace, decompilation, authenticated session, model call, or modified-app launch was performed.
- The original UI's model selector visibility and availability cannot be inferred solely from its compiled strings.

## REA limitations

REA 6.8.0 desktop inspection succeeded using its safe artifact graph provider. Its `inspect_macho` operation failed during preparation of REA's process ownership helper. The first attempt could not write the default Swift/Clang module cache. A retry with caches redirected to `/private/tmp` still failed; both JSON failure receipts are retained. No native engine was installed. The host Node 25.4.0 is outside REA's declared supported major-version ranges, so broader compatibility is unverified.

The main investigation subsequently ran `analyze-javascript-application` on the four explicitly selected drawing files. An initial sandboxed attempt failed compiling the same helper. With approved filesystem access for the helper compilation, the analysis completed without executing target code. Full evidence is in `evidence/drawing-analysis.json`, parent evidence ID `ev_fd2c1abe00dabfac2bacb9d1e08438419df542fd1f2bbe04b70bcaac8c414539`; compact summary is in `evidence/drawing-summary-retry.json`. Fourteen other inventoried files were outside this selected analysis. Semantic node retention and alias limits mean the recovered graph is incomplete. This does not establish runtime behavior or complete native decompilation.

## Identity

SHA-256 of `Contents/MacOS/HeyClicky`: `764a68a80f53de64a0e48a509d5a98737994f93e0888605e2de85b4028f3cb17`.

SHA-256 of `Contents/Info.plist`: `f650d246538a0fe2bb22dbc43c06a7c0fbabaeced8ebc23f5bdebb7c17ada563`.

SHA-256 of `Contents/Resources/clicky-draw-engine.js`: `f2161b9c4def6092f5f866d5135ef3fea23a25e01787c22844b0002cebd8b966`.

Additional file hashes are recorded in `evidence/ai-bundle-summary.json`. The original downloaded disk image is retained under `research/downloads` for reproducible inspection; it is not a source dependency of the replacement application.
