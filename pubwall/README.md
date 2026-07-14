# Beers — Pub Wall API

The opt-in community leaderboard for [Beers](https://github.com/llatser-dot/beers),
the free, open-source macOS dictation app. A *pour* is one dictation; every
**1,000 words pulls a pint**. Opt in from the app and your pints climb the wall.

**This code lives in the open-source repo on purpose.** You can read exactly what
the server sees — because the whole product is a privacy promise, and a promise
you can't inspect is just marketing.

## What the server sees — and everything it does not

The server stores, per opted-in user (see [`schema.sql`](./schema.sql)):

- `username` — the handle you chose
- `words`, `pours` — running totals
- `streak_days`, `last_pour_date` — your consecutive-day streak
- `token_hash` — the **SHA-256 hash** of your device token (the raw token is never stored)
- `email` — **only** if you explicitly claim your handle, and `NULL` for everyone else
- `created_at` and a few operational counters for rate-limiting

That is the complete list. There is **no column** for, and no endpoint that accepts:

- ❌ transcripts / the text of any dictation
- ❌ audio
- ❌ any content of what you said, ever

The app sends only two numbers per batch: `words` and `pours`. Nothing you dictate
leaves your Mac. Email is the single exception and it only exists after *you* type
one in to claim your handle so you can recover it on a new machine.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/register` | — | `{username}` → `{userId, deviceToken}` (token shown once; only its hash is stored) |
| POST | `/api/pours` | Bearer | `{words, pours}` → increment totals + update streak (capped & rate-limited) |
| GET  | `/api/leaderboard?limit=50` | — | ranked `[{rank, username, words, pints, streakDays}]` + `{totalPints, totalWords}` |
| GET  | `/api/me` | Bearer | your own row |
| POST | `/api/claim` | Bearer | `{email}` → email a 6-digit code (501 if email not enabled) |
| POST | `/api/claim/verify` | Bearer | `{code}` → mark email verified (501 if email not enabled) |
| POST | `/api/recover` | — | `{email, username}` → rotate + return a fresh `deviceToken` (501 if email not enabled) |

### Guardrails
- **Username:** 3–20 chars, letters/numbers/`_ . -` (not on the ends), case-insensitively
  unique, obvious-slur blocklist.
- **Caps:** 25,000 words/day and 400 pours/day per user; implausible single batches
  (e.g. `words=999999`) are rejected `422`.
- **Rate limit:** ~1 accepted `/api/pours` per minute per token (`429` otherwise).
- **CORS:** `GET /api/leaderboard` is readable from anywhere; POSTs accept any origin
  (the native app calls them) and are protected by the caps + Bearer token above.

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
npm install
wrangler d1 create beers-pubwall                    # once; put the id in wrangler.toml
wrangler d1 execute beers-pubwall --remote --file=./schema.sql
wrangler deploy
```

Auth uses the Cloudflare Global API Key via `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL`.

Database: **`beers-pubwall`** (D1, id `67ff7e23-b935-42c7-a702-b0cb720b5cb9`).
