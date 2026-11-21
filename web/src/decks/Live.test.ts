import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import Live from "./Live.svelte";
import { FakeEventSource, failure, fixture, stubEventSource, stubFetch } from "../test/net";
import type { EditorSnapshot, ModeratorSnapshot } from "../lib/types";

const CODE = "abcde23456";
const base = `/api/sessions/${CODE}`;
const moderator = fixture<ModeratorSnapshot>("moderator");
const deck = { ...fixture("presentation"), polls: [fixture("poll")], sessions: [] };
const closedRun = { ...moderator.runs[0], closed_at: "2026-11-15T10:25:00.000Z" };

// the fixture is mid-vote with the poll overlay hidden; tests vary it
const snapshot = (over: Partial<ModeratorSnapshot> = {}): ModeratorSnapshot => ({ ...moderator, ...over });
const atSlide = (slide: number, overlay: ModeratorSnapshot["stage"]["overlay"] = null) => snapshot({ stage: { slide, overlay } });
const noVote = { open_run: null, runs: [] };

let net: ReturnType<typeof stubFetch>;
const user = userEvent.setup();
const settle = () => new Promise((r) => setTimeout(r));

/** Opens the cockpit and delivers the first snapshot, as the server stream would. */
async function open(snap: ModeratorSnapshot = moderator, handler: Parameters<typeof stubFetch>[0] = () => ({})) {
  net = stubFetch((c) => (c.method === "GET" ? deck : handler(c)));
  const view = render(Live, { code: CODE });
  FakeEventSource.last().emit("snapshot", snap);
  await screen.findByRole("heading", { name: /Class A/ });
  return view;
}
const push = (snap: ModeratorSnapshot) => FakeEventSource.last().emit("snapshot", snap);
const dock = () => within(screen.getByRole("group", { name: "Lecture controls" }));
const posts = () => net.posts().map(({ method, url, body }) => [method, url, body]);
const post = (path: string, body: unknown = {}) => ["POST", `${base}/${path}`, body];

beforeEach(() => {
  localStorage.clear();
  stubEventSource();
});
afterEach(() => vi.unstubAllGlobals());

describe("Live cockpit: reading the snapshot", () => {
  it("shows the slide position", async () => {
    await open();
    expect(screen.getByText("5 / 42")).toBeTruthy();
  });

  it("names the dock's next step after the vote's state", async () => {
    await open();
    expect(dock().getByRole("button", { name: "Reveal results" })).toBeTruthy();
    push(snapshot({ stage: { slide: 5, overlay: { type: "poll", run_id: 12, revealed: true } } }));
    expect(await dock().findByRole("button", { name: "Close voting" })).toBeTruthy();
    push(snapshot({ ...noVote, stage: { slide: 5, overlay: null } }));
    expect(await dock().findByRole("button", { name: "Open poll" })).toBeTruthy();
    push(snapshot({ ...noVote, stage: { slide: 6, overlay: null } }));
    expect(await dock().findByRole("button", { name: "No poll on this slide" })).toBeTruthy();
  });

  it("opens the slide's poll from the dock", async () => {
    await open(snapshot({ ...noVote }));
    await user.click(await dock().findByRole("button", { name: "Open poll" }));
    expect(posts()).toEqual([post("poll/open", { poll_id: 3, only_if_idle: true })]);
  });

  it("requires closing voting before another poll can open", async () => {
    await open();
    const start = await screen.findByRole<HTMLButtonElement>("button", { name: "Start new vote" });
    expect(start.disabled).toBe(true);
    await user.click(start);
    await user.keyboard("o");
    expect(posts()).toEqual([]);
    await user.click(dock().getByRole("button", { name: "Reveal results" }));
    push(atSlide(5, { type: "poll", run_id: 12, revealed: true }));
    await user.click(await dock().findByRole("button", { name: "Close voting" }));
    expect(posts().at(-1)).toEqual(post("poll/close", { run_id: 12 }));
    push(snapshot({ open_run: null, runs: [closedRun] }));
    await vi.waitFor(() => expect(start.disabled).toBe(false));
    await user.click(start);
    expect(posts().at(-1)).toEqual(post("poll/open", { poll_id: 3, only_if_idle: true }));
  });
});

describe("Live cockpit: moving through slides", () => {
  it("next and prev buttons post the neighbouring slide", async () => {
    await open();
    await user.click(dock().getByRole("button", { name: "Next slide" }));
    await vi.waitFor(() => expect(posts()).toEqual([post("slide", { slide: 6 })]));
    await user.click(dock().getByRole("button", { name: "Previous slide" }));
    await vi.waitFor(() => expect(posts().at(-1)).toEqual(post("slide", { slide: 4 })));
  });

  it.each([["ArrowRight", 6], ["PageDown", 6], ["ArrowLeft", 4], ["PageUp", 4]])("%s posts slide %i", async (key, slide) => {
    await open();
    await user.keyboard(`{${key}}`);
    expect(posts()).toEqual([post("slide", { slide })]);
  });

  it("stops at the first slide", async () => {
    await open(atSlide(1));
    expect((dock().getByRole("button", { name: "Previous slide" }) as HTMLButtonElement).disabled).toBe(true);
    await user.keyboard("{ArrowLeft}{PageUp}");
    await settle();
    expect(posts()).toEqual([]);
    await user.keyboard("{ArrowRight}");
    expect(posts()).toEqual([post("slide", { slide: 2 })]);
  });

  it("stops at the last slide", async () => {
    await open(atSlide(42));
    expect((dock().getByRole("button", { name: "Next slide" }) as HTMLButtonElement).disabled).toBe(true);
    await user.keyboard("{ArrowRight}{PageDown}");
    await settle();
    expect(posts()).toEqual([]);
    await user.keyboard("{ArrowLeft}");
    expect(posts()).toEqual([post("slide", { slide: 41 })]);
  });
});

describe("Live cockpit: what is on the screen", () => {
  const overlayBtn = (name: RegExp) => screen.getByRole("button", { name });

  it("s, q and p post the overlay", async () => {
    await open(atSlide(5, { type: "poll", run_id: 12, revealed: false }));
    await user.keyboard("s");
    expect(posts().at(-1)).toEqual(post("overlay", { overlay: null }));
    await user.keyboard("q");
    expect(posts().at(-1)).toEqual(post("overlay", { overlay: { type: "qr" } }));
    push(atSlide(5, null));
    await user.keyboard("p");
    await vi.waitFor(() => expect(posts().at(-1)).toEqual(post("overlay", { overlay: { type: "poll", run_id: 12 } })));
  });

  it("q again takes the QR code down", async () => {
    await open(atSlide(5, { type: "qr" }));
    await user.keyboard("q");
    expect(posts()).toEqual([post("overlay", { overlay: null })]);
  });

  it("does nothing when the chosen overlay is already showing", async () => {
    await open(atSlide(5, null));
    await user.keyboard("s");
    await settle();
    expect(posts()).toEqual([]);
  });

  it("the screen toggle posts the same overlays", async () => {
    await open(atSlide(5, null));
    await user.click(overlayBtn(/^QR code/));
    await vi.waitFor(() => expect(posts()).toEqual([post("overlay", { overlay: { type: "qr" } })]));
    await user.click(overlayBtn(/^Poll/));
    await vi.waitFor(() => expect(posts().at(-1)).toEqual(post("overlay", { overlay: { type: "poll", run_id: 12 } })));
  });

  it("reveals and hides results", async () => {
    await open();
    await user.keyboard("r");
    expect(posts()).toEqual([post("poll/reveal", { run_id: 12 })]);
    push(atSlide(5, { type: "poll", run_id: 12, revealed: true }));
    await user.click(await screen.findByRole("button", { name: /^Hide results/ }));
    await vi.waitFor(() => expect(posts().at(-1)).toEqual(post("poll/hide", { run_id: 12 })));
  });

  it("closes voting with c", async () => {
    await open();
    await user.keyboard("c");
    expect(posts()).toEqual([post("poll/close", { run_id: 12 })]);
  });

  it("offers to show the live poll while a previous run is on screen", async () => {
    await open(snapshot({
      runs: [...moderator.runs, { ...closedRun, run_id: 11, question: "Earlier vote" }],
      stage: { slide: 5, overlay: { type: "poll", run_id: 11, revealed: false } },
    }));
    await user.keyboard("r");
    expect(posts()).toEqual([]);
    await user.click(screen.getByRole("button", { name: "Reveal previous results" }));
    expect(posts()).toEqual([post("poll/reveal", { run_id: 11 })]);
    await user.click(dock().getByRole("button", { name: "Show current poll" }));
    expect(posts().at(-1)).toEqual(post("overlay", { overlay: { type: "poll", run_id: 12 } }));
    push(atSlide(5, { type: "poll", run_id: 12, revealed: false }));
    await user.click(await dock().findByRole("button", { name: "Reveal results" }));
    expect(posts().at(-1)).toEqual(post("poll/reveal", { run_id: 12 }));
  });

  it("controls pages for the displayed poll and reflects the shared pause state", async () => {
    await open(snapshot({ screen_pages: [{ page: 1, total: 1 }] }));
    const stage = within(screen.getByRole("region", { name: "On screen" }));
    expect(stage.queryByRole("group", { name: "Projector pages" })).toBeNull();
    push(snapshot({ screen_pages: [{ page: 1, total: 3 }] }));
    const pages = within(await stage.findByRole("group", { name: "Projector pages" }));
    await user.click(pages.getByRole("button", { name: "Pause rotation" }));
    push(snapshot({ screen_pages: [{ page: 2, total: 3 }], stage: { ...moderator.stage, rotation: { paused: true, advance: 0 } } }));
    expect(await pages.findByRole("button", { name: "Resume rotation" })).toBeTruthy();
    expect(pages.getByRole("status").textContent).toBe("View 2 / 3");
    await user.click(pages.getByRole("button", { name: "Next page" }));
    await user.click(pages.getByRole("button", { name: "Resume rotation" }));
    expect(posts()).toEqual(["pause", "next", "resume"].map((action) => post("poll/rotation", { run_id: 12, revealed: false, action })));
  });
});

describe("Live cockpit: shortcuts and typing", () => {
  it("are ignored while focus is in a form field", async () => {
    await open();
    screen.getByRole("radio").focus();
    await user.keyboard("sqcor");
    await settle();
    expect(posts()).toEqual([]);
  });

  it.each([["Control"], ["Meta"], ["Alt"], ["Shift"]])("are ignored with %s held", async (mod) => {
    await open();
    await user.keyboard(`{${mod}>}s{ArrowRight}c{/${mod}}`);
    await settle();
    expect(posts()).toEqual([]);
  });

  it("can turn off letter shortcuts without losing slide keys or buttons", async () => {
    const view = await open();
    await user.click(screen.getByText("Session", { selector: "summary" }));
    await user.click(screen.getByRole("checkbox", { name: "Letter shortcuts" }));
    await user.keyboard("{Escape}rcq{ArrowRight}");
    expect(posts()).toEqual([post("slide", { slide: 6 })]);
    expect(dock().getByRole("button", { name: "Reveal results" }).hasAttribute("aria-keyshortcuts")).toBe(false);
    await user.click(dock().getByRole("button", { name: "Reveal results" }));
    expect(posts().at(-1)).toEqual(post("poll/reveal", { run_id: 12 }));
    view.unmount();
    await open();
    expect(dock().getByRole("button", { name: "Reveal results" }).hasAttribute("aria-keyshortcuts")).toBe(false);
  });
});

describe("Live cockpit: failing actions", () => {
  it("shows the server's error in an alert and clears it after the next success", async () => {
    let n = 0;
    await open(moderator, () => (n++ === 0 ? failure(403, { error: "forbidden", message: "Not your session" }) : {}));
    const next = dock().getByRole("button", { name: "Next slide" });
    await user.click(next);
    expect((await screen.findByRole("alert")).textContent).toBe("Not your session");
    await user.click(next);
    await vi.waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
    expect(posts()).toHaveLength(2);
  });
});

describe("Live cockpit: ended session", () => {
  const frozen = async () => {
    expect((dock().getByRole("button", { name: "Next slide" }) as HTMLButtonElement).disabled).toBe(true);
    expect((dock().getByRole("button", { name: "Previous slide" }) as HTMLButtonElement).disabled).toBe(true);
    expect((dock().getByRole("button", { name: "Session ended" }) as HTMLButtonElement).disabled).toBe(true);
    await user.keyboard("{ArrowRight}{ArrowLeft}sqpocr");
    await settle();
    expect(posts()).toEqual([]);
  };

  it("disables the controls when the snapshot says it ended", async () => {
    await open(snapshot({ session: { ...moderator.session, ended_at: "2026-11-15T11:00:00.000Z" } }));
    await frozen();
  });

  it("disables the controls when the stream reports the end", async () => {
    await open();
    FakeEventSource.last().emit("ended");
    await dock().findByRole("button", { name: "Session ended" });
    await frozen();
  });
});

describe("Live cockpit: resuming a closed vote", () => {
  it("offers Resume on the newest run's poll once it is closed", async () => {
    await open(snapshot({ open_run: null, runs: [closedRun] }));
    await user.click(await screen.findByRole("button", { name: "Resume" }));
    expect(posts()).toEqual([post("poll/resume", { run_id: 12 })]);
  });

  it("does not offer Resume while that run is open", async () => {
    await open();
    await screen.findByRole("button", { name: "Start new vote" });
    expect(screen.queryByRole("button", { name: "Resume" })).toBeNull();
  });
});

describe("Live cockpit: session menu", () => {
  const menu = () => screen.getByText("Session", { selector: "summary" }).closest("details")!;

  it("opens from its button and closes on Escape", async () => {
    await open();
    expect(menu().open).toBe(false);
    await user.click(screen.getByText("Session", { selector: "summary" }));
    expect(menu().open).toBe(true);
    await user.keyboard("{Escape}");
    expect(menu().open).toBe(false);
  });

  it("closes on a click outside but not inside", async () => {
    await open();
    await user.click(screen.getByText("Session", { selector: "summary" }));
    await user.click(screen.getByRole("navigation", { name: "Session" }));
    expect(menu().open).toBe(true);
    await user.click(document.body);
    expect(menu().open).toBe(false);
  });
});

describe("Live Q&A moderation", () => {
  it("opens submissions separately from showing the generic screen", async () => {
    const snap = fixture<ModeratorSnapshot>("moderator-qa");
    await open({ ...snap, qa: { ...snap.qa, open: false } });
    await user.click(screen.getByRole("button", { name: "Open Q&A" }));
    expect(posts()).toEqual([post("qa", { open: true })]);
    await user.click(screen.getByRole("button", { name: "Show Q&A screen" }));
    expect(posts().at(-1)).toEqual(post("overlay", { overlay: { type: "qa", question_id: null } }));
  });

  it("requires explicit question selection, then supports answer, dismiss and restore", async () => {
    const snap = fixture<ModeratorSnapshot>("moderator-qa");
    await open(snap);
    await user.click(screen.getByRole("button", { name: "Show question" }));
    expect(posts().at(-1)).toEqual(post("overlay", { overlay: { type: "qa", question_id: 41 } }));
    await user.click(screen.getByRole("button", { name: "Mark answered" }));
    expect(posts().at(-1)).toEqual(["PATCH", `${base}/qa/questions/41`, { status: "answered" }]);
    await user.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(posts().at(-1)).toEqual(["PATCH", `${base}/qa/questions/41`, { status: "dismissed" }]);
    push({ ...snap, qa: { ...snap.qa, questions: snap.qa.questions.map((q) => ({ ...q, status: "dismissed" })) } });
    await user.click(screen.getByRole("button", { name: /^dismissed/ }));
    await user.click(await screen.findByRole("button", { name: "Restore to pending" }));
    expect(posts().at(-1)).toEqual(["PATCH", `${base}/qa/questions/41`, { status: "pending" }]);
  });
});

describe("Live editor access", () => {
  it("only offers run-local additions and never sends moderator shortcuts", async () => {
    const editor = fixture<EditorSnapshot>("editor");
    net = stubFetch(() => ({ ...deck, access: { ...deck.access, owner: false, moderate: false, edit: true } }));
    render(Live, { code: CODE });
    FakeEventSource.last().emit("snapshot", { ...editor, open_run: { ...editor.open_run!, allow_additional_answers: true } });
    await screen.findByRole("heading", { name: "Current vote" });
    expect(screen.queryByRole("group", { name: "Lecture controls" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Open Q&A" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Close voting" })).toBeNull();
    expect(screen.queryByRole("navigation", { name: "Session" })).toBeNull();
    await user.keyboard("{ArrowRight}sqporc");
    expect(posts()).toEqual([]);
    await user.type(screen.getByRole("textbox", { name: "Additional answer" }), "Audience suggestion");
    await user.click(screen.getByRole("checkbox", { name: "Exclusive" }));
    await user.click(screen.getByRole("button", { name: "Add answer" }));
    expect(posts()).toEqual([post("poll/options", { run_id: 12, label: "Audience suggestion", exclusive: true })]);
  });
});
