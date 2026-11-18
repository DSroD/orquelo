// Contract types; see docs/api.md. Fixtures in docs/api-fixtures/ must parse as these.
export type ISOTime = string;
export type PollKind = "single" | "multi";

// What the asking user may do with a deck; the owner has every flag. Seeing a deck at all means view.
export interface Access { owner: boolean; edit: boolean; moderate: boolean; copy: boolean; results: boolean }
export interface Presentation {
  id: number; title: string; page_count: number; created_at: ISOTime; archived_at: ISOTime | null; qa_enabled: boolean;
  owner: { email: string; name: string }; access: Access;
}
// A share grants view plus the flags set; it applies to the user with that verified email.
export interface Share { email: string; edit: boolean; moderate: boolean; copy: boolean; results: boolean }
export interface PresentationListItem extends Presentation { live_sessions: number }
export interface OptionDraft { label: string; exclusive: boolean }
export interface Option extends OptionDraft { id: number; idx: number }
export interface Poll {
  id: number; presentation_id: number; slide: number | null; position: number;
  question: string; kind: PollKind; options: Option[]; has_runs: boolean; show_results: boolean; allow_additional_answers: boolean;
  // set once archived: kept with its runs and results, but no longer offered in any session
  archived_at: ISOTime | null;
}
export interface Session {
  id: number; presentation_id: number; code: string; screen_code: string | null; label: string;
  started_at: ISOTime; ended_at: ISOTime | null; audience_url: string; screen_url: string | null;
}
export interface VoteResponse { run_id: number; option_ids: number[] }
export interface Me {
  user: { id: number; email: string | null; name: string };
  membership: {
    plan: string | null; status: "active" | "suspended";
    storage_used: number; storage_quota: number | null; max_upload_bytes: number;
  };
}
export interface PasswordLogin { email: string; password: string }
export interface PasswordChange { current: string; new: string }
export interface ApiErrorBody { error: string; message: string; field?: string }

export interface CountedOption { id: number; label: string; count: number }

export type QuestionStatus = "pending" | "answered" | "dismissed";
export interface Question { id: number; text: string; status: QuestionStatus; created_at: ISOTime; updated_at: ISOTime }
export interface AudienceQA { enabled: boolean; open: boolean; started: boolean; questions: Question[] }
export interface ModeratorQA extends AudienceQA { selected_question_id: number | null }

export interface AudienceSnapshot {
  session: { code: string; label: string };
  presentation: { id: number; title: string };
  poll: null | {
    run_id: number; question: string; kind: PollKind; open: boolean;
    options: { id: number; label: string; exclusive: boolean }[];
  };
  my_vote: number[] | null;
  qa: AudienceQA;
}

// What the screen shows: the slide in the background and at most one overlay on top of it.
// An overlay is a tagged union on `type`; add a variant here, in the backend and as a Svelte branch.
export interface QrOverlay { type: "qr" }
export interface ScreenPollOverlay {
  type: "poll"; run_id: number; question: string; kind: PollKind; open: boolean; revealed: boolean;
  total_voters: number; options: { id: number; label: string; count: number | null }[]; // count null unless revealed
}
export interface ScreenQAOverlay { type: "qa"; question: { id: number; text: string } | null; open: boolean }
export type ScreenOverlay = QrOverlay | ScreenPollOverlay | ScreenQAOverlay;
export interface ModeratorPollOverlay { type: "poll"; run_id: number; revealed: boolean }
export interface ModeratorQAOverlay { type: "qa"; question_id: number | null }
export type ModeratorOverlay = QrOverlay | ModeratorPollOverlay | ModeratorQAOverlay;

export interface ScreenSnapshot {
  session: { code: string; label: string };
  presentation: { id: number; title: string; page_count: number };
  join_url: string;
  stage: { slide: number; overlay: ScreenOverlay | null };
}

export interface RunSummary {
  run_id: number; poll_id: number; question: string; kind: PollKind;
  opened_at: ISOTime; closed_at: ISOTime | null; total_voters: number;
}

export interface ModeratorSnapshot {
  session: { code: string; screen_code: string; label: string; started_at: ISOTime; ended_at: ISOTime | null };
  presentation: { id: number; title: string; page_count: number };
  audience_url: string;
  screen_url: string;
  connections: { audience: number; screen: number };
  stage: { slide: number; overlay: ModeratorOverlay | null };
  // the run accepting votes, if any; it may differ from the run the overlay shows
  open_run: null | {
    run_id: number; poll_id: number; question: string; kind: PollKind; opened_at: ISOTime;
    options: (CountedOption & { exclusive: boolean })[]; total_voters: number; allow_additional_answers: boolean;
  };
  qa: ModeratorQA;
  runs: RunSummary[]; // this session's history, newest first
}

// Editors see the current vote, without the moderator inbox or projector capabilities.
export interface EditorSnapshot {
  session: { code: string; screen_code: null; label: string; started_at: ISOTime; ended_at: ISOTime | null };
  presentation: ModeratorSnapshot["presentation"];
  audience_url: string;
  screen_url: null;
  connections: null;
  stage: null;
  open_run: ModeratorSnapshot["open_run"];
  qa: null;
  runs: [];
}
export type SessionSnapshot = ModeratorSnapshot | EditorSnapshot;

// GET /api/sessions/:code/results; every | null is "not recorded" (older sessions, runs without a peak or votes)
export interface ResultOption { id: number; idx: number; label: string; count: number }
export interface RunResult {
  run_id: number; poll_id: number; slide: number | null; question: string; kind: PollKind;
  opened_at: ISOTime; closed_at: ISOTime | null; total_voters: number; peak_audience: number | null;
  participation: number | null; median_seconds_to_vote: number | null; changed_voters: number | null;
  options: ResultOption[];
}
export interface SessionResults {
  session: { code: string; label: string; started_at: ISOTime; ended_at: ISOTime | null };
  presentation: { id: number; title: string };
  summary: {
    unique_voters: number; peak_audience: number | null; runs: number; avg_participation: number | null;
    median_seconds_to_vote: number | null; changed_votes: number | null; changed_voters: number | null;
  };
  qa: { enabled: boolean; questions: Question[] };
  runs: RunResult[]; // oldest first
}
