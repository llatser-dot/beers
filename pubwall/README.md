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
6-digit `code`, and a 15-minute expiry — created only during a claim/recover.
Codes stop working at expiry; rows are deleted on use or opportunistically on a
later registration/claim/recovery write.

Throttle rows in `rate_events`: a coarse **bucket label** (a secretly salted,
truncated IP hash or a user id) and a timestamp. No raw IP, no content — stale
rows are purged opportunistically on later registration/claim/recovery writes.

### What is *never* present — by construction, not by policy

There is **no column** for, and **no endpoint that accepts**:

- ❌ transcripts / the text of any dictation
- ❌ audio
- ❌ any content of what you said, ever

You can verify this by absence: grep the schema and the router — there is nowhere
to put a transcript and no route that reads one. The Pub Wall client sends only
two numbers per batch; this service never receives what you dictated. A separately
configured remote rewrite endpoint has its own explicit consent boundary in the app.

### Retention

- `users` rows persist while your handle exists on the wall.
- `pending_claims` codes are valid for at most 15 minutes and are deleted on use;
  expired rows are removed opportunistically on later writes and may physically
  remain longer if the service is idle.
- `rate_events` stop counting after the 1-hour throttle window; stale rows are
  removed opportunistically on later writes and may physically remain longer if
  the service is idle.

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
| POST | `/api/backfill` | Bearer | one-time import of retained local history, only while verified server totals are zero (max 1,000 pours / 250,000 words) |
| GET  | `/api/leaderboard?limit=50` | — | ranked `[{rank, username, words, pints, streakDays}]` + `{totalPints, totalWords}` |
| GET  | `/api/username-available?username=name` | — | validate and check a handle without reserving it |
| GET  | `/api/me` | Bearer | your own row |
| DELETE | `/api/me` | Bearer | leave the wall and delete the user, pending claims and private email |
| POST | `/api/claim` | Bearer | `{email}` → email a 6-digit code (501 if email not enabled) |
| POST | `/api/claim/verify` | Bearer | `{code}` → mark email verified (501 if email not enabled) |
| POST | `/api/recover` | — | `{email, username}` → **initiate only**; emails a single-use code on a match. Valid match, no-match, matched-account throttle, and email-disabled paths share the same generic 200; malformed input is 400 and the IP throttle is 429. Never returns a token. |
| POST | `/api/recover/verify` | — | `{email, username, code}` → checks + consumes the code, then rotates and returns a fresh `deviceToken` (400 generic on any bad/expired/wrong input; 501 if email not enabled) |

### Guardrails
- **Username:** 3–20 chars, letters/numbers/`_ . -` (not on the ends), case-insensitively
  unique, obvious-slur blocklist.
- **Verification gate:** unverified registrations never appear on the public wall
  and cannot upload counts. Abandoned unverified registrations are released after
  roughly 24 hours by opportunistic cleanup.
- **Empty batches rejected:** a `/api/pours` batch with `pours < 1` is rejected `400`
  — it represents no dictation and must not touch totals or keep a streak alive.
- **Caps:** 25,000 words/day and 400 pours/day per user; implausible single batches
  (e.g. `words=999999`) are rejected `422`.
- **Historical import:** `/api/backfill` is a separate one-time write for a newly
  verified account whose server totals are still exactly zero. It is capped to
  the native app's retained 1,000 pours and never affects current-day/streak data.
- **Rate limit (atomic):** ~1 accepted `/api/pours` per minute per token (`429`
  otherwise). The limit and the counter update are one conditional `UPDATE ... WHERE`
  checked by affected-rows, so concurrent requests cannot both slip through.
- **Email abuse controls:** at most 3 verification emails and 10 claim-code
  attempts per account per hour. Recovery has separate per-IP and per-account
  limits; successful account deletion also removes its account throttle rows.
- **Registration throttle:** best-effort ~5 registrations/hour per coarse ip-hash
  (`429`). See the limitations note below.
- **Recovery throttle:** best-effort ~3/hour per coarse ip-hash on *both*
  `/api/recover` and `/api/recover/verify`, plus ~3/hour per matched account.
- **Generic errors:** unexpected server exceptions return `500 {"error":"internal","incident":"<id>"}`
  — the internal message is logged server-side under that incident id and never
  sent to the client.
- **CORS:** public GETs are readable from anywhere; POSTs/DELETE accept any origin
  (the native app calls them) and are protected by the caps + Bearer token above.

> **Throttle limitations (by design, best-effort):** the registration/claim/recovery
> throttles bucket on a salted hash of the source IP. Users behind the same NAT or
> corporate proxy share a bucket (may over-limit); an attacker who can rotate IPs
> (botnet, IPv6, VPN) can evade it. It is a speed-bump against casual abuse, not a
> hard security boundary. There is also a small check-then-insert race under
> extreme concurrency. The *pours* rate limit, by contrast, is enforced atomically
> in SQL and is not best-effort.

## Email (claim / recover) ships dark

If no `RESEND_API_KEY` secret is configured, claim, claim verification, and
recovery verification return `501 {"error":"claiming not enabled yet"}`;
recovery initiation still returns its generic 200. The leaderboard works fully.
To enable email:

```sh
wrangler secret put RESEND_API_KEY
wrangler secret put RESEND_FROM   # optional, e.g. "Beers <newsletter@yourdomain>"
```

## Develop / deploy

```sh
npm ci                                               # reproducible install from package-lock.json
wrangler d1 create beers-pubwall                    # once; put the id in wrangler.toml
wrangler d1 execute beers-pubwall --remote --file=./schema.sql   # idempotent; creates rate_events too
openssl rand -hex 32 | wrangler secret put IP_HASH_SALT          # required; no public fallback
wrangler deploy
```

(`npm install` also works, but `npm ci` installs the exact, committed
`package-lock.json` for a reproducible build.)

Authenticate Wrangler with `wrangler login` or a scoped Cloudflare API token.
Never put Cloudflare or Resend credentials in this repository; local `.env*` and
`.dev.vars*` files are ignored, and `.dev.vars.example` contains placeholders only.

Database: **`beers-pubwall`** (D1, id `67ff7e23-b935-42c7-a702-b0cb720b5cb9`).
