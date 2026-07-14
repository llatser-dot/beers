/**
 * Beers — Pub Wall API (Cloudflare Worker + D1)
 *
 * PRIVACY CONTRACT (the whole brand):
 *   This server only ever sees a username, running word/pour counts, and a
 *   streak. It NEVER sees transcripts. It NEVER sees audio. It only ever stores
 *   an email address when a user *explicitly* claims their handle. Read the
 *   schema (schema.sql) — there is nowhere to put anything else.
 */

export interface Env {
  DB: D1Database;
  RESEND_API_KEY?: string;
  RESEND_FROM?: string; // e.g. "Beers <newsletter@example.com>"
  IP_HASH_SALT?: string; // optional salt for the coarse abuse-throttle ip-hash
}

// ------------------------------------------------------------------ tunables
const USERNAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.\-]{1,18}[A-Za-z0-9]$/; // 3–20, alnum + _ . -, not edge-punct
const MAX_WORDS_PER_DAY = 25_000;
const MAX_POURS_PER_DAY = 400;
// A single batch can never be larger than a plausible full day of talking.
// ~200 wpm * 60 * 24 ≈ 288k theoretical ceiling; we clamp far below at the
// daily cap, so any single batch above MAX_WORDS_PER_DAY is rejected outright.
const MAX_WORDS_PER_BATCH = MAX_WORDS_PER_DAY;
const MAX_POURS_PER_BATCH = MAX_POURS_PER_DAY;
const RATE_LIMIT_MS = 60_000; // ~1 accepted /api/pours per minute per token
const CODE_TTL_MS = 15 * 60 * 1000;

// Abuse throttles (best-effort; see rate_events in schema.sql).
const THROTTLE_WINDOW_MS = 60 * 60 * 1000; // 1 hour
const MAX_REGISTRATIONS_PER_WINDOW = 5; // per coarse ip-hash / hour
const MAX_RECOVERS_PER_WINDOW = 3; // per coarse ip-hash / hour (initiate)
const MAX_RECOVER_VERIFY_PER_WINDOW = 3; // per coarse ip-hash / hour (verify)
const MAX_RECOVER_PER_ACCOUNT_PER_WINDOW = 3; // per matched account / hour

// Obvious-slur blocklist (substring, case-insensitive). Deliberately short —
// the goal is to keep the wall free of the unambiguous ones, not to moderate.
const PROFANITY = [
  'nigger', 'nigga', 'faggot', 'chink', 'spic', 'kike', 'retard', 'tranny',
  'cunt', 'coon', 'wetback', 'paki', 'gook', 'dyke',
];

// ------------------------------------------------------------------ helpers
const enc = new TextEncoder();

function json(data: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders(), ...extraHeaders },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    'Access-Control-Max-Age': '86400',
  };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', enc.encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomTokenHex(bytes = 32): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return [...buf].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function sixDigitCode(): string {
  return String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, '0');
}

function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10); // YYYY-MM-DD
}

function utcDateMinusOne(today: string): string {
  const d = new Date(today + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

function bearer(req: Request): string | null {
  const h = req.headers.get('Authorization') || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

// Coarse, privacy-preserving throttle key from the source IP. We never store the
// raw IP — only a salted, truncated hash — and only to bucket abuse. See the
// limitations note in README (shared IPs collide; rotating IPs can evade).
async function ipHash(req: Request, env: Env): Promise<string> {
  const ip = req.headers.get('CF-Connecting-IP') || 'unknown';
  const h = await sha256Hex(`${env.IP_HASH_SALT || 'beers-pubwall'}:${ip}`);
  return h.slice(0, 16);
}

interface UserRow {
  id: number;
  username: string;
  token_hash: string;
  words: number;
  pours: number;
  streak_days: number;
  last_pour_date: string | null;
  email: string | null;
  email_verified: number;
  created_at: number;
  last_pour_at: number | null;
  today_date: string | null;
  words_today: number;
  pours_today: number;
}

async function userFromToken(env: Env, token: string | null): Promise<UserRow | null> {
  if (!token) return null;
  const hash = await sha256Hex(token);
  return env.DB.prepare('SELECT * FROM users WHERE token_hash = ?').bind(hash).first<UserRow>();
}

// Best-effort throttle: count recent events in a bucket; if under the cap, record
// this one and allow. There is a small check-then-insert race under extreme
// concurrency (documented in README) — acceptable for an abuse speed-bump.
async function throttle(env: Env, bucket: string, max: number, windowMs: number, now: number): Promise<boolean> {
  const since = now - windowMs;
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS c FROM rate_events WHERE bucket = ? AND created_at > ?'
  )
    .bind(bucket, since)
    .first<{ c: number }>();
  if ((row?.c ?? 0) >= max) return true; // throttled
  await env.DB.prepare('INSERT INTO rate_events (bucket, created_at) VALUES (?, ?)')
    .bind(bucket, now)
    .run();
  return false;
}

// Opportunistic purge of expired verification codes and stale throttle rows.
// Called on lower-frequency write paths; failures are swallowed.
async function purgeExpired(env: Env, now: number): Promise<void> {
  try {
    await env.DB.batch([
      env.DB.prepare('DELETE FROM pending_claims WHERE expires_at < ?').bind(now),
      env.DB.prepare('DELETE FROM rate_events WHERE created_at < ?').bind(now - THROTTLE_WINDOW_MS),
    ]);
  } catch {
    /* best-effort */
  }
}

// ------------------------------------------------------------------ router
export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders() });

    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    try {
      if (path === '/' || path === '/api' || path === '/api/health') {
        return json({ ok: true, service: 'beers-pubwall', privacy: 'username + counts + streak only; never transcripts or audio' });
      }
      if (req.method === 'POST' && path === '/api/register') return register(req, env);
      if (req.method === 'POST' && path === '/api/pours') return pours(req, env);
      if (req.method === 'GET' && path === '/api/leaderboard') return leaderboard(req, env, url);
      if (req.method === 'GET' && path === '/api/me') return me(req, env);
      if (req.method === 'POST' && path === '/api/claim') return claim(req, env);
      if (req.method === 'POST' && path === '/api/claim/verify') return claimVerify(req, env);
      if (req.method === 'POST' && path === '/api/recover') return recover(req, env);
      if (req.method === 'POST' && path === '/api/recover/verify') return recoverVerify(req, env);

      return json({ error: 'not found' }, 404);
    } catch (err: any) {
      // Never leak internal exception text to clients. Log server-side with an
      // incident id the caller can quote; return only that id.
      const incident = randomTokenHex(8);
      console.error(`[incident ${incident}] ${req.method} ${path}:`, err?.stack || err?.message || err);
      return json({ error: 'internal', incident }, 500);
    }
  },
};

// ------------------------------------------------------------------ endpoints

async function parseBody(req: Request): Promise<any> {
  try {
    return await req.json();
  } catch {
    return {};
  }
}

async function register(req: Request, env: Env): Promise<Response> {
  const now = Date.now();
  await purgeExpired(env, now);

  // Best-effort per-ip-hash registration throttle (abuse speed-bump).
  const bucket = `register:${await ipHash(req, env)}`;
  if (await throttle(env, bucket, MAX_REGISTRATIONS_PER_WINDOW, THROTTLE_WINDOW_MS, now)) {
    return json({ error: 'too many registrations, try again later' }, 429, { 'Retry-After': '3600' });
  }

  const body = await parseBody(req);
  const username = typeof body.username === 'string' ? body.username.trim() : '';

  if (username.length < 3 || username.length > 20) {
    return json({ error: 'username must be 3–20 characters' }, 400);
  }
  if (!USERNAME_RE.test(username)) {
    return json({ error: 'username must be letters, numbers, and _ . - (not on the ends)' }, 400);
  }
  const lower = username.toLowerCase();
  if (PROFANITY.some((w) => lower.includes(w))) {
    return json({ error: 'username not allowed' }, 400);
  }

  const existing = await env.DB.prepare('SELECT id FROM users WHERE username = ? COLLATE NOCASE')
    .bind(username)
    .first<{ id: number }>();
  if (existing) return json({ error: 'username already taken' }, 409);

  const token = randomTokenHex(32);
  const tokenHash = await sha256Hex(token);

  try {
    const res = await env.DB.prepare(
      'INSERT INTO users (username, token_hash, created_at) VALUES (?, ?, ?)'
    )
      .bind(username, tokenHash, now)
      .run();
    const userId = res.meta.last_row_id;
    return json({ userId, deviceToken: token });
  } catch (err: any) {
    // UNIQUE race
    if (String(err?.message || err).toLowerCase().includes('unique')) {
      return json({ error: 'username already taken' }, 409);
    }
    throw err;
  }
}

async function pours(req: Request, env: Env): Promise<Response> {
  const user = await userFromToken(env, bearer(req));
  if (!user) return json({ error: 'unauthorized' }, 401);

  const body = await parseBody(req);
  const words = Number(body.words);
  const pourCount = Number(body.pours);

  if (!Number.isFinite(words) || !Number.isFinite(pourCount) ||
      !Number.isInteger(words) || !Number.isInteger(pourCount) ||
      words < 0 || pourCount < 0) {
    return json({ error: 'words and pours must be non-negative integers' }, 400);
  }

  // Reject empty/zero batches — a batch with no pours represents no dictation and
  // must never touch totals or (crucially) keep a streak alive.
  if (pourCount < 1) {
    return json({ error: 'empty batch rejected' }, 400);
  }

  // Per-batch plausibility (an absurd single batch, e.g. words=999999, dies here)
  if (words > MAX_WORDS_PER_BATCH || pourCount > MAX_POURS_PER_BATCH) {
    return json({ error: 'implausible batch rejected' }, 422);
  }

  const now = Date.now();
  const today = utcDate(now);
  const yesterday = utcDateMinusOne(today);
  const rateThreshold = now - RATE_LIMIT_MS;

  // Single atomic conditional UPDATE. It enforces the per-token rate limit AND
  // the daily caps in the WHERE clause and rolls the per-day counters + streak
  // in one statement, so two concurrent requests cannot both pass (the previous
  // read-then-write left a TOCTOU race). RHS expressions see the pre-update row.
  const res = await env.DB.prepare(
    `UPDATE users SET
        words = words + ?1,
        pours = pours + ?2,
        streak_days = CASE
          WHEN last_pour_date = ?3 THEN MAX(streak_days, 1)
          WHEN last_pour_date = ?4 THEN streak_days + 1
          ELSE 1 END,
        last_pour_date = ?3,
        last_pour_at = ?5,
        today_date = ?3,
        words_today = CASE WHEN today_date = ?3 THEN words_today + ?1 ELSE ?1 END,
        pours_today = CASE WHEN today_date = ?3 THEN pours_today + ?2 ELSE ?2 END
      WHERE id = ?6
        AND (last_pour_at IS NULL OR last_pour_at < ?7)
        AND (CASE WHEN today_date = ?3 THEN words_today + ?1 ELSE ?1 END) <= ?8
        AND (CASE WHEN today_date = ?3 THEN pours_today + ?2 ELSE ?2 END) <= ?9`
  )
    .bind(words, pourCount, today, yesterday, now, user.id, rateThreshold, MAX_WORDS_PER_DAY, MAX_POURS_PER_DAY)
    .run();

  if (!res.meta.changes) {
    // Nothing changed → either the rate limit or the daily cap blocked it.
    // Re-read (read-only, for messaging only) to pick the right 429 reason.
    const fresh = await env.DB.prepare('SELECT last_pour_at FROM users WHERE id = ?')
      .bind(user.id)
      .first<{ last_pour_at: number | null }>();
    if (fresh?.last_pour_at != null && now - fresh.last_pour_at < RATE_LIMIT_MS) {
      const retryMs = RATE_LIMIT_MS - (now - fresh.last_pour_at);
      return json({ error: 'slow down' }, 429, { 'Retry-After': String(Math.ceil(retryMs / 1000)) });
    }
    return json({ error: 'daily cap reached' }, 429);
  }

  // Return authoritative post-update totals.
  const updated = await env.DB.prepare('SELECT words, pours, streak_days FROM users WHERE id = ?')
    .bind(user.id)
    .first<{ words: number; pours: number; streak_days: number }>();
  const totalWords = updated?.words ?? user.words + words;
  const totalPours = updated?.pours ?? user.pours + pourCount;

  return json({
    ok: true,
    words: totalWords,
    pours: totalPours,
    pints: Math.floor(totalWords / 1000),
    streakDays: updated?.streak_days ?? user.streak_days,
  });
}

async function leaderboard(_req: Request, env: Env, url: URL): Promise<Response> {
  let limit = parseInt(url.searchParams.get('limit') || '50', 10);
  if (!Number.isFinite(limit) || limit < 1) limit = 50;
  if (limit > 200) limit = 200;

  const rows = await env.DB.prepare(
    'SELECT username, words, streak_days FROM users ORDER BY words DESC, id ASC LIMIT ?'
  )
    .bind(limit)
    .all<{ username: string; words: number; streak_days: number }>();

  const entries = (rows.results || []).map((r, i) => ({
    rank: i + 1,
    username: r.username,
    words: r.words,
    pints: Math.floor(r.words / 1000),
    streakDays: r.streak_days,
  }));

  const agg = await env.DB.prepare(
    'SELECT COALESCE(SUM(words),0) AS totalWords, COUNT(*) AS drinkers FROM users'
  ).first<{ totalWords: number; drinkers: number }>();

  const totalWords = agg?.totalWords ?? 0;
  const totalPints = Math.floor(totalWords / 1000);

  return json(
    { leaderboard: entries, totalPints, totalWords, drinkers: agg?.drinkers ?? 0 },
    200,
    { 'Cache-Control': 'public, max-age=60' }
  );
}

async function me(req: Request, env: Env): Promise<Response> {
  const user = await userFromToken(env, bearer(req));
  if (!user) return json({ error: 'unauthorized' }, 401);
  return json({
    userId: user.id,
    username: user.username,
    words: user.words,
    pours: user.pours,
    pints: Math.floor(user.words / 1000),
    streakDays: user.streak_days,
    lastPourDate: user.last_pour_date,
    emailVerified: !!user.email_verified,
    createdAt: user.created_at,
  });
}

// ---- email flows (ship dark when RESEND_API_KEY is not configured) ----

function emailEnabled(env: Env): boolean {
  return typeof env.RESEND_API_KEY === 'string' && env.RESEND_API_KEY.length > 0;
}

async function sendResendCode(env: Env, to: string, code: string, purpose: string): Promise<boolean> {
  const from = env.RESEND_FROM || 'Beers <newsletter@beers.llatser.dev>';
  const subject = purpose === 'recover' ? 'Recover your Beers handle' : 'Claim your Beers handle';
  const body =
    `Your Beers verification code is ${code}\n\n` +
    `It expires in 15 minutes. If you didn't ask for this, ignore this email.\n\n` +
    `— The Pub Wall. We only ever store your handle, your counts, and (now) this email. Never your words.`;
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ from, to, subject, text: body }),
  });
  return res.ok;
}

function validEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

async function claim(req: Request, env: Env): Promise<Response> {
  const user = await userFromToken(env, bearer(req));
  if (!user) return json({ error: 'unauthorized' }, 401);
  if (!emailEnabled(env)) return json({ error: 'claiming not enabled yet' }, 501);

  const now = Date.now();
  await purgeExpired(env, now);

  const body = await parseBody(req);
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  if (!validEmail(email)) return json({ error: 'valid email required' }, 400);

  const code = sixDigitCode();
  await env.DB.prepare('DELETE FROM pending_claims WHERE user_id = ? AND purpose = ?')
    .bind(user.id, 'claim')
    .run();
  await env.DB.prepare(
    'INSERT INTO pending_claims (user_id, email, code, purpose, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)'
  )
    .bind(user.id, email, code, 'claim', now, now + CODE_TTL_MS)
    .run();

  const sent = await sendResendCode(env, email, code, 'claim');
  if (!sent) return json({ error: 'could not send email' }, 502);
  return json({ ok: true, message: 'verification code sent' });
}

async function claimVerify(req: Request, env: Env): Promise<Response> {
  const user = await userFromToken(env, bearer(req));
  if (!user) return json({ error: 'unauthorized' }, 401);
  if (!emailEnabled(env)) return json({ error: 'claiming not enabled yet' }, 501);

  const body = await parseBody(req);
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!/^\d{6}$/.test(code)) return json({ error: 'valid 6-digit code required' }, 400);

  const now = Date.now();
  const pc = await env.DB.prepare(
    'SELECT * FROM pending_claims WHERE user_id = ? AND purpose = ? ORDER BY id DESC LIMIT 1'
  )
    .bind(user.id, 'claim')
    .first<{ id: number; email: string; code: string; expires_at: number }>();

  if (!pc || pc.code !== code) return json({ error: 'invalid code' }, 400);
  if (pc.expires_at < now) return json({ error: 'code expired' }, 400);

  await env.DB.prepare('UPDATE users SET email = ?, email_verified = 1 WHERE id = ?')
    .bind(pc.email, user.id)
    .run();
  await env.DB.prepare('DELETE FROM pending_claims WHERE user_id = ? AND purpose = ?')
    .bind(user.id, 'claim')
    .run();

  return json({ ok: true, emailVerified: true });
}

// ---- recovery: two-stage, oracle-free ----
//
// Stage 1 (/api/recover): initiate ONLY. Whether or not the (username, verified
// email) pair matches, the response is byte-identical — no account-existence
// oracle. On a match we store a single-use 15-min code and email it. There is
// NO token handed back here (the old flow returned one on match = takeover).
//
// Stage 2 (/api/recover/verify): supply {email, username, code}. Only a correct,
// unexpired, unconsumed code rotates the device token and returns a fresh one.

// Generic, byte-identical initiate response. Reused for every path so nothing —
// not a match, a no-match, a throttled account, or email being disabled — is
// distinguishable to the caller.
const RECOVER_GENERIC = { ok: true, message: 'if that handle and email match, a code has been emailed' };

async function recover(req: Request, env: Env): Promise<Response> {
  // When email is disabled we still return the generic 200 (never 501) so the
  // initiate endpoint reveals nothing at all — the dark state is invisible here.
  // Actual recovery is gated at /api/recover/verify, which is honestly 501-dark.
  if (!emailEnabled(env)) return json(RECOVER_GENERIC);

  const now = Date.now();
  await purgeExpired(env, now);

  // Per-ip-hash throttle on initiate.
  const ipBucket = `recover:${await ipHash(req, env)}`;
  if (await throttle(env, ipBucket, MAX_RECOVERS_PER_WINDOW, THROTTLE_WINDOW_MS, now)) {
    return json({ error: 'too many recovery attempts, try again later' }, 429, { 'Retry-After': '3600' });
  }

  const body = await parseBody(req);
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const username = typeof body.username === 'string' ? body.username.trim() : '';
  if (!validEmail(email) || !username) return json({ error: 'email and username required' }, 400);

  const user = await env.DB.prepare(
    'SELECT * FROM users WHERE username = ? COLLATE NOCASE AND email = ? AND email_verified = 1'
  )
    .bind(username, email)
    .first<UserRow>();

  if (user) {
    // Per-account throttle prevents a matched pair from being hammered.
    const acctBucket = `recover_acct:${user.id}`;
    if (!(await throttle(env, acctBucket, MAX_RECOVER_PER_ACCOUNT_PER_WINDOW, THROTTLE_WINDOW_MS, now))) {
      const code = sixDigitCode();
      await env.DB.prepare('DELETE FROM pending_claims WHERE user_id = ? AND purpose = ?')
        .bind(user.id, 'recover')
        .run();
      await env.DB.prepare(
        'INSERT INTO pending_claims (user_id, email, code, purpose, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)'
      )
        .bind(user.id, email, code, 'recover', now, now + CODE_TTL_MS)
        .run();
      // Best-effort send; failure must not change the response shape (no oracle).
      await sendResendCode(env, email, code, 'recover').catch(() => {});
    }
  }

  // Byte-identical generic response in every path — match, no-match, or throttled
  // account. Never confirms whether the handle/email exist.
  return json(RECOVER_GENERIC);
}

async function recoverVerify(req: Request, env: Env): Promise<Response> {
  if (!emailEnabled(env)) return json({ error: 'claiming not enabled yet' }, 501);

  const now = Date.now();
  await purgeExpired(env, now);

  // Per-ip-hash throttle on verify (brute-force speed-bump on the 6-digit code).
  const ipBucket = `recover_verify:${await ipHash(req, env)}`;
  if (await throttle(env, ipBucket, MAX_RECOVER_VERIFY_PER_WINDOW, THROTTLE_WINDOW_MS, now)) {
    return json({ error: 'too many recovery attempts, try again later' }, 429, { 'Retry-After': '3600' });
  }

  const body = await parseBody(req);
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const username = typeof body.username === 'string' ? body.username.trim() : '';
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!validEmail(email) || !username || !/^\d{6}$/.test(code)) {
    return json({ error: 'email, username and 6-digit code required' }, 400);
  }

  const user = await env.DB.prepare(
    'SELECT * FROM users WHERE username = ? COLLATE NOCASE AND email = ? AND email_verified = 1'
  )
    .bind(username, email)
    .first<UserRow>();

  // A missing pair and a wrong code return the SAME generic error — no oracle.
  if (user) {
    const pc = await env.DB.prepare(
      'SELECT * FROM pending_claims WHERE user_id = ? AND purpose = ? ORDER BY id DESC LIMIT 1'
    )
      .bind(user.id, 'recover')
      .first<{ id: number; code: string; expires_at: number }>();

    if (pc && pc.code === code && pc.expires_at >= now) {
      // Consume the code (single-use) and rotate the device token.
      await env.DB.prepare('DELETE FROM pending_claims WHERE user_id = ? AND purpose = ?')
        .bind(user.id, 'recover')
        .run();
      const token = randomTokenHex(32);
      const tokenHash = await sha256Hex(token);
      await env.DB.prepare('UPDATE users SET token_hash = ? WHERE id = ?').bind(tokenHash, user.id).run();
      return json({ ok: true, deviceToken: token });
    }
  }

  return json({ error: 'invalid or expired code' }, 400);
}
