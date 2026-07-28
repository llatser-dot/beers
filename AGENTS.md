Read docs/PROJECT.md first — it is the canonical map of this project (layout, pipeline, Bouncer/flywheel status, key commands, hard rules).

This repo is PUBLIC, and it publishes its history, not just its current state. Read docs/PUBLISHING.md before committing any generated or usage-derived file (ml/ reports, flywheel output, eval dumps), or before making another repo public — not for ordinary code work. Short version: real dictations, client names and people's names never enter the repo; metrics and transcript IDs are fine.

## Releasing — read docs/RELEASING.md BEFORE touching a release

Four things that have each already cost a release cycle. Do not rediscover them.

1. **`git push` ships nothing.** Sparkle reads only `appcast.xml` on `main` and
   compares `<sparkle:version>` to the installed `CFBundleVersion`. The appcast
   push IS the release. Bump BOTH `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` in `project.yml` — Sparkle compares the build
   number, so bumping only the marketing string ships nothing.

2. **The notarization credential already exists. Do NOT ask Ben to recreate it.**
   Profile `Beers Notarization 2026` (spaces are part of the name), Apple ID
   `benjaminrestall@outlook.com`, team `6U9UFUUR48`. It is stored under keychain
   service `com.apple.gke.notary.tool` — so any `grep -v com.apple` filter over a
   keychain dump hides it and makes it look absent. It is not absent. The only
   valid check is
   `xcrun notarytool history --keychain-profile "Beers Notarization 2026"`.
   Never conclude "no credential exists" from a keychain dump, and never make
   Ben re-enter it because you filtered it out of your own output.

3. **Build with `archive` + `exportArchive` (`method: developer-id`), never
   `xcodebuild build`.** The `build` action reports BUILD SUCCEEDED, is
   Developer ID signed, hardened-runtime, timestamped, and passes
   `codesign --verify --deep --strict` — and Apple still rejects it. It injects
   `com.apple.security.get-task-allow` (absent from `Beers.entitlements`, so
   invisible in source) and leaves `Sparkle.framework/Versions/B/Autoupdate`
   and `.../Updater.app` on their upstream signatures.

4. **Order: notarize → staple → re-zip → Sparkle-sign that zip.** Stapling
   rewrites the app, so a zip made before it fails the signature check on every
   user's machine. Sparkle's key is under the OLD bundle id: every
   `sign_update` / `generate_keys` call needs `--account com.llatser.listen`, or
   it reports "No existing signing key found!" and looks like the key is lost.

`.github/workflows/release.yml` automates all of this on a `v*` tag, but is
gated on six repo secrets that do not exist yet, so it currently skips. Until
they are added, release by hand per `docs/RELEASING.md`.

Act like a high-performing senior engineer. Be concise, direct, decisive, and execution-focused.
Solve problems with simple, maintainable, production-friendly solutions.
Prefer low-complexity code that is easy to read, debug, and modify.
Do not overengineer. Do not introduce heavy abstractions, extra layers, or large dependencies for small features. Choose the smallest solution that solves the problem well.
Keep implementations clean, APIs small, behavior explicit, and naming clear. Avoid cleverness unless it clearly improves the outcome.
Write code that another strong engineer can quickly understand, safely extend, and confidently ship.
Default reasoning effort: medium unless explicitly asked for deeper reasoning.
Large-output guardrail: never run broad or unbounded scans on huge trees. Use targeted rg/find patterns, bounded head/tail samples, and path filters first. Escalate to wider scans only if the narrow pass is insufficient.
Large-output guardrail: when a command can emit large output, request short output and iterate in small chunks instead of dumping full files or full indexes.
Thread rollover rule: after each major milestone (for example fix verified, deploy done, root cause delivered), close with a compact checkpoint and recommend starting a fresh thread from that checkpoint before continuing.
