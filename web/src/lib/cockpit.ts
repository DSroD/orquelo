import { assertNever } from "./exhaustive";
import type { ModeratorOverlay, ModeratorSnapshot, Poll, RunSummary } from "./types";

// The overlay control mirrors the sum type: None | Poll | QR.
export type Choice = "none" | "poll" | "qr" | "qa";
// The one amber action: open a vote, then reveal its results, then close it.
export type Step = "open" | "reveal" | "close";

export const STEP_KEY: Record<Step, string> = { open: "o", reveal: "r", close: "c" };
export const STEP_LABEL: Record<Step, string> = { open: "Open poll", reveal: "Reveal results", close: "Close voting" };

export function choiceOf(o: ModeratorOverlay | null): Choice {
  if (o === null) return "none";
  switch (o.type) {
    case "poll": return "poll";
    case "qr": return "qr";
    case "qa": return "qa";
    default: return assertNever(o);
  }
}

export const voters = (n: number) => `${n} ${n === 1 ? "voter" : "voters"}`;

export const clampSlide = (n: number, pageCount: number) => Math.min(Math.max(n, 1), pageCount);

/** Everything the cockpit derives from the snapshot, the deck's polls and the pending actions.
 *  `can` is the single source of truth for "may this action run now", shared by buttons and shortcuts. */
export function cockpit(snap: ModeratorSnapshot | null, polls: Poll[], ended: boolean, busy: (k: string) => boolean) {
  const slide = snap?.stage.slide ?? 1;
  const overlay = snap?.stage.overlay ?? null;
  const cur = snap?.open_run ?? null;
  const choice = choiceOf(overlay);
  // Poll shows the open run, else the newest one; nothing to show before the first run
  const pollTarget = snap?.open_run?.run_id ?? snap?.runs[0]?.run_id ?? null;
  // Resume reopens the newest run, so only its poll offers it, and only once that run is closed
  const resumable: RunSummary | null = snap?.runs[0]?.closed_at ? snap.runs[0] : null;
  const hasRun = (pl: Poll) => !!snap?.runs.some((r) => r.poll_id === pl.id);
  const slidePolls = polls.filter((p) => p.slide === slide);
  const anyPolls = polls.filter((p) => p.slide === null);
  // the poll the `o` key and the primary Open button act on: first of this slide without a run
  const nextOpen = slidePolls.find((pl) => !hasRun(pl)) ?? null;
  const can = {
    prev: !ended && !busy("slide") && slide > 1,
    next: !ended && !busy("slide") && !!snap && slide < snap.presentation.page_count,
    open: !ended && !busy("poll/open") && nextOpen !== null,
    close: !ended && cur !== null && !busy("poll/close"),
    reveal: !ended && overlay?.type === "poll" && !busy("poll/reveal") && !busy("poll/hide"),
    overlay: !ended && !busy("overlay"),
    poll: !ended && !busy("overlay") && pollTarget !== null,
  };
  const nextStep = ((): Step | null => {
    if (ended) return null;
    if (cur === null) return nextOpen === null ? null : "open";
    return overlay?.type === "poll" && !overlay.revealed ? "reveal" : "close";
  })();
  // what the dock's main button says when there is no next step
  const idleLabel = ended ? "Session ended" : "No poll on this slide";
  return { slide, overlay, cur, choice, pollTarget, resumable, hasRun, slidePolls, anyPolls, nextOpen, nextStep, can, idleLabel };
}
