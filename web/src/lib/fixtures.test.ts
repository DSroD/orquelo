import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import type {
  ModeratorSnapshot, EditorSnapshot, ApiErrorBody, AudienceSnapshot, Me, Poll, PollRotation, Presentation, PresentationListItem, ScreenSnapshot, SessionResults, Session, Share,
  VoteResponse, OAuthRequest, OAuthRedirect, OAuthGrant,
} from "./types";

const load = (n: string) =>
  JSON.parse(readFileSync(resolve(import.meta.dirname, "../../../docs/api-fixtures", `${n}.json`), "utf8"));

const isStr = (v: unknown) => typeof v === "string";
const isNum = (v: unknown) => typeof v === "number";
const keys = (o: object, ks: string[]) => expect(Object.keys(o).sort()).toEqual([...ks].sort());

describe("fixtures match types.ts", () => {
  it("audience", () => {
    for (const n of ["audience", "audience-idle", "audience-no-vote", "audience-qa"]) {
      const a: AudienceSnapshot = load(n);
      keys(a, ["session", "presentation", "poll", "my_vote", "qa"]);
      if (a.poll) {
        keys(a.poll, ["run_id", "question", "kind", "open", "options"]);
        a.poll.options.forEach((o) => keys(o, ["id", "label", "exclusive"]));
      }
      keys(a.qa, ["enabled", "open", "started", "questions"]);
      a.qa.questions.forEach((q) => keys(q, ["id", "text", "status", "created_at", "updated_at"]));
      expect(a.my_vote === null || Array.isArray(a.my_vote)).toBe(true);
    }
  });
  it("screen", () => {
    for (const n of ["screen", "screen-unrevealed", "screen-qr", "screen-qa", "screen-qa-question"]) {
      const s: ScreenSnapshot = load(n);
      keys(s, ["session", "presentation", "join_url", "stage"]);
      keys(s.stage, ["slide", "overlay"]);
      expect(isNum(s.stage.slide)).toBe(true);
      const o = s.stage.overlay;
      if (!o) continue;
      switch (o.type) {
        case "qr": keys(o, ["type"]); break;
        case "qa": keys(o, ["type", "question", "open"]); if (o.question) keys(o.question, ["id", "text"]); break;
        case "poll":
          keys(o, ["type", "run_id", "question", "kind", "open", "revealed", "total_voters", "options"]);
          o.options.forEach((x) => keys(x, ["id", "label", "count"]));
          // counts are hidden until revealed
          o.options.forEach((x) => expect(x.count === null).toBe(!o.revealed));
          break;
        default: { const _never: never = o; return _never; }
      }
    }
  });
  it("me", () => {
    const m: Me = load("me");
    keys(m, ["user", "membership"]);
    keys(m.user, ["id", "email", "name"]);
    keys(m.membership, ["plan", "status", "storage_used", "storage_quota", "max_upload_bytes"]);
    expect(isNum(m.user.id) && isStr(m.membership.plan) && isNum(m.membership.storage_quota)).toBe(true);
    const u: Me = load("me-unlimited");
    keys(u.membership, ["plan", "status", "storage_used", "storage_quota", "max_upload_bytes"]);
    expect(u.membership.plan === null && u.membership.storage_quota === null).toBe(true);
  });
  it("moderator", () => {
    const a: ModeratorSnapshot = load("moderator");
    keys(a, ["session", "presentation", "audience_url", "screen_url", "connections", "stage", "open_run", "runs", "qa"]);
    keys(a.session, ["code", "screen_code", "label", "started_at", "ended_at"]);
    keys(a.connections, ["audience", "screen"]);
    keys(a.stage, ["slide", "overlay"]);
    if (a.stage.overlay?.type === "poll") keys(a.stage.overlay, ["type", "run_id", "revealed"]);
    if (a.open_run) keys(a.open_run, ["run_id", "poll_id", "question", "kind", "opened_at", "options", "total_voters", "allow_additional_answers"]);
    a.runs.forEach((r) => keys(r, ["run_id", "poll_id", "question", "kind", "opened_at", "closed_at", "total_voters"]));
  });
  it("projector page controls", () => {
    const rotation: PollRotation = load("poll-rotation");
    keys(rotation, ["paused", "advance"]);
    expect(typeof rotation.paused).toBe("boolean");
    expect(Number.isSafeInteger(rotation.advance) && rotation.advance >= 0).toBe(true);
    const pages: NonNullable<ModeratorSnapshot["screen_pages"]> = load("screen-pages");
    for (const position of pages) {
      keys(position, ["page", "total"]);
      expect(Number.isInteger(position.page) && Number.isInteger(position.total)).toBe(true);
      expect(position.page).toBeGreaterThanOrEqual(1);
      expect(position.page).toBeLessThanOrEqual(position.total);
    }
  });
  it("editor projection excludes moderator data", () => {
    const e: EditorSnapshot = load("editor");
    expect(e.session.screen_code).toBeNull();
    for (const value of [e.screen_url, e.connections, e.stage, e.qa]) expect(value).toBeNull();
    expect(e.runs).toEqual([]);
    expect(e.open_run?.options.length).toBeGreaterThan(0);
  });
  it("results", () => {
    const r: SessionResults = load("results");
    keys(r, ["session", "presentation", "summary", "runs", "qa"]);
    keys(r.session, ["code", "label", "started_at", "ended_at"]);
    keys(r.presentation, ["id", "title"]);
    keys(r.summary, ["unique_voters", "peak_audience", "runs", "avg_participation", "median_seconds_to_vote", "changed_votes", "changed_voters"]);
    r.runs.forEach((x) => {
      keys(x, ["run_id", "poll_id", "slide", "question", "kind", "opened_at", "closed_at", "total_voters", "peak_audience",
        "participation", "median_seconds_to_vote", "changed_voters", "options"]);
      x.options.forEach((o) => keys(o, ["id", "idx", "label", "count"]));
    });
  });
  it("rest", () => {
    const p: Presentation = load("presentation");
    keys(p, ["id", "title", "page_count", "created_at", "archived_at", "owner", "access", "qa_enabled"]);
    keys(p.owner, ["email", "name"]);
    keys(p.access, ["owner", "edit", "moderate", "copy", "results"]);
    const item: PresentationListItem = load("presentation-listing");
    keys(item, ["id", "title", "page_count", "created_at", "archived_at", "owner", "access", "live_sessions", "qa_enabled"]);
    const shares: Share[] = load("shares");
    shares.forEach((x) => keys(x, ["email", "edit", "moderate", "copy", "results"]));
    const poll: Poll = load("poll");
    keys(poll, ["id", "presentation_id", "slide", "position", "question", "kind", "options", "has_runs", "show_results", "archived_at", "allow_additional_answers"]);
    const s: Session = load("session");
    keys(s, ["id", "presentation_id", "code", "screen_code", "label", "started_at", "ended_at", "audience_url", "screen_url"]);
    const v: VoteResponse = load("vote-response");
    keys(v, ["run_id", "option_ids"]);
    const e: ApiErrorBody = load("error");
    expect(isStr(e.error) && isStr(e.message)).toBe(true);
  });
  it("oauth", () => {
    const client = ["name", "host", "uri", "verified"];
    const r: OAuthRequest = load("oauth-request");
    keys(r, ["id", "client", "redirect_host", "redirect_host_differs", "scopes"]);
    keys(r.client, client);
    r.scopes.forEach((x) => keys(x, ["name", "description", "requested"]));
    keys(load("oauth-redirect") as OAuthRedirect, ["redirect_to"]);
    const grants: OAuthGrant[] = load("oauth-grants");
    grants.forEach((g) => {
      keys(g, ["id", "client", "scopes", "created_at", "last_used_at", "needs_reconnect"]);
      keys(g.client, client);
    });
  });
});
