<div align="center">

# 🍺 Beers

**Open-source push-to-talk dictation for macOS.**

Hold a key, say the thing, let go — the words land wherever your cursor is.
On-device speech recognition. No cloud, account or subscription required.

</div>

---

Beers turns your voice into text in any app on your Mac. Hold your pour key, talk,
release — the transcript pastes straight at the cursor, whether that's Mail, Slack,
a terminal, or your editor. In Beers-speak, one dictation is a **pour**, and every
1,000 words you pour **pulls a pint**.

Everything that matters runs **on your machine**. Transcription is
[Parakeet v3](https://github.com/FluidInference/FluidAudio) (multilingual) or v2
(English) via FluidAudio, executed locally through Core ML. Your voice
never touches a server.

## Why Beers

- **On-device by default.** Speech-to-text is local. There is no API to call, no
  key to paste, nothing to sign up for. Beers keeps its data in a couple of
  folders under your home Library (pours, the flywheel log, downloaded models);
  removing it is a short checklist — see [Uninstall](#uninstall).
- **Parakeet-first by design.** Ordinary pours now take the shortest trustworthy
  path: Parakeet → minimal artefact cleanup → your explicit vocabulary corrections → paste. There is no
  automatic generative rewrite, deletion model or ramble gate in the default path.
  The former deterministic cleanup rules remain available as an off-by-default
  comparison mode.
- **No Ollama tax.** Beers cannot launch, prewarm or call Ollama, and it has no
  external text-model endpoint in the production app. Optional Command Mode uses
  only Apple's system-managed on-device model when the Mac supports it; otherwise
  it fails closed without starting another process.
- **The Bouncer is parked research.** The bundled disfluency tagger can only
  delete words, never invent them, but three versions failed the real-speech
  precision gate. The latest reached 0.222 DELETE precision against a required
  0.98, so it does not run in the production path. Its local flywheel and frozen
  evaluation harness remain for future evidence-led work; activation can happen
  only after a reviewed model passes both gold and held-out real exams. The full
  story is in [`ml/DESIGN.md`](ml/DESIGN.md).
- **It learns your words.** Beers watches the keyboard corrections you make in the
  couple of minutes after a paste and turns them into vocabulary suggestions — so
  "plan watch" becomes "PlanWatch" next time, without you teaching it by hand.
- **Private, actually.** Dictation stays on your Mac and there is no telemetry or
  remote transcript-rewrite endpoint. The training-data directory is
  gitignored — even the author's own dictation isn't in this repo — and Beers
  itself has no upload path for the flywheel records.

## Screenshots

**The Taproom** — every pour you've served, searchable, grouped by app, with your
streak and Keepers (the pours worth saving).

![Beers Taproom — searchable dictation history](docs/screenshots/taproom.png)

**Brew Controls** — one screen, everything on tap: pour key, where the words land,
sounds, the listening pill's position, and your local brew engine.

![Beers Brew Controls settings](docs/screenshots/brew-controls.png)

**The Little Black Book** — every learning feature on one switchboard, with the
promise printed right on it: Beers never uploads those learning records.

![Beers privacy controls — The Little Black Book](docs/screenshots/little-black-book.png)

## Features

| Feature | What it does |
|---|---|
| **Push-to-talk** | Hold the pour key (Left Command ⌘ by default, configurable), speak, release. Text pastes at the cursor. |
| **Command Mode** | On supported Macs, hold **Shift + pour key** over selected text and say the edit ("make this a bullet list"); Apple's system-managed on-device model rewrites the selection in place. |
| **Optional legacy polish** | Off by default. Enables the former rule-based writing modes for controlled comparison against Fast Parakeet. |
| **The Taproom** | Searchable history of every pour, grouped by day and app, with Keepers (starred), the drip tray (trash), and your daily streak. |
| **Listening HUD** | A compact "pour" pill (position configurable, notch-friendly) shows the live state — taking order → pouring → settling → served — plus your running pint count. |
| **Vocabulary** | The Brewer's Dictionary maps what Beers *heard* to what you *meant*, and auto-suggests fixes harvested from your keyboard corrections. |
| **Pint leaderboard** | Opt in from the Taproom with a verified private email and unique public `@handle`; 1,000 words = 1 pint on the live community Pub Wall. The service receives aggregate word/pour counts, never transcripts or audio. The [complete boundary is public](pubwall/README.md). |

## Download

Grab the latest release from **[Releases](https://github.com/llatser-dot/beers/releases/latest)**
— no Xcode, no build step:

1. Download `Beers.app.zip` and unzip it.
2. Drag **Beers.app** into **Applications** and open it.
3. macOS blocks the first launch (not notarized yet — see
   [Gatekeeper](#a-note-on-gatekeeper) below): System Settings →
   Privacy & Security → **Open Anyway**, then open Beers again. One-time step.
4. Grant **Microphone**, **Accessibility** and **Input Monitoring** when asked,
   then hold **Right Option** and speak.

Prefer a guided install? `Beers.AirDrop.zip` on the same page bundles an
installer script that copies the app to /Applications for you.

Apple Silicon only. Everything runs on-device.

## Install from source

Prefer to build it yourself? It's a one-command build once you have the tools.

### Requirements

- **macOS 14.0 or later** (Sonoma+).
- **Apple Silicon** (M1 or newer). This is the only supported public target;
  Parakeet runs locally through Core ML. Intel runtime behaviour has not been
  validated.
- **Full Xcode** (not just the Command Line Tools). `install.sh` runs
  `xcodebuild … archive`, which needs a complete Xcode install — install Xcode
  from the App Store, launch it once, and make sure `xcode-select -p` points at
  `…/Xcode.app/Contents/Developer` (if it still points at
  `/Library/Developer/CommandLineTools`, run
  `sudo xcode-select -s /Applications/Xcode.app`). You need a working toolchain
  with a team signed in, *or* let the installer mint a stable local code-signing
  certificate for you.
- **XcodeGen** — `brew install xcodegen`. The Xcode project is generated from
  `project.yml`, not committed.
- **Git LFS** — `brew install git-lfs && git lfs install`. The Bouncer Core ML model
  (`Bouncer.mlpackage`) is stored via Git LFS. If you clone without LFS you'll get a
  pointer file instead of the model and the build will fail — run `git lfs install`
  **before** cloning, or `git lfs pull` inside the checkout afterward.

### Build & install

```sh
git clone https://github.com/llatser-dot/beers.git
cd beers
git lfs pull                      # if you didn't `git lfs install` before cloning
LLATSER_ALLOW_LOCAL_SIGNING=1 ./install.sh
```

`install.sh` first tries a proper Developer ID build (for maintainers who have the
certificate and set `LLATSER_LISTEN_TEAM_ID`). Without that configuration,
`LLATSER_ALLOW_LOCAL_SIGNING=1` tells it to build and
sign with a **stable local identity** instead — the installer creates that identity
automatically on a fresh machine, so you don't need any Apple certificate to get
running. It builds a Release binary, installs to `/Applications/Beers.app`, cleans
up stray build copies, and launches the app.

> The local signing identity is deliberate: it keeps your macOS privacy grants
> stable across rebuilds. Ad-hoc signing (`codesign -s -`) would re-key permissions
> on every build and force you to re-grant them constantly — Beers never does that.
> On a Mac with no usable signing identity, the installer creates a ten-year
> `Llatser Listen Local Code Signing` certificate and private key in your login
> keychain and trusts that certificate for code signing on this Mac only.

### Permissions it will ask for

On first launch, Beers requests three macOS privacy permissions. Each maps to one
job, and it won't work without them:

| Permission | Why |
|---|---|
| **Microphone** | To hear you. The mic is only live while the pour key is held. |
| **Input Monitoring** | To detect your global pour-key hold from any app. |
| **Accessibility** | To paste the transcript at your cursor, and to read the current selection for Command Mode. |

Grant all three once when prompted. Because the build is signed with a stable
identity, future rebuilds keep the grants — you shouldn't have to do this again.

### A note on Gatekeeper

A self-built copy is **self-signed** with your local identity. It runs fine on your
own machine; the first launch may need a right-click → **Open** to get past
Gatekeeper. It is **not** notarized, so you can't hand the `.app` to someone else and
have it open cleanly — notarized releases are planned, and until then, building from
source is the way in.

### First-run models

The Parakeet speech models download automatically on first use (a few hundred MB,
once) to:

```
~/Library/Application Support/FluidAudio/Models/
```

### Uninstall

Beers is honest about where it puts things, so a full removal is a short list.
Deleting the app alone leaves your data and models behind; to remove everything:

- **The app** — delete `/Applications/Beers.app`.
- **App data** — `~/Library/Application Support/Beers/` (your pours, the
  `flywheel.jsonl` training log, the `beers.log` app log, and any explicitly
  opted-in `ASR Benchmarks/` audio).
- **Speech models** — `~/Library/Application Support/FluidAudio/Models/` (the
  downloaded Parakeet models cache, a few hundred MB).
- **Login item** — if you enabled "Open bar at login," remove Beers under
  **System Settings → General → Login Items**.
- **Local signing identity** — only if the installer created `Llatser Listen Local
  Code Signing`, remove that certificate and its private key in Keychain Access.
  Do not remove an Apple Development or Developer ID identity you already had.
- **Preferences** — `defaults delete com.llatser.listen` (clears saved settings
  from UserDefaults).
- **Log symlink** — `/tmp/llatser-listen.log` (a symlink to the owner-only
  `beers.log` above; harmless, but tidy it if you like).

Privacy permissions (Microphone, Input Monitoring, Accessibility) can be revoked
in **System Settings → Privacy & Security** if you want them gone too.

## Verify without installing

Contributors and CI can run the same non-installing release-readiness gate:

```sh
./scripts/release-check.sh
```

It requires a clean checkout, full Xcode, XcodeGen, Git LFS and Python 3. The
gate verifies every current LFS object is materialised, exercises transcript
polish and sanitation, proves the binary contains no Ollama client, and builds an **unsigned arm64**
Release app in a temporary directory, and checks its bundle metadata and Bouncer
resources. It never launches or installs the app, touches TCC, signs with a local
identity, notarises, uploads, deploys or publishes anything.

Passing this gate is necessary, but it is not a public release. A distributable
build still needs an authorised maintainer to archive with a Developer ID
Application identity, submit it to Apple for notarisation, staple the accepted
ticket, verify Gatekeeper on the final artefact, and publish that exact artefact.

## The flywheel — how the Bouncer learns

Every pour and every keyboard correction is logged **locally only**, to
`~/Library/Application Support/Beers/flywheel.jsonl` (outside this repo; the app
never uploads it). A `launchd` standing loop periodically checks whether enough real data
has accumulated and, if so, retrains the Bouncer on *your* speech, scores it against
the frozen gold exam plus held-out real dictation, and writes a report. The latest
v3 run failed and the production path is parked. One honest
caveat: the committed reference loop (`ml/standing-loop/`) is the author's personal
automation and uses a cloud LLM agent (Claude) to label the training data — so
running *that* loop sends flywheel text to Anthropic and requires your own Claude
access, which may cost money. The app neither installs nor runs the loop;
nothing retrains unless you set it up yourself, and a fully on-device trainer is
the roadmap item that closes this gap. It **never**
activates the model and **never** commits anything — going live is a manual,
reviewed step. Flywheel logging and correction-watching remain controllable and
default on; Bouncer execution is parked rather than exposed as a live toggle.

If you'd rather not participate at all, switch off flywheel logging in the app —
dictation still works exactly the same. Same-audio benchmark capture is a separate
switch, is off by default, and stores 16 kHz mono WAVs locally until you use the
confirmed **Pour it away** action. After filling the `gold` fields in its local
manifest, `scripts/run-asr-benchmark.sh` compares Parakeet v3 auto, v3 English and
v2 English on identical audio and reports WER, faulty-sentence rate and latency.

## Architecture

- [`PROJECT.md`](PROJECT.md) — the canonical map: repo layout, the cleanup pipeline,
  Bouncer/flywheel status, and key commands.
- [`ml/DESIGN.md`](ml/DESIGN.md) — the Bouncer's design: the label scheme, data
  contract, metrics, and the ship gate.
- The app is Swift + SwiftUI (macOS), built with XcodeGen; the ML side is Python
  under `ml/`.

## Contributing

Pull up a stool. Issues and PRs are welcome — bug fixes, new writing modes, better
polish, model work, all of it. Read `PROJECT.md` and `AGENTS.md` first for the lay
of the land and the house rules (chiefly: the Bouncer only ever deletes, and flywheel
data never gets an upload path).

## License

[Apache-2.0](LICENSE). Third-party dependencies, bundled fonts, and downloaded
models follow their own upstream licenses — see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the full attributions.
