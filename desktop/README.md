# Clippy island for macOS

The primary app lives in a small black island at the top of the screen. It has no normal app window or Dock icon. Click it, or press **Control-Option-Space**, to open its compact composer. On notched MacBooks, the collapsed island sits in the menu-bar row and at rest extends only 24 points to the right of the physical camera, showing a green dot there, with nothing to its left. Green means the local server answers and Codex is signed in. Pointing at the dot makes it react: the right side grows to 44 points and the dot glows and pings until the pointer leaves. The waveform replaces the dot, on a 36-point right side, only while audio is live (Talk, dictation or spoken replies). Progress, notices and problems show text left of the camera, up to 130 points, and a dot that turns coral while working or when something is wrong; one-off notices return to the dot after 5 seconds. No compact controls are placed behind the camera or below the notch. Its top corners are square to meet the screen edge and its lower corners are rounded. Opening it shows the 400 × 144 composer below the camera, joined by a black, click-through background. Displays without a notch use a floating pill with the same states, resting at 30 × 22. Click the top-right chevron, press Escape while focused, or click outside to make it small again. Hovering never opens the composer; only a click or the shortcut does. Your unsent text stays in the composer.

Build with `npm run desktop:build`, then open `build/Clippy.app`. The app reuses a healthy local server at `127.0.0.1:4317`. If none is available, it starts this project's server as its own child process, and stops only that child when you quit. No installation, login item or background service is registered. The build saves this checkout's Node/Codex paths in the app's `runtime.json`; rebuild after moving the checkout or changing those paths.

## Use

- Type a question and press Return or Send. The native app calls the local Codex backend and progressively shows validated visual parts in a transparent floating drawing panel above the current desktop. No sample drawing appears automatically.
- Rotate, zoom or select 3D parts in the drawing. Follow-ups keep the previous scene and bounded conversation history in memory.
- Drag the drawing using its drag handle. Hide drawing dismisses both the drawing and captions. The … menu or menu-bar paperclip can reopen the last drawing.
- Captions float near the bottom of the display. Voice on/off toggles local macOS speech synthesis.
- Talk starts an OpenAI Realtime voice conversation. End or Escape stops the microphone and connection. Collapse keeps the voice session running, indicated by the island’s activity state. The speaker button mutes output, not the microphone. … → Dictate on-device remains available separately.
- Screen captures the main display once, with Clippy's panels temporarily hidden. It requests Screen Recording permission only when used. The screenshot remains in memory until sent or removed, and the temporary capture file is deleted immediately. Clicking Remove screen clears it. During Talk, Screen explicitly shares that single screenshot with the live voice session instead.
- Standard/Fast selects the requested Codex service tier. Your account must support the selected tier; errors remain visible and never trigger a silent fallback.
- Cancel aborts the active model request and restores the last completed visual. Escape also cancels an active request, or otherwise hides drawings and collapses the island. … → New conversation clears the in-memory conversation and attachment.

## Selected-text editing

Select text in another app, then press **Control-Option-D** to proofread or **Control-D** to rewrite. Both always use **GPT-6.1 Sol with high reasoning**, independent of the Terra/Fast drawing settings. The result replaces the selection automatically using normal Paste; Command-Z undoes it. Clippy never presses Return or submits the field. Control-D is reserved globally while Clippy runs, overriding apps that use it for forward-delete or EOF.

Use the paperclip menu → Enable text editing… to open the permission prompt. Allow Clippy under System Settings → Privacy & Security → Accessibility on first use. Fn dictation is untouched. Only selected text is sent, up to 12,000 characters. Password fields and fields that expose no verifiable selection are excluded. If you change the field, app, selected range or selected text before completion, Clippy leaves it untouched and shows a copyable result. The clipboard is restored after Copy/Paste unless it changed meanwhile. Use the paperclip menu → Cancel text edit to stop a request.

## Boundaries and verification

This is an independent implementation, not a modified HeyClicky app. The native bridge and drawing navigation accept only the local server origin. Model results are validated by the backend before being drawn. Local screen capture and on-device voice are explicitly activated by you.

The build uses native Swift/AppKit, WKWebView, Carbon hotkeys, Speech and AVFoundation. It is ad-hoc signed for this Mac, not notarized for distribution. Microphone and speech availability depend on the Mac, language and permissions. Screen Recording permission can require restarting the app after authorization. Empty transparent drawing areas pass clicks through; objects and controls receive clicks. Command-D focuses the last drawing while Clippy is active, and Command-Q quits.

Compilation, plist syntax and signature checks are performed by the build script. Actual native rendering, microphone, screen capture and hotkey behavior require interactive verification separately.

Run `bash scripts/test-island-layout.sh` on macOS to check notch clearance, camera-width alignment, external-display coordinates and the safe-area fallback. The expanded notch background never receives mouse events. The collapsed wings occupy 72 points beside each side of the camera and can cover menu items in that space. Hardware-notch appearance needs a physical-screen check; software screenshots do not capture the camera cutout.
