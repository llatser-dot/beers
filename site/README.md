# Beers public site

This directory contains the first tracked public website surface for Beers. It is
plain HTML, CSS and JavaScript: there is no build step, package manager or client
framework.

## Local preview

Serve the **repository root**, not `site/`, because the page deliberately reuses
the app's tracked fonts, brand mark and screenshots without copying binaries:

```sh
python3 -m http.server 4173
```

Then open `http://localhost:4173/site/`.

Opening `site/index.html` directly also renders in modern browsers, but a local
HTTP server is the useful check because it exercises the live Pub Wall request.

## Asset-root assumptions

The page references these existing repository paths relative to `site/`:

- `LlatserListen/Resources/Fonts/`
- `LlatserListen/Resources/BrandAssets/logo-b-small.png`
- `docs/screenshots/`

A deployment must therefore publish the repository tree with those paths intact,
or rewrite/copy the referenced assets as an explicit packaging step. No such
deployment packaging exists on this branch. The page makes no assumption about a
production hostname.

## Deployment boundary

This branch creates and validates the website source only. It does **not**:

- deploy or configure a host, domain, redirects, analytics or cookies;
- create a notarised app artefact or a download endpoint;
- add Homebrew distribution;
- add the native app client for Pub Wall opt-in;
- change the live Pub Wall API.

The primary CTA therefore links to the source install guide. The page queries the
public read-only leaderboard endpoint in the browser and has explicit loading,
empty and failure states. It never substitutes mock people or counters.

## Launch-truth checklist

- [x] Repository links use `https://github.com/llatser-dot/beers`.
- [x] Primary CTA says **Build from source** / **View install guide**.
- [x] No notarised download or Homebrew claim.
- [x] Requirements say Apple Silicon and macOS 14+.
- [x] Default hotkey says Left Command and is described as configurable.
- [x] Local dictation is separated from optional remote rewriting.
- [x] Pub Wall counts are separated from dictation content and Cloudflare's
  standard request metadata is acknowledged.
- [x] Pub Wall app opt-in is clearly marked **coming soon**.
- [x] Bouncer is described as shadow-only after failed v1/v2 gates.
- [x] The operator-run retraining loop and its Anthropic boundary are explicit.
- [x] Live Pub Wall empty/failure states show no invented users or totals.
- [ ] Signed, notarised and stapled release exists.
- [ ] Fresh-install, first-model-download and permission flows are verified on a
  clean Mac.
- [ ] Production hosting, cache policy, CSP and final canonical URL are chosen.
- [ ] Native Pub Wall opt-in exists and passes privacy and batching tests.

When the first notarised release is real and independently verified, the build CTA
can be promoted to a download CTA. Until then, do not weaken this boundary.
