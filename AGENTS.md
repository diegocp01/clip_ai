# Repository workflow

The initial bootstrap commit is the only change authorized for direct publication to `main`.
After that, make changes on a feature branch and open a pull request. Do not push further
commits directly to `main` or merge a PR without the user's explicit authorization.

Keep downloaded HeyClicky binaries, extracted proprietary code, raw research evidence,
credentials, local runtime files and app builds out of Git. Publish only this independent
implementation and written research summaries. Never claim full HeyClicky feature parity.

Run `npm test` and `npm run check` for backend or JavaScript changes. For native changes,
also run `npm run desktop:build` on macOS. Distinguish successful compilation and model
tests from verified native permissions, shortcuts and cross-app interactions.
