import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import { tick } from "svelte";
import ProjectorPoll from "../components/ProjectorPoll.svelte";
import type { ScreenPollOverlay } from "./types";

const poll = (): ScreenPollOverlay => ({
  type: "poll", run_id: 1, question: "Choose", kind: "single", open: true, revealed: true,
  total_voters: 5, options: Array.from({ length: 5 }, (_, index) => ({ id: index, label: `Answer ${index}`, count: 1 })),
});
const settle = async () => { await tick(); await tick(); await tick(); };
const visibleLabels = () => screen.getAllByRole("listitem").map((element) => element.textContent);

beforeEach(() => {
  vi.useFakeTimers();
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockImplementation(function(this: HTMLElement) {
    return this.classList.contains("answers") ? 96 : 720;
  });
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function(this: HTMLElement) {
    return { height: this.tagName === "LI" ? 40 : 720, width: 1000, x: 0, y: 0, top: 0, bottom: 0, left: 0, right: 0, toJSON() {} };
  });
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

it("applies remote pause initially without replaying old commands and handles coalesced Next", async () => {
  const view = render(ProjectorPoll, { poll: poll(), joinUrl: "https://example.com/join", rotation: { paused: true, advance: 7 } });
  await settle();
  expect(screen.getByText(/View 1 \/ 3 · paused/)).toBeTruthy();
  await vi.advanceTimersByTimeAsync(60000);
  expect(screen.getByText(/View 1 \/ 3 · paused/)).toBeTruthy();
  await view.rerender({ poll: poll(), joinUrl: "https://example.com/join", rotation: { paused: true, advance: 9 } });
  await settle();
  expect(screen.getByText(/View 3 \/ 3 · paused/)).toBeTruthy();
  expect(visibleLabels()).toHaveLength(1);
  await view.rerender({ poll: poll(), joinUrl: "https://example.com/join", rotation: { paused: false, advance: 9 } });
  await settle();
  await vi.advanceTimersByTimeAsync(12000);
  expect(screen.getByText(/View 1 \/ 3/)).toBeTruthy();
});

it("freezes statistics until the complete rotation finishes", async () => {
  const initial = poll();
  const view = render(ProjectorPoll, { poll: initial, joinUrl: "https://example.com/join", rotation: { paused: true, advance: 0 } });
  await settle();
  const updated = { ...initial, total_voters: 10, options: initial.options.map((option) => ({ ...option, count: 2 })) };
  await view.rerender({ poll: updated, joinUrl: "https://example.com/join", rotation: { paused: true, advance: 0 } });
  await settle();
  expect(screen.getByText(/^5 votes/)).toBeTruthy();
  expect(visibleLabels().every((label) => label?.includes("1 · 20%"))).toBe(true);
  await view.rerender({ poll: updated, joinUrl: "https://example.com/join", rotation: { paused: true, advance: 3 } });
  await settle();
  expect(screen.getByText(/^10 votes/)).toBeTruthy();
  expect(visibleLabels().every((label) => label?.includes("2 · 20%"))).toBe(true);
});

it("keeps fitting one-view results live", async () => {
  const initial = { ...poll(), total_voters: 1, options: [{ id: 1, label: "Only answer", count: 1 }] };
  const view = render(ProjectorPoll, { poll: initial, joinUrl: "https://example.com/join" });
  await settle();
  await view.rerender({ poll: { ...initial, total_voters: 2, options: [{ id: 1, label: "Only answer", count: 2 }] }, joinUrl: "https://example.com/join" });
  await settle();
  expect(screen.getByText(/^2 votes/)).toBeTruthy();
  expect(visibleLabels()[0]).toContain("2 · 100%");
  expect(screen.queryByText(/View \d/)).toBeNull();
});
