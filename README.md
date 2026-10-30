# Clippy Island

A local Mac assistant that lives at the top of the screen and places interactive visuals over your desktop. Reasoning and visual generation run through the Codex SDK with your existing ChatGPT login.

This is a separately implemented app inspired by the HeyClicky demo. It does not install HeyClicky, call its backend, reuse its credentials, or ship its drawing code.

## Open the app

Requires macOS 14.2+, Node.js 22 or later, and Xcode Command Line Tools (for Swift).

```sh
npm ci
npx codex login
npm run desktop:build
open build/Clippy.app
```

The primary interface is the black island at the top of your display. Click to open it; click the top-right chevron or press Escape to collapse it. The earlier browser interface at `http://127.0.0.1:4317/` remains only a development harness.

Use the island to ask a question, dictate on-device, or attach one screenshot. Select text in another app and press Control-Option-D to proofread or Control-D to rewrite; both use GPT-6.1 Sol with high reasoning and replace the selection automatically. Generated 3D objects and diagrams appear in a transparent floating overlay above your other apps. Select a labeled part to ask a follow-up. See [desktop/README.md](desktop/README.md) for shortcuts and controls.

Sign in with ChatGPT using the bundled Codex CLI. Your account needs access to `gpt-6.1-terra` for visuals and `gpt-6.1-sol` for text editing. Codex visuals and text editing use your ChatGPT login. Optional realtime voice uses a separate OpenAI API key and API billing.

## What uses AI

Typed and dictated questions, explicitly attached images, prior answers and the previous scene are sent to Codex. The SDK generates validated scene data rather than host-executable JavaScript. The app renders 3D primitives with Three.js and diagrams with SVG. Optional local dictation uses on-device recognition. Talk uses GPT-Realtime-2.1 over WebRTC for streaming speech, turn detection and interruptions; the speaker button mutes replies. Audio is sent to OpenAI only after you start Talk. End, Escape or Quit stops the microphone. Typed replies can still use installed system voices.

Each model turn uses a read-only, tool-disabled, ephemeral Codex session. Personal Codex configuration, tools and environment API keys are excluded. Screenshots are temporarily written for SDK image input, then removed. Conversation context is held in the running client, not a project chat database. The Codex service processes prompts and images; this is not offline inference.

## Live voice

Save `OPENAI_API_KEY` in a local `.env.local` file (ignored by Git). Never commit this file or put the key in browser code. The server reads the credential; WebKit receives only the WebRTC connection answer.

Click **Talk**, grant macOS microphone access, then speak naturally. Click **End** to stop. Say “Draw a water molecule” to delegate a visual to Codex using Terra low/Fast. Click **Screen** during Talk to explicitly share one screenshot as voice context. Voice does not continuously watch your screen. The speaker button mutes spoken replies without ending microphone capture; use End to stop listening. Sessions end after 10 minutes and can be restarted. The … menu keeps optional on-device dictation separate.

API credential and session-configuration acceptance have been verified. Native microphone permission, WebRTC audio playback and interruption behavior still need an interactive test on the target Mac.

## Speed and cost

Model: `gpt-6.1-terra`. Low reasoning and Fast mode are the defaults. Standard and Fast are explicit requested tiers, with no silent model/tier fallback. Access and billing follow your Codex account. The SDK does not make inference free or unlimited. A successful request does not expose independent proof of the server's delivered service tier.

Official references: [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk), [speed and eligibility](https://learn.chatgpt.com/docs/agent-configuration/speed).

## Checks and evidence

`npm test` covers schema validation, SDK request configuration, temporary image cleanup, API-key exclusion, local HTTP access restrictions, and cancellation. `npm run check` checks JavaScript syntax. `npm run smoke` makes a real small model request and saves a receipt under `research/evidence`.

[Static investigation](research/AI-BOUNDARIES.md) records the REA findings and limitations. It found separate agent, conversation, drawing and speech interfaces; a one-line provider replacement would not recreate the app. HeyClicky was downloaded and inspected without installing or launching it. Raw evidence, extracted code and original binaries are local-only and are not distributed in this repository. The written summaries reference those excluded artifacts.

## Current limits

The original demo's arbitrary generated programs, detailed bespoke 3D meshes, incremental visual generation, computer control and connected services are not reproduced. Live audio is implemented separately from visual generation. This version uses bounded primitive scenes and diagrams. Visuals appear after a model response completes; latency depends on Codex. Dictation and screen capture require your OS permissions on first use. No routine, login item or background installation is created.

Clippy uses the Codex CLI bundled with its SDK (0.166.0) for current model support, reusing your existing ChatGPT login. It does not update the globally installed CLI.

## Contributing

After the initial bootstrap, changes go through feature branches and pull requests. CI runs the JavaScript checks and tests without credentials; native builds and permission-dependent behavior need macOS verification. See [AGENTS.md](AGENTS.md).
