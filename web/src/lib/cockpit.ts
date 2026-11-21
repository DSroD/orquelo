import { assertNever } from "./exhaustive";
import type { ModeratorOverlay, ModeratorSnapshot, Poll, RunSummary } from "./types";

// The overlay control mirrors the sum type: None | Poll | QR.
export type Choice = "none" | "poll" | "qr" | "qa";
export type Step = "open" | "show" | "reveal" | "close";

export const STEP_KEY: Record<Step, string> = { open: "o", show: "p", reveal: "r", close: "c" };
export const STEP_LABEL: Record<Step, string> = { open: "Open poll", show: "Show current poll", reveal: "Reveal results", close: "Close voting" };

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
export function cockpit(snap: ModeratorSnapshot | null, polls: Poll[], ended: boolean, connected: boolean, busy: (k: string) => boolean) {
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
  const liveOnScreen = cur !== null && overlay?.type === "poll" && cur.run_id === overlay.run_id;
  const canChangeStage = !!snap && connected && !ended && !busy("stage");
  const canStart = canChangeStage && cur === null;
  const can = {
    prev: !ended && !busy("slide") && slide > 1,
    next: !ended && !busy("slide") && !!snap && slide < snap.presentation.page_count,
    open: canStart && nextOpen !== null,
    show: canChangeStage && cur !== null && !liveOnScreen,
    close: canChangeStage && cur !== null,
    reveal: canChangeStage && overlay?.type === "poll",
    overlay: canChangeStage,
    poll: canChangeStage && pollTarget !== null,
  };
  const nextStep = ((): Step | null => {
    if (ended) return null;
    if (cur === null) return nextOpen === null ? null : "open";
    if (!liveOnScreen) return "show";
    return overlay.revealed ? "close" : "reveal";
  })();
  // what the dock's main button says when there is no next step
  const idleLabel = ended ? "Session ended" : slidePolls.length || anyPolls.length ? "Choose a poll below" : "No poll on this slide";
  return { slide, overlay, cur, choice, pollTarget, resumable, hasRun, slidePolls, anyPolls, nextOpen, nextStep, can, canStart, liveOnScreen, idleLabel };
}
