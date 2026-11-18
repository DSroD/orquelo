CREATE FUNCTION iso(t timestamptz) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

-- Accounts. email_verified: the address is trusted for linking logins and for receiving shares
CREATE TABLE users (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email          text,
  email_verified boolean NOT NULL DEFAULT false,
  name           text NOT NULL DEFAULT '',
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
  -- a cookie is valid only under the epoch it was issued in, so bumping it logs the user out everywhere
  session_epoch  bigint NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_login_at  timestamptz
);
CREATE UNIQUE INDEX users_verified_email ON users (lower(email)) WHERE email_verified;

-- local accounts: password credentials
CREATE TABLE password_credentials (
  user_id    bigint PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  hash       text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE presentations (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title      text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  owner_id   bigint NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  pdf_key    text NOT NULL,
  pdf_bytes  bigint NOT NULL DEFAULT 0 CHECK (pdf_bytes >= 0),
  page_count int  NOT NULL CHECK (page_count > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz
);

CREATE INDEX presentations_owner ON presentations (owner_id);

-- A share applies to the user whose verified email matches, even before their first login.
CREATE TABLE deck_shares (
  presentation_id bigint NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
  email           text   NOT NULL CHECK (email = lower(email)),
  can_edit        boolean NOT NULL DEFAULT false,
  can_moderate    boolean NOT NULL DEFAULT false,
  can_copy        boolean NOT NULL DEFAULT false,
  can_results     boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (presentation_id, email)
);
CREATE INDEX deck_shares_email ON deck_shares (email);

CREATE TABLE polls (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  presentation_id bigint NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
  slide           int CHECK (slide IS NULL OR slide > 0),
  position        int NOT NULL,
  question        text NOT NULL CHECK (length(question) BETWEEN 1 AND 500),
  kind            text NOT NULL CHECK (kind IN ('single', 'multi')),
  -- open the poll with its results already shown on the screen
  show_results    boolean NOT NULL DEFAULT false,
  -- polls with runs cannot be deleted; archiving hides them. NULL = active
  archived_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX polls_presentation_slide ON polls (presentation_id, slide, position);

ALTER TABLE polls ADD COLUMN allow_additional_answers boolean NOT NULL DEFAULT false;
ALTER TABLE presentations ADD COLUMN qa_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE poll_options (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  poll_id bigint NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
  idx     int  NOT NULL CHECK (idx >= 0),
  label   text NOT NULL CHECK (length(label) BETWEEN 1 AND 200),
  exclusive boolean NOT NULL DEFAULT false,
  UNIQUE (poll_id, idx)
);

CREATE TABLE lecture_sessions (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  presentation_id bigint NOT NULL REFERENCES presentations(id) ON DELETE RESTRICT,
  code            text NOT NULL UNIQUE CHECK (code ~ '^[a-z2-7]{10}$'),
  label           text NOT NULL DEFAULT '' CHECK (length(label) <= 100),
  -- the presenter-only code of the projector screen and the PDF
  screen_code     text NOT NULL UNIQUE CHECK (screen_code ~ '^[a-z2-7]{10}$'),
  current_slide   int  NOT NULL DEFAULT 1 CHECK (current_slide > 0),
  started_at      timestamptz NOT NULL DEFAULT now(),
  ended_at        timestamptz,
  peak_audience   int
);
ALTER TABLE lecture_sessions ADD COLUMN qa_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE lecture_sessions ADD COLUMN qa_open boolean NOT NULL DEFAULT false;
ALTER TABLE lecture_sessions ADD COLUMN qa_started boolean NOT NULL DEFAULT false;
ALTER TABLE lecture_sessions ADD COLUMN qa_on_screen boolean NOT NULL DEFAULT false;
ALTER TABLE lecture_sessions ADD COLUMN qa_selected bigint;

CREATE INDEX lecture_sessions_presentation ON lecture_sessions (presentation_id);

CREATE TABLE poll_runs (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id  bigint NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
  poll_id     bigint NOT NULL REFERENCES polls(id) ON DELETE RESTRICT,
  opened_at   timestamptz NOT NULL DEFAULT now(),
  closed_at   timestamptz CHECK (closed_at IS NULL OR closed_at >= opened_at),
  revealed_at timestamptz,
  peak_audience int
);
CREATE UNIQUE INDEX poll_runs_one_open ON poll_runs (session_id) WHERE closed_at IS NULL;
CREATE INDEX poll_runs_session_opened ON poll_runs (session_id, opened_at DESC);
CREATE INDEX poll_runs_poll ON poll_runs (poll_id);

ALTER TABLE poll_runs ADD COLUMN allow_additional_answers boolean NOT NULL DEFAULT false;

CREATE TABLE run_options (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  poll_run_id bigint NOT NULL REFERENCES poll_runs(id) ON DELETE CASCADE,
  idx int NOT NULL CHECK (idx >= 0),
  label text NOT NULL CHECK (length(label) BETWEEN 1 AND 200),
  exclusive boolean NOT NULL DEFAULT false,
  UNIQUE (poll_run_id, idx),
  UNIQUE (poll_run_id, id)
);

CREATE TABLE votes (
  poll_run_id    bigint NOT NULL REFERENCES poll_runs(id) ON DELETE CASCADE,
  participant_id uuid   NOT NULL,
  voted_at       timestamptz NOT NULL DEFAULT now(),
  -- engagement; NULL = not recorded
  first_voted_at timestamptz DEFAULT now(),
  changes        int DEFAULT 0,
  PRIMARY KEY (poll_run_id, participant_id)
);

CREATE TABLE vote_options (
  poll_run_id    bigint NOT NULL,
  participant_id uuid   NOT NULL,
  option_id      bigint NOT NULL,
  PRIMARY KEY (poll_run_id, participant_id, option_id),
  FOREIGN KEY (poll_run_id, participant_id) REFERENCES votes ON DELETE CASCADE,
  FOREIGN KEY (poll_run_id, option_id) REFERENCES run_options(poll_run_id, id) ON DELETE CASCADE
);
CREATE INDEX vote_options_run_option ON vote_options (poll_run_id, option_id);

CREATE VIEW analysis_votes AS
SELECT s.id AS session_id, s.code AS session_code, s.label AS session_label, s.started_at AS session_started_at,
       p.id AS presentation_id, p.title AS presentation_title,
       pl.id AS poll_id, pl.slide, pl.question, pl.kind,
       r.id AS run_id, r.opened_at AS run_opened_at,
       o.id AS option_id, o.idx AS option_idx, o.label AS option_label,
       v.participant_id, v.voted_at
FROM vote_options vo
JOIN votes v            ON v.poll_run_id = vo.poll_run_id AND v.participant_id = vo.participant_id
JOIN poll_runs r        ON r.id = vo.poll_run_id
JOIN lecture_sessions s ON s.id = r.session_id
JOIN presentations p    ON p.id = s.presentation_id
JOIN polls pl           ON pl.id = r.poll_id
JOIN run_options o      ON o.id = vo.option_id;


CREATE TABLE qa_questions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id bigint NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
  participant_id uuid NOT NULL,
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 1000 AND body = btrim(body)),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'answered', 'dismissed')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX qa_questions_session_created ON qa_questions (session_id, id);
CREATE INDEX qa_questions_participant ON qa_questions (session_id, participant_id, created_at DESC);
