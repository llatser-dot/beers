# Beers

Private macOS push-to-talk dictation. Hold the hotkey, speak, release — transcript pastes into the active app.

**Project folder:** `~/Projects/Llatser.Listen`  
**Installed app:** `/Applications/Beers.app` (only copy that should exist)

## Features

- Local Parakeet v3 multilingual and Parakeet v2 English transcription via FluidAudio
- Push-to-talk hotkey (configurable)
- Auto-paste via Accessibility
- Flow-style listening HUD
- Transcript polish + optional local AI rewrite
- Mic and “Suppress Mac audio” only while the hotkey is held

## Requirements

- macOS 14+
- Apple Silicon recommended
- Xcode + XcodeGen

## Daily install (keeps permissions)

Use the agent/dev installer so signing stays stable and TCC grants survive updates:

```sh
./scripts/agent-install.sh
```

That script:

1. Builds from this repo
2. Signs with your Apple Development identity (not ad-hoc)
3. Installs only to `/Applications/Beers.app`
4. Deletes ghost build copies that confuse System Settings

One-time: grant Microphone, Input Monitoring, and Accessibility for the `/Applications` app. If a toggle is already ON but the app still shows denied, use **Relaunch to apply grants** in Settings.

## Release install

```sh
./scripts/release-check.sh
./install.sh
```

Run the release check before tagging or uploading a GitHub download. It builds
the same universal Release configuration and verifies both Mac architectures
and required app metadata.

## First-run models

Parakeet models download on first use to:

```text
~/Library/Application Support/FluidAudio/Models/
```

## Layout

```text
Llatser.Listen/
  LlatserListen/          Swift sources
  scripts/agent-install.sh
  install.sh
  project.yml
  README.md
```

## License

Apache-2.0. Third-party dependencies and downloaded models follow their upstream licenses.
