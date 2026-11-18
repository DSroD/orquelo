import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import Editor from "./Editor.svelte";
import { failure, fixture, stubFetch } from "../test/net";
import type { Access, Me } from "../lib/types";

const URL_ = "/api/decks/7";
const me = fixture<Me>("me");
const OWNER: Access = { owner: true, edit: true, moderate: true, copy: true, results: true };
const NONE: Access = { owner: false, edit: false, moderate: false, copy: false, results: false };
const detail = (access: Access = OWNER) => ({ ...fixture<object>("presentation"), access, polls: [fixture("poll")], sessions: [fixture("session")] });
const user = userEvent.setup();
afterEach(() => vi.unstubAllGlobals());

const tab = (name: RegExp) => screen.findByRole("tab", { name });
const selected = (t: HTMLElement) => t.getAttribute("aria-selected") === "true";
const focused = (t: HTMLElement) => document.activeElement === t;

describe("Deck editor: tabs", () => {
  async function open() {
    stubFetch(() => detail({ ...NONE, edit: true }));
    render(Editor, { id: 7, me });
    return { sessions: await tab(/^Sessions/), polls: await tab(/^Polls/), qa: await tab(/^Q&A/) };
  }

  it("opens on Sessions and switches panels on click", async () => {
    const { sessions, polls } = await open();
    expect(selected(sessions)).toBe(true);
    expect(screen.getByRole("tabpanel", { name: /^Sessions/ })).toBeTruthy();
    expect(screen.queryByRole("tabpanel", { name: /^Polls/ })).toBeNull();
    await user.click(polls);
    expect(selected(polls)).toBe(true);
    expect(screen.getByRole("tabpanel", { name: /^Polls/ })).toBeTruthy();
    expect(screen.queryByRole("tabpanel", { name: /^Sessions/ })).toBeNull();
  });

  it("moves with the arrow keys, wrapping, and focus follows", async () => {
    const { sessions, polls, qa } = await open();
    sessions.focus();
    await user.keyboard("{ArrowRight}");
    expect(selected(polls) && focused(polls)).toBe(true);
    await user.keyboard("{ArrowRight}");
    expect(selected(qa) && focused(qa)).toBe(true);
    await user.keyboard("{ArrowRight}");
    expect(selected(sessions) && focused(sessions)).toBe(true);
    await user.keyboard("{ArrowLeft}");
    expect(selected(qa) && focused(qa)).toBe(true);
  });

  it("jumps with Home and End", async () => {
    const { sessions, qa } = await open();
    sessions.focus();
    await user.keyboard("{End}");
    expect(selected(qa) && focused(qa)).toBe(true);
    await user.keyboard("{Home}");
    expect(selected(sessions) && focused(sessions)).toBe(true);
  });

  it("ignores other keys", async () => {
    const { sessions } = await open();
    sessions.focus();
    await user.keyboard("a");
    expect(selected(sessions)).toBe(true);
  });
});

describe("Deck editor: title", () => {
  it("rename sends the title and the draft follows the server's version", async () => {
    let title = "Intro to HtDP";
    const net = stubFetch((c) => {
      if (c.method === "PATCH") title = (c.body as { title: string }).title.trim();
      return { ...detail(), title };
    });
    render(Editor, { id: 7, me });
    const input = (await screen.findByRole("textbox", { name: "Title" })) as HTMLInputElement;
    const rename = screen.getByRole("button", { name: "Rename" }) as HTMLButtonElement;
    expect(rename.disabled).toBe(true);
    await user.clear(input);
    await user.type(input, "  Spaced out ");
    await user.click(rename);
    await vi.waitFor(() => expect(net.posts()).toEqual([{ method: "PATCH", url: URL_, body: { title: "  Spaced out " } }]));
    await vi.waitFor(() => expect(input.value).toBe("Spaced out"));
    expect(rename.disabled).toBe(true);
  });

  it("keeps what is being typed across an unrelated reload", async () => {
    stubFetch(() => detail());
    render(Editor, { id: 7, me });
    const input = (await screen.findByRole("textbox", { name: "Title" })) as HTMLInputElement;
    await user.type(input, "!");
    await user.click(screen.getByRole("button", { name: "Archive" }));
    await vi.waitFor(() => expect((screen.getByRole("button", { name: "Archive" }) as HTMLButtonElement).disabled).toBe(false));
    expect(input.value).toBe("Intro to HtDP!");
  });
});

describe("Deck editor: Q&A", () => {
  it("saves the new-session default through the Q&A tab", async () => {
    let enabled = false;
    const net = stubFetch((c) => {
      if (c.method === "PUT") enabled = (c.body as { enabled: boolean }).enabled;
      return { ...detail(), qa_enabled: enabled };
    });
    render(Editor, { id: 7, me });
    await user.click(await tab(/^Q&A/));
    await user.click(screen.getByRole("checkbox", { name: "Allow Q&A" }));
    await vi.waitFor(() => expect(net.posts()).toEqual([{ method: "PUT", url: `${URL_}/qa`, body: { enabled: true } }]));
    expect((screen.getByRole("checkbox", { name: "Allow Q&A" }) as HTMLInputElement).checked).toBe(true);
  });
});

describe("Deck editor: load errors", () => {
  it("shows the error when the first load fails", async () => {
    stubFetch(() => failure(500, { error: "internal", message: "boom" }));
    render(Editor, { id: 7, me });
    expect((await screen.findByRole("alert")).textContent).toBe("boom");
  });

  it("keeps a failed reload's error until a reload succeeds", async () => {
    let fail = false;
    stubFetch((c) => (c.method === "GET" && fail ? failure(500, { error: "internal", message: "boom" }) : detail()));
    render(Editor, { id: 7, me });
    const archive = await screen.findByRole("button", { name: "Archive" });
    fail = true;
    await user.click(archive);
    expect((await screen.findByRole("alert")).textContent).toBe("boom");
    await user.click(screen.getByRole("button", { name: "Archive" }));
    await vi.waitFor(() => expect(screen.getByRole("alert").textContent).toBe("boom"));
    fail = false;
    await user.click(screen.getByRole("button", { name: "Archive" }));
    await vi.waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  });
});

describe("Deck editor: gating by access", () => {
  const present = (name: string | RegExp, role = "button") => screen.queryByRole(role as "button", { name });
  async function open(access: Partial<Access>) {
    stubFetch(() => detail({ ...NONE, ...access }));
    render(Editor, { id: 7, me });
    await screen.findByRole("tab", { name: /^Sessions/ });
  }

  it("a viewer can do nothing but read", async () => {
    await open({});
    expect(present("Rename")).toBeNull();
    expect(present("Archive")).toBeNull();
    expect(present("Delete")).toBeNull();
    expect(present("Copy to my decks")).toBeNull();
    expect(present(/^Share/, "tab")).toBeNull();
    expect(present("Start session")).toBeNull();
    expect(screen.getByRole("heading", { name: "Intro to HtDP" })).toBeTruthy();
    await user.click(await tab(/^Polls/));
    expect(present("New poll")).toBeNull();
    expect(screen.queryByRole("button", { name: "Edit" })).toBeNull();
  });

  it("edit allows rename and poll changes, nothing owner-only", async () => {
    await open({ edit: true });
    expect(present("Rename")).toBeTruthy();
    expect(present("Archive")).toBeNull();
    expect(present("Delete")).toBeNull();
    await user.click(await tab(/^Polls/));
    expect(present("New poll")).toBeTruthy();
  });

  it("moderate allows sessions; results gates the history links", async () => {
    await open({ moderate: true });
    expect(present("Start session")).toBeTruthy();
    expect(screen.queryByRole("link", { name: "Results" })).toBeNull();
  });

  it("results shows Results and CSV for ended sessions", async () => {
    stubFetch(() => ({ ...detail({ ...NONE, results: true }), sessions: [{ ...fixture("session"), ended_at: "2026-11-15T11:00:00.000Z" }] }));
    render(Editor, { id: 7, me });
    expect(await screen.findByRole("link", { name: "Results" })).toBeTruthy();
    expect(screen.getByRole("link", { name: "CSV" })).toBeTruthy();
  });

  it("the owner gets everything, including the Share tab", async () => {
    stubFetch(() => ({ ...detail(OWNER), sessions: [] }));
    render(Editor, { id: 7, me });
    await screen.findByRole("tab", { name: /^Sessions/ });
    for (const n of ["Archive", "Delete", "Rename", "Copy to my decks"]) expect(present(n)).toBeTruthy();
    expect(present(/^Share/, "tab")).toBeTruthy();
  });
});

describe("Deck editor: copy", () => {
  it("copies and navigates to the new deck", async () => {
    const net = stubFetch((c) => (c.method === "POST" ? { ...fixture<object>("presentation"), id: 99 } : detail({ ...NONE, copy: true })));
    render(Editor, { id: 7, me });
    await user.click(await screen.findByRole("button", { name: "Copy to my decks" }));
    await vi.waitFor(() => expect(location.pathname).toBe("/decks/99"));
    expect(net.posts()).toEqual([{ method: "POST", url: `${URL_}/copy`, body: {} }]);
  });

  it("explains the quota and per-deck limits", async () => {
    let err = { error: "quota_exceeded", message: "raw" };
    stubFetch((c) => (c.method === "POST" ? failure(413, err) : detail({ ...NONE, copy: true })));
    render(Editor, { id: 7, me });
    const copy = await screen.findByRole("button", { name: "Copy to my decks" });
    await user.click(copy);
    expect((await screen.findByRole("alert")).textContent).toBe("Not enough storage left");
    err = { error: "too_large", message: "raw" };
    await user.click(copy);
    await vi.waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Deck over the 5 MB per-deck limit"));
  });
});

describe("Deck editor: delete", () => {
  const deleteBtn = () => screen.findByRole("button", { name: "Delete" });

  it("with sessions, needs the deck title typed before deleting", async () => {
    const net = stubFetch(() => detail());
    render(Editor, { id: 7, me });
    await user.click(await deleteBtn());
    expect((await screen.findByRole("alert")).textContent).toContain("permanently deleted");
    const go = screen.getByRole("button", { name: "Delete permanently" }) as HTMLButtonElement;
    expect(go.disabled).toBe(true);
    await user.type(screen.getByRole("textbox", { name: /Type the deck title/ }), "Intro to HtDP");
    expect(go.disabled).toBe(false);
    await user.click(go);
    await vi.waitFor(() => expect(net.posts()).toEqual([{ method: "DELETE", url: URL_, body: undefined }]));
  });

  it("without sessions, a plain confirm is enough", async () => {
    const net = stubFetch(() => ({ ...detail(), sessions: [] }));
    vi.stubGlobal("confirm", () => true);
    render(Editor, { id: 7, me });
    await user.click(await deleteBtn());
    await vi.waitFor(() => expect(net.posts()).toEqual([{ method: "DELETE", url: URL_, body: undefined }]));
    expect(screen.queryByRole("button", { name: "Delete permanently" })).toBeNull();
  });

  it("says to end the live session first on 409 session_live", async () => {
    stubFetch((c) => (c.method === "DELETE" ? failure(409, { error: "session_live", message: "raw" }) : detail()));
    render(Editor, { id: 7, me });
    await user.click(await deleteBtn());
    await user.type(screen.getByRole("textbox", { name: /Type the deck title/ }), "Intro to HtDP");
    await user.click(screen.getByRole("button", { name: "Delete permanently" }));
    await vi.waitFor(() => expect(screen.getAllByRole("alert").map((a) => a.textContent)).toContain("End the live session first"));
  });
});
