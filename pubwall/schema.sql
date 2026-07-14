-- Beers Pub Wall — D1 schema
-- The server only ever stores what is below. There is NO column for
-- transcripts, audio, or any content of a dictation. Email is nullable and is
-- only ever populated when a user explicitly claims their handle.

CREATE TABLE IF NOT EXISTS users (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  username       TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  token_hash     TEXT    NOT NULL,          -- SHA-256 hex of the device token (raw token never stored)
  words          INTEGER NOT NULL DEFAULT 0,
  pours          INTEGER NOT NULL DEFAULT 0,
  streak_days    INTEGER NOT NULL DEFAULT 0,
  last_pour_date TEXT,                       -- UTC YYYY-MM-DD, for streak logic
  email          TEXT,                       -- NULL until an explicit claim
  email_verified INTEGER NOT NULL DEFAULT 0,
  created_at     INTEGER NOT NULL,           -- unix ms

  -- operational columns (rate-limit + per-day caps)
  last_pour_at   INTEGER,                    -- unix ms of last accepted /api/pours
  today_date     TEXT,                       -- UTC YYYY-MM-DD the *_today counters belong to
  words_today    INTEGER NOT NULL DEFAULT 0,
  pours_today    INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_users_words ON users (words DESC);
CREATE INDEX IF NOT EXISTS idx_users_token ON users (token_hash);

-- Short-lived email verification codes for claim / recover. Only rows here ever
-- reference an email, and only after the user typed one in.
CREATE TABLE IF NOT EXISTS pending_claims (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id    INTEGER NOT NULL,
  email      TEXT    NOT NULL,
  code       TEXT    NOT NULL,               -- 6-digit code
  purpose    TEXT    NOT NULL DEFAULT 'claim', -- 'claim' | 'recover'
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS idx_claims_user ON pending_claims (user_id);
CREATE INDEX IF NOT EXISTS idx_claims_expires ON pending_claims (expires_at);

-- Best-effort abuse throttle. Each row is one throttled action (a registration
-- attempt, a recovery-initiate, a recovery-verify) bucketed by a coarse key
-- (a salted hash of the source IP for anonymous endpoints, or a user id).
-- These rows carry NO dictation content — only a bucket label and a timestamp —
-- and are purged opportunistically once older than the widest rate window.
CREATE TABLE IF NOT EXISTS rate_events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  bucket     TEXT    NOT NULL,   -- e.g. 'register:<iphash>', 'recover:<iphash>', 'recover_acct:<userId>'
  created_at INTEGER NOT NULL    -- unix ms
);
CREATE INDEX IF NOT EXISTS idx_rate_events_bucket ON rate_events (bucket, created_at);
