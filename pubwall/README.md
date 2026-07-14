# Beers — Pub Wall API

The opt-in community leaderboard for [Beers](https://github.com/llatser-dot/beers),
the free, open-source macOS dictation app. A *pour* is one dictation; every
**1,000 words pulls a pint**. Opt in from the app and your pints climb the wall.

**This code lives in the open-source repo on purpose.** You can read exactly what
the server sees — because the whole product is a privacy promise, and a promise
you can't inspect is just marketing.

## The complete data boundary

This is the whole, honest boundary — everything that crosses the wire, everything
stored, everything that is never present, and who else can see any of it.

### What this server *receives* on a request

- A **bearer device token** (on the authenticated endpoints) — its hash is what
  identifies your row.
- Two **integers per pour batch**: `words` and `pours`. Nothing else.
- An **email address** — *only* on `/api/claim` and `/api/recover*`, and *only*
  because you typed one in.
- **Standard HTTP metadata that every web request carries**, handled by
  Cloudflare's edge before our code runs: your **source IP address**, `User-Agent`,
  and TLS/connection details. Cloudflare (our infrastructure provider) can see
  these as the network operator. Our code reads only `CF-Connecting-IP`, and only
  to derive a **salted, truncated hash** for the abuse throttle — the raw IP is
  never written to our database.

### What this server *persists* (see [`schema.sql`](./schema.sql) — that file is the whole truth)

Per opted-in user, in `users`:

- `username` — the handle you chose
- `words`, `pours` — running totals
- `streak_days`, `last_pour_date` — your consecutive-day streak
- `token_hash` — the **SHA-256 hash** of your device token (the raw token is never stored)
- `email` — **only** if you explicitly claim your handle, and `NULL` for everyone else
- `created_at` and a few operational counters (`last_pour_at`, `today_date`,
  `words_today`, `pours_today`) for rate-limiting and daily caps

Short-lived rows in `pending_claims`: a `user_id`, the `email` you entered, a
6-digit `code`, and a 15-minute expiry — created only during a claim/recover and
deleted on use or expiry (purged opportunistically on writes).

Throttle rows in `rate_events`: a coarse **bucket label** (a salted ip-hash or a
user id) and a timestamp. No IP, no content — purged once older than one hour.

### What is *never* present — by construction, not by policy

There is **no column** for, and **no endpoint that accepts**:

- ❌ transcripts / the text of any dictation
- ❌ audio
- ❌ any content of what you said, ever

You can verify this by absence: grep the schema and the router — there is nowhere
to put a transcript and no route that reads one. The app sends only two numbers
per batch. Nothing you dictate leaves your Mac.

### Retention

- `users` rows persist while your handle exists on the wall.
- `pending_claims` codes live at most 15 minutes and are deleted on use.
- `rate_events` are deleted once older than the 1-hour throttle window.

### Third parties

- **Cloudflare** hosts the Worker and D1 database and, as the network operator,
  sees standard request metadata including your source IP (as above).
- **Resend** (email provider) sees the **email address and the verification code**
  for a claim/recover message — *only when email is enabled* (a `RESEND_API_KEY`
  is configured). With no key, the email endpoints ship dark and Resend sees
  nothing. Resend never receives any counts, handle totals, or dictation content
  beyond what the short code email contains.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/register` | — | `{username}` → `{userId, deviceToken}` (token shown once; only its hash is stored) |
| POST | `/api/pours` | Bearer | `{words, pours}` → increment totals + update streak (capped & rate-limited) |
| GET  | `/api/leaderboard?limit=50` | — | ranked `[{rank, username, words, pints, streakDays}]` + `{totalPints, totalWords}` |
| GET  | `/api/me` | Bearer | your own row |
| POST | `/api/claim` | Bearer | `{email}` → email a 6-digit code (501 if email not enabled) |
| POST | `/api/claim/verify` | Bearer | `{code}` → mark email verified (501 if email not enabled) |
| POST | `/api/recover` | — | `{email, username}` → **initiate only**; emails a single-use code on a match. Response is a **generic 200 in every path** (match, no-match, throttled, or email-disabled) — no account-existence oracle and no feature-state leak. Never returns a token. |
| POST | `/api/recover/verify` | — | `{email, username, code}` → checks + consumes the code, then rotates and returns a fresh `deviceToken` (400 generic on any bad/expired/wrong input; 501 if email not enabled) |

### Guardrails
- **Username:** 3–20 chars, letters/numbers/`_ . -` (not on the ends), case-insensitively
  unique, obvious-slur blocklist.
- **Empty batches rejected:** a `/api/pours` batch with `pours < 1` is rejected `400`
  — it represents no dictation and must not touch totals or keep a streak alive.
- **Caps:** 25,000 words/day and 400 pours/day per user; implausible single batches
  (e.g. `words=999999`) are rejected `422`.
- **Rate limit (atomic):** ~1 accepted `/api/pours` per minute per token (`429`
  otherwise). The limit and the counter update are one conditional `UPDATE ... WHERE`
  checked by affected-rows, so concurrent requests cannot both slip through.
- **Registration throttle:** best-effort ~5 registrations/hour per coarse ip-hash
  (`429`). See the limitations note below.
- **Recovery throttle:** best-effort ~3/hour per coarse ip-hash on *both*
  `/api/recover` and `/api/recover/verify`, plus ~3/hour per matched account.
- **Generic errors:** unexpected server exceptions return `500 {"error":"internal","incident":"<id>"}`
  — the internal message is logged server-side under that incident id and never
  sent to the client.
- **CORS:** `GET /api/leaderboard` is readable from anywhere; POSTs accept any origin
  (the native app calls them) and are protected by the caps + Bearer token above.

> **Throttle limitations (by design, best-effort):** the registration/recovery
> throttles bucket on a salted hash of the source IP. Users behind the same NAT or
> corporate proxy share a bucket (may over-limit); an attacker who can rotate IPs
> (botnet, IPv6, VPN) can evade it. It is a speed-bump against casual abuse, not a
> hard security boundary. There is also a small check-then-insert race under
> extreme concurrency. The *pours* rate limit, by contrast, is enforced atomically
> in SQL and is not best-effort.

## Email (claim / recover) ships dark

If no `RESEND_API_KEY` secret is configured, the three email endpoints return
`501 {"error":"claiming not enabled yet"}` — the leaderboard still works fully.
To enable:

```sh
wrangler secret put RESEND_API_KEY
wrangler secret put RESEND_FROM   # optional, e.g. "Beers <newsletter@yourdomain>"
```

## Develop / deploy

```sh
npm ci                                               # reproducible install from package-lock.json
wrangler d1 create beers-pubwall                    # once; put the id in wrangler.toml
wrangler d1 execute beers-pubwall --remote --file=./schema.sql   # idempotent; creates rate_events too
wrangler deploy
```

(`npm install` also works, but `npm ci` installs the exact, committed
`package-lock.json` for a reproducible build.)

Auth uses the Cloudflare Global API Key via `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL`.

Database: **`beers-pubwall`** (D1, id `67ff7e23-b935-42c7-a702-b0cb720b5cb9`).
