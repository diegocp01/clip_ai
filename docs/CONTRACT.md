# Clippy local app contract

Independent implementation, no HeyClicky code or assets copied into the app.

GET /api/status returns {model, authenticated, auth: "ChatGPT", tiers: ["standard","fast"], note}. Tiers are request choices, not proof of account eligibility.
GET /api/status?provider=claude returns the same shape for the Claude CLI: {provider, model, reasoningEffort, authenticated, auth: "Claude", note}. Without the query it describes GPT.
GET /api/session returns {token}; send X-Clippy-Session header on POST /api/chat.
POST /api/chat JSON: {message: string, tier: "standard" | "fast", history: [{role: "user" | "assistant", content: string}], previous: visual-result | null, image: PNG/JPEG data URL | null}. Max 8 MB body. Model always gpt-6.1-terra. Defaults fast, with low reasoning. No API key.
POST /api/chat also accepts provider: "gpt" | "claude", defaulting to "gpt". GPT uses the Codex SDK and ChatGPT login. Claude uses the signed-in Claude CLI with no tools, MCP servers, settings, hooks, skills or saved sessions, and with API keys kept out of its environment. Results include provider. There is no fallback between providers, and tier does not apply to Claude. /api/edit and live voice stay on GPT.
Response application/x-ndjson stream: {type:"status",message}, {type:"preview",result}, {type:"result",result,usage,elapsedMs,model,reasoningEffort,requestedTier}, {type:"error",message}. Browser AbortController cancels server/model. Errors are shown, no silent tier/model fallback.

visual-result is {title, reply, cards: [{title, body}], diagram: {nodes: [{id,label,x,y,color}], links: [{from,to,label}]}, scene: {objects:[{id,label,description,shape,color,position:[x,y,z],scale:[x,y,z],rotation:[x,y,z]}]}}.
All fields required. Empty arrays when not needed. diagram coordinates 0..100, SVG viewBox 0 0 1000 600. shape enum sphere, box, cylinder, cone, torus. Positions -10..10, scale .05..5, rotations radians. Up to 24 diagram nodes, 40 links, 40 scene objects, 6 cards. Colors #RRGGBB. Model generates only this data, never executable code or HTML.

Primary experience: native macOS black island at the top of the current display. Borderless NSPanel, no Dock icon or regular app window. Expands to compact text/voice/screenshot controls; Ctrl-Option-Space toggles it. Native client owns HTTP requests, cancellation, in-memory conversation and previous result. Only real validated model parts appear, progressively during generation. Previews do not enter history or previous-result context; errors and cancellation restore the last committed result. Transparent floating WKWebView loads /overlay.html and renders above the user's other apps. Native noninteractive captions sit at the bottom of the display. The original ivory browser UI is retained as a development harness only.

Overlay contract: window.clippyRender(result, preview=false) receives a validated visual-result. window.clippyCaptionManaged=true suppresses web captions when native captions are present. JS sends window.webkit.messageHandlers.clippy.postMessage({action:'ready'|'closeOverlay'|'dragOverlay'}) and {action:'followup',text}. Default document is transparent and blank. ?demo=water is an explicitly labeled QA-only sample, never the default native experience.

Optional dictation uses macOS on-device recognition with no cloud fallback; system speech can read typed answers. Live Talk uses the separate Realtime flow described below. Screen capture is one explicit user action, stored in memory until Send or removal, not continuous observation. No external URLs, CDN, fonts, images, telemetry, login item or HeyClicky services are required by the app.

POST /api/edit: {action: "proofread" | "rewrite", text: string} with the same local-session token and NDJSON transport as /api/chat. Requires nonempty text, max 12,000 UTF-16 units. Always GPT-6.1 Sol, high reasoning, standard tier; clients cannot override these. Returns result: {text}, model, reasoningEffort, requestedTier, usage, elapsedMs. No screenshots, history or tools.

Realtime voice: GET /api/realtime/status returns only configured/model metadata. POST /api/realtime/call accepts {sdp}; POST /api/realtime/stop accepts {id}. Both require the local session token, valid local Host/Origin and JSON. A single 10-minute call is allowed. The server alone reads .env.local and exchanges the SDP with OpenAI. Realtime WebRTC media travels directly between WebKit and OpenAI. draw_visual delegates through the existing token-protected /api/chat route with Terra/Fast; voice has no desktop or connector action tools.
