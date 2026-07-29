# Security policy

## Supported versions

Security fixes target the latest published release and `main`. Older release
lines are not maintained separately.

## Reporting a vulnerability

Please use
[GitHub private vulnerability reporting](https://github.com/llatser-dot/beers/security/advisories/new).
Do not open a public issue for a vulnerability that could expose dictations,
audio, credentials, signing material or another user’s data.

Include:

- the affected version or commit;
- macOS and hardware version;
- a concise reproduction;
- impact and any known workaround;
- logs or screenshots with private text removed.

The maintainer aims to acknowledge complete reports within five working days.
Please allow time for a fix and release before public disclosure.

## Security boundaries

The highest-risk areas are:

- Microphone, Accessibility and Input Monitoring permission handling;
- pasteboard and selected-text access;
- local pour, correction and benchmark storage;
- Pub Wall authentication and aggregate-count uploads;
- update signing, notarisation and `appcast.xml`;
- any change that could introduce a remote transcript or audio path.

Never include real dictations, private vocabulary, client names, credentials or
signing material in an issue, pull request, screenshot or test fixture.
