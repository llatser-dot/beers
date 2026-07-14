<div align="center">

# 🍺 Beers

**Free, open-source push-to-talk dictation for macOS.**

Hold a key, say the thing, let go — the words land wherever your cursor is.
On-device speech recognition. No cloud, no account, no subscription, no tab to settle.

</div>

---

Beers turns your voice into text in any app on your Mac. Hold your pour key, talk,
release — the transcript pastes straight at the cursor, whether that's Mail, Slack,
a terminal, or your editor. In Beers-speak, one dictation is a **pour**, and every
1,000 words you pour **pulls a pint**.

Everything that matters runs **on your machine**. Transcription is
[Parakeet v3](https://github.com/FluidInference/FluidAudio) (multilingual) or v2
(English) via FluidAudio, executed locally on the Apple Neural Engine. Your voice
never touches a server.

## Why Beers

- **On-device by default.** Speech-to-text is local. There is no API to call, no
  key to paste, nothing to sign up for. Delete the app and it's all gone.
- **Optional AI cleanup — also local.** Beyond the built-in rule polisher, Beers can
  tidy a pour with an on-device LLM: Apple's on-device model, or your own
  [Ollama](https://ollama.com) (`gemma4` by default). The two race on a shared
  deadline; the first acceptable rewrite wins, and a keep-ratio guard rejects
  anything that trims too hard. If you have no model, Beers just serves the
  rule-polished text. Nothing leaves the Mac either way.
- **The Bouncer — a model that trains itself on you.** Beers ships an on-device
  ~10 ms disfluency tagger that removes fillers, stutters, and false starts. It can
  only *delete* words, never write them, so it can't hallucinate or answer your
  dictation. Today it runs in **shadow mode**: it predicts and logs, but does not
  touch your text. Meanwhile it learns from *your* pours locally (see
  [the flywheel](#the-flywheel--how-the-bouncer-learns)) and retrains on your own
  speech. It only ever goes live if a retrained version **passes a precision exam
  on your data** — DELETE precision ≥ 0.98 on a frozen gold set *and* held-out real
  dictation. A false deletion is the cardinal sin, so when it's unsure, it keeps.
  We're being honest: as of this release the gate has not been met, and the Bouncer
  stays in shadow. Activation is a deliberate, reviewed file-swap — never a silent
  auto-update. The full story is in [`ml/DESIGN.md`](ml/DESIGN.md).
- **It learns your words.** Beers watches the keyboard corrections you make in the
  couple of minutes after a paste and turns them into vocabulary suggestions — so
  "plan watch" becomes "PlanWatch" next time, without you teaching it by hand.
- **Private, actually.** Verbatim speech data never leaves your Mac. There is no
  telemetry. The training-data directory is gitignored — even the author's own
  dictation isn't in this repo — and the on-device flywheel has no upload path,
  ever.

## Screenshots

**The Taproom** — every pour you've served, searchable, grouped by app, with your
streak and Keepers (the pours worth saving).

![Beers Taproom — searchable dictation history](docs/screenshots/taproom.png)

**Brew Controls** — one screen, everything on tap: pour key, where the words land,
sounds, the listening pill's position, and your local brew engine.

![Beers Brew Controls settings](docs/screenshots/brew-controls.png)

**The Little Black Book** — every learning feature on one switchboard, with the
promise printed right on it: everything stays on this Mac.

![Beers privacy controls — The Little Black Book](docs/screenshots/little-black-book.png)

## Features

| Feature | What it does |
|---|---|
| **Push-to-talk** | Hold the pour key (Left Command ⌘ by default, configurable), speak, release. Text pastes at the cursor. |
| **Command Mode** | Hold **Shift + pour key** over selected text, say the edit ("make this a bullet list"), and the local model rewrites the selection in place. |
| **Writing modes** | *Auto* (matches the active app), *Clean* (neutral written English), *Message* (short and conversational), *Command* (direct instructions for terminals, editors, and coding agents). |
| **The Taproom** | Searchable history of every pour, grouped by day and app, with Keepers (starred), the drip tray (trash), and your daily streak. |
| **Listening HUD** | A compact "pour" pill (position configurable, notch-friendly) shows the live state — taking order → pouring → settling → served — plus your running pint count. |
| **Vocabulary** | The Brewer's Dictionary maps what Beers *heard* to what you *meant*, and auto-suggests fixes harvested from your keyboard corrections. |
| **Pint leaderboard** | *(Coming soon — site not live yet.)* Opt in and 1,000 words = 1 pint on the community Pub Wall. Only a username and word count would ever leave the Mac. |

## Install from source

Right now, **building from source is the only supported install path** — there is
no notarized download yet (see [Gatekeeper](#a-note-on-gatekeeper) below). It's a
one-command build once you have the tools.

### Requirements

- **macOS 14.0 or later** (Sonoma+).
- **Apple Silicon** (M1 or newer). Parakeet runs on the Neural Engine.
- **Xcode Command Line Tools** — `xcode-select --install`. (A full Xcode install is
  fine too; the build uses `xcodebuild`.) You need a working Xcode toolchain with a
  team signed in, *or* let the installer mint a throwaway local certificate for you.
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
certificate). Without one, `LLATSER_ALLOW_LOCAL_SIGNING=1` tells it to build and
sign with a **stable local identity** instead — the installer creates that identity
automatically on a fresh machine, so you don't need any Apple certificate to get
running. It builds a Release binary, installs to `/Applications/Beers.app`, cleans
up stray build copies, and launches the app.

> The local signing identity is deliberate: it keeps your macOS privacy grants
> stable across rebuilds. Ad-hoc signing (`codesign -s -`) would re-key permissions
> on every build and force you to re-grant them constantly — Beers never does that.

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

## The flywheel — how the Bouncer learns

Every pour and every keyboard correction is logged **locally only**, to
`~/Library/Application Support/Beers/flywheel.jsonl` (outside this repo, never
uploaded). A `launchd` standing loop periodically checks whether enough real data
has accumulated and, if so, retrains the Bouncer on *your* speech, scores it against
the frozen gold exam plus held-out real dictation, and writes a report. One honest
caveat: the committed reference loop (`ml/standing-loop/`) is the author's personal
automation and uses a cloud LLM agent (Claude) to label the training data — so
running *that* loop sends flywheel text to Anthropic. The app itself never runs it;
nothing retrains unless you set it up yourself, and a fully on-device trainer is
the roadmap item that closes this gap. It **never**
activates the model and **never** commits anything — going live is a manual,
reviewed step. Toggles for logging, correction-watching, and shadow prediction all
live in the app (and all default on; turn them off any time).

If you'd rather not participate at all, switch off flywheel logging in the app — the
dictation still works exactly the same, minus the self-improvement.

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

[Apache-2.0](LICENSE). Third-party dependencies and downloaded models follow their
own upstream licenses.
