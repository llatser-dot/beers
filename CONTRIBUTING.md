# Contributing to Beers

Beers is a small native macOS project. Focused fixes, measured performance work
and well-evidenced UX improvements are welcome.

## Before you start

- Read [`docs/PROJECT.md`](docs/PROJECT.md). It is the current architecture and
  behaviour map.
- Read [`docs/PUBLISHING.md`](docs/PUBLISHING.md) before adding screenshots,
  generated reports or anything derived from real use.
- Keep real dictations, correction logs, benchmark audio, client details and
  personal names out of the repository and its history.
- Do not enable the Bouncer in production unless it passes the documented 0.98
  DELETE-precision gate on both frozen gold and held-out real data.

## Local setup

Requirements: Apple silicon, macOS 14+, full Xcode, XcodeGen and Git LFS.

```sh
brew install xcodegen git-lfs
git lfs install
git clone https://github.com/llatser-dot/beers.git
cd beers
git lfs pull
BEERS_ALLOW_LOCAL_SIGNING=1 ./install.sh
```

`project.yml` is the Xcode project source of truth. Do not hand-edit the
generated `.xcodeproj`.

## Verification

Run the release-readiness gate before opening a pull request:

```sh
./scripts/release-check.sh
```

For Pub Wall changes:

```sh
cd pubwall
npm ci
npm run check
```

For screenshot or public-copy changes, generate the real SwiftUI surfaces:

```sh
/Applications/Beers.app/Contents/MacOS/Beers --beers-snapshot
```

The output lands in `/tmp/beers-snapshots`. The harness must use synthetic,
in-memory content only.

## Pull requests

Keep each pull request narrow and explain:

- the user-visible problem;
- the chosen fix;
- how it was verified;
- any privacy, permissions, signing or migration impact.

Screenshots are expected for visible UI changes. Tests should cover behaviour
changes where a deterministic harness exists.

## Releases

Do not infer release readiness from a successful local build. Signed public
releases must follow [`docs/RELEASING.md`](docs/RELEASING.md): archive,
Developer ID export, Apple notarisation, stapling, re-zipping, Sparkle signing,
asset publication and appcast update.
