-- OAuth 2.1 authorization server state (see server/oauth/store.rkt). Times are epoch seconds
-- (bigint), exactly as the store interface passes them; hashes are SHA-256 digests.

CREATE TABLE oauth_clients (
  client_id     text PRIMARY KEY,
  kind          text NOT NULL CHECK (kind IN ('metadata-document', 'registered')),
  name          text NOT NULL,
  client_uri    text,
  logo_uri      text,
  redirect_uris text[] NOT NULL,
  refresh       boolean NOT NULL,
  created_at    bigint NOT NULL,
  -- when a cached metadata document goes stale; NULL for a registered client
  expires_at    bigint
);

-- No foreign key to oauth_clients: pending rows are short-lived, sweep keeps the clients they refer to,
-- and the generic store suite stores pending rows for clients it never put
CREATE TABLE oauth_pending (
  id_hash           bytea PRIMARY KEY,
  client_id         text NOT NULL,
  redirect_uri      text NOT NULL,
  explicit_redirect boolean NOT NULL,
  scopes            text[] NOT NULL,
  state             text,
  challenge         text NOT NULL,
  resource          text NOT NULL,
  expires_at        bigint NOT NULL
);
CREATE INDEX oauth_pending_expires ON oauth_pending (expires_at);
CREATE INDEX oauth_pending_client ON oauth_pending (client_id);

-- one row per approval: a user may approve the same client many times
CREATE TABLE oauth_grants (
  id            text PRIMARY KEY,
  user_id       bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_id     text NOT NULL REFERENCES oauth_clients(client_id) ON DELETE CASCADE,
  scopes        text[] NOT NULL,
  session_epoch bigint NOT NULL CHECK (session_epoch >= 0),
  created_at    bigint NOT NULL,
  last_used_at  bigint
);
CREATE INDEX oauth_grants_user ON oauth_grants (user_id);
CREATE INDEX oauth_grants_client ON oauth_grants (client_id);

CREATE TABLE oauth_codes (
  code_hash         bytea PRIMARY KEY,
  grant_id          text NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
  redirect_uri      text NOT NULL,
  explicit_redirect boolean NOT NULL,
  challenge         text NOT NULL,
  resource          text NOT NULL,
  scopes            text[] NOT NULL,
  expires_at        bigint NOT NULL,
  -- set when consumed; the row stays so that a second use is recognised as a replay
  used_at           bigint
);
CREATE INDEX oauth_codes_grant ON oauth_codes (grant_id);
CREATE INDEX oauth_codes_expires ON oauth_codes (expires_at);

CREATE TABLE oauth_access_tokens (
  token_hash bytea PRIMARY KEY,
  grant_id   text NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
  scopes     text[] NOT NULL,
  resource   text NOT NULL,
  expires_at bigint NOT NULL
);
CREATE INDEX oauth_access_tokens_grant ON oauth_access_tokens (grant_id);
CREATE INDEX oauth_access_tokens_expires ON oauth_access_tokens (expires_at);

CREATE TABLE oauth_refresh_tokens (
  token_hash bytea PRIMARY KEY,
  grant_id   text NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
  scopes     text[] NOT NULL,
  resource   text NOT NULL,
  expires_at bigint NOT NULL,
  -- set when rotated away; the row stays so that its reuse is recognised
  retired_at bigint
);
CREATE INDEX oauth_refresh_tokens_grant ON oauth_refresh_tokens (grant_id);
CREATE INDEX oauth_refresh_tokens_expires ON oauth_refresh_tokens (expires_at);
