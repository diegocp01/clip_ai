# Private local features

The public app starts with no habit ring, checklist, habit menu items, or reserved space beside the notch. All other Clip features work normally.

## Enable your own tracker

Copy `local-features.example.json` to:

```text
~/Library/Application Support/Clip/local-features.json
```

Create the directory if needed. Edit the seven neutral task titles and set `habits.enabled` to `true`, then quit and reopen Clip. Exactly seven unique IDs and non-empty titles are required; malformed or missing settings leave the feature off. IDs use letters, numbers, underscores or hyphens. Titles are at most 32 characters.

The ring stays inside the black notch in both states. Click it to reveal your list; click the chart icon for 7- or 30-day history. A finished day is 1 only when all seven items are done, otherwise 0. Today stays provisional. There are no habit API calls.

Keep item IDs stable when changing a label. Existing local progress and history are preserved in the `local.clippy.codex` macOS preferences domain. Changing an ID creates a different item; it does not rename its past completions. Config and progress are never copied into the build or sent to the generation APIs.

## Demo mode

Quit Clip and launch `open build/Clip.app --args --public-demo`. This ignores the personal feature file without changing it or the saved history. Relaunch normally to restore your local tracker. The build script never bundles this file, and repository ignore rules exclude private settings exported into the checkout.

Demo mode only hides private Clip features. It does not redact your screen, prevent screenshot sharing, clear conversations or disable automatic selected-text editing. Record with non-sensitive content visible and no private text selected.
