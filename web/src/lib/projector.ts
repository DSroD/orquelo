import { percents } from "./percent";
import type { CountedOption, PollKind } from "./types";

export interface ProjectorOption extends CountedOption { percent: number; rank: number | null }
export interface ProjectorPage { options: ProjectorOption[]; leaders: boolean; cutoffTies: number }
const names = new Intl.Collator("en", { numeric: true, sensitivity: "base" });

/** Calculate percentages before sorting, preserving the contract's rounding order. */
export function projectorOptions(options: CountedOption[], total: number, kind: PollKind, revealed: boolean): ProjectorOption[] {
  const percentages = percents(options.map((option) => option.count), total, kind);
  const rows = options.map((option, index) => ({ ...option, percent: percentages[index], rank: null as number | null }));
  if (!revealed || total === 0) return rows;
  rows.sort((a, b) => b.count - a.count || names.compare(a.label, b.label));
  let rank = 0;
  return rows.map((option, index) => {
    if (index === 0 || option.count !== rows[index - 1].count) rank = index + 1;
    return { ...option, rank };
  });
}

/** Pack complete measured rows; only overflowing, revealed votes get a leading view. */
export function projectorPages(options: ProjectorOption[], heights: number[], available: number, gap: number, revealed: boolean): ProjectorPage[] {
  const pages: ProjectorPage[] = [];
  let start = 0;
  while (start < options.length) {
    let end = start;
    let used = 0;
    const leaders = pages.length === 0 && revealed && options.some((option) => option.count > 0)
      && heights.reduce((sum, height) => sum + height, 0) + gap * (options.length - 1) > available;
    while (end < options.length) {
      const next = heights[end] + (end > start ? gap : 0);
      if (end > start && (used + next > available || (leaders && (end - start === 3 || options[end].count === 0)))) break;
      used += next;
      end++;
    }
    const last = options[end - 1];
    const cutoffTies = leaders && last.count > 0 ? options.slice(end).filter((option) => option.count === last.count).length : 0;
    pages.push({ options: options.slice(start, end), leaders, cutoffTies });
    start = end;
  }
  return pages;
}

/** Allow a full reading of the first question and each view's answers, at 180 words/minute. */
export function projectorDwell(question: string, options: ProjectorOption[], first: boolean): number {
  const text = [...(first ? [question] : []), ...options.map((option) => option.label)].join(" ");
  // Character count also accounts for long unbroken labels and languages without spaces.
  const words = Math.max(text.trim().split(/\s+/u).length, Math.ceil(text.length / 6));
  return Math.max(12000, Math.ceil(words / 3) * 1000);
}

/** Historical commands establish the baseline; coalesced increments advance every requested view. */
export function projectorAdvance(previous: number, current: number, index: number, length: number): { index: number; wrapped: boolean } {
  const delta = Math.max(0, current - previous);
  return { index: length ? (index + delta) % length : 0, wrapped: length > 0 && index + delta >= length };
}
