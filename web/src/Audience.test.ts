import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import Audience from "./Audience.svelte";
import { FakeEventSource, failure, fixture, stubEventSource, stubFetch } from "./test/net";
import type { AudienceSnapshot } from "./lib/types";

const user = userEvent.setup();
const code = "abcde23456";
const multi = (): AudienceSnapshot => ({
  ...fixture<AudienceSnapshot>("audience-no-vote"),
  poll: {
    run_id: 12, question: "Choose your answers", kind: "multi", open: true,
    options: [{ id: 1, label: "A", exclusive: false }, { id: 2, label: "B", exclusive: false }, { id: 3, label: "Unknown", exclusive: true }, { id: 4, label: "Other", exclusive: true }],
  },
});
async function open(snap: AudienceSnapshot, handler: Parameters<typeof stubFetch>[0] = () => ({})) {
  const net = stubFetch(handler);
  render(Audience, { pid: 7, code });
  FakeEventSource.last().emit("snapshot", snap);
  await screen.findByText("Intro to HtDP · Class A");
  return net;
}
const push = (snap: AudienceSnapshot) => FakeEventSource.last().emit("snapshot", snap);
const checkbox = (name: string | RegExp) => screen.getByRole("checkbox", { name }) as HTMLButtonElement;

beforeEach(stubEventSource);
afterEach(() => vi.unstubAllGlobals());

it("shows when the audience is full and joins on the next snapshot", async () => {
  stubFetch(() => ({}));
  render(Audience, { pid: 7, code });
  FakeEventSource.last().emit("audience-full", {});
  expect(await screen.findByRole("heading", { name: "This session is full" })).toBeTruthy();
  push(fixture<AudienceSnapshot>("audience-idle"));
  expect(await screen.findByText("Intro to HtDP · Class A")).toBeTruthy();
  expect(screen.queryByRole("heading", { name: "This session is full" })).toBeNull();
});

describe("Audience exclusive answers", () => {
  it("blocks conflicts until the current selection is cleared", async () => {
    await open(multi());
    await user.click(checkbox("A"));
    expect(checkbox(/Unknown/).disabled).toBe(true);
    expect(checkbox("B").disabled).toBe(false);
    await user.click(checkbox("A"));
    await user.click(checkbox(/Unknown/));
    expect(checkbox("A").disabled).toBe(true);
    expect(checkbox("B").disabled).toBe(true);
    expect(checkbox(/Other/).disabled).toBe(true);
    expect(checkbox(/Unknown/).disabled).toBe(false);
    await user.click(checkbox(/Unknown/));
    expect(checkbox("A").disabled).toBe(false);
  });

  it("keeps a draft when another option arrives and submits run-local IDs", async () => {
    const snap = multi();
    const net = await open(snap);
    await user.click(checkbox("A"));
    push({ ...snap, poll: { ...snap.poll!, options: [...snap.poll!.options, { id: 9, label: "Added live", exclusive: false }] } });
    expect(await screen.findByRole("checkbox", { name: "Added live" })).toBeTruthy();
    expect(checkbox("A").getAttribute("aria-checked")).toBe("true");
    await user.click(checkbox("Added live"));
    await user.click(screen.getByRole("button", { name: "Submit (2)" }));
    expect(net.posts()[0]).toEqual({ method: "POST", url: `/api/s/7/${code}/vote`, body: { run_id: 12, option_ids: [1, 9] } });
  });
});

describe("Audience Q&A", () => {
  it("appears on first opening and stays read-only after closing", async () => {
    const snap = fixture<AudienceSnapshot>("audience-qa");
    await open({ ...snap, qa: { ...snap.qa, started: false, open: false, questions: [] } });
    expect(screen.queryByRole("tab", { name: "Q&A" })).toBeNull();
    push(snap);
    await user.click(await screen.findByRole("tab", { name: "Q&A" }));
    expect(await screen.findByRole("textbox", { name: "Your question" })).toBeTruthy();
    push({ ...snap, qa: { ...snap.qa, open: false } });
    expect(await screen.findByText("Submissions are closed. Your questions stay below.")).toBeTruthy();
    expect(screen.queryByRole("textbox", { name: "Your question" })).toBeNull();
    expect(screen.getByText(snap.qa.questions[0].text)).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Q&A" })).toBeTruthy();
  });

  it("posts trimmed question text", async () => {
    const snap = fixture<AudienceSnapshot>("audience-qa");
    const net = await open(snap);
    await user.click(await screen.findByRole("tab", { name: "Q&A" }));
    await user.type(screen.getByRole("textbox", { name: "Your question" }), "  Could you explain this?  ");
    await user.click(screen.getByRole("button", { name: "Send question" }));
    expect(net.posts()[0]).toEqual({ method: "POST", url: `/api/s/7/${code}/qa`, body: { text: "Could you explain this?" } });
  });

  it("keeps an unsent question when submissions close or a request fails", async () => {
    const snap = fixture<AudienceSnapshot>("audience-qa");
    await open(snap, ({ method }) => method === "POST"
      ? failure(429, { error: "rate_limited", message: "Wait before sending another question." })
      : { remember: false });
    await user.click(await screen.findByRole("tab", { name: "Q&A" }));
    const input = screen.getByRole("textbox", { name: "Your question" }) as HTMLTextAreaElement;
    await user.type(input, "Please explain");
    await user.click(screen.getByRole("button", { name: "Send question" }));
    expect((await screen.findByRole("alert")).textContent).toBe("Wait before sending another question.");
    expect(input.value).toBe("Please explain");
    push({ ...snap, qa: { ...snap.qa, open: false } });
    await screen.findByText("Submissions are closed. Your questions stay below.");
    push(snap);
    expect((await screen.findByRole("textbox", { name: "Your question" }) as HTMLTextAreaElement).value).toBe("Please explain");
  });
});
