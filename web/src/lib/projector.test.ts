import { describe, expect, it } from "vitest";
import { projectorAdvance, projectorDwell, projectorOptions, projectorPages } from "./projector";

const options = [
  { id: 1, label: "Zebra", count: 1 },
  { id: 2, label: "Alpha", count: 1 },
  { id: 3, label: "Beta", count: 1 },
  { id: 4, label: "None", count: 0 },
];

describe("projector results", () => {
  it("calculates rounding in original option order before alphabetical tie sorting", () => {
    const rows = projectorOptions(options, 3, "single", true);
    expect(rows.map((row) => [row.label, row.rank, row.percent])).toEqual([
      ["Alpha", 1, 33], ["Beta", 1, 33], ["Zebra", 1, 34], ["None", 4, 0],
    ]);
  });
  it("keeps hidden results and zero-voter results in authored order without ranks", () => {
    for (const [total, revealed] of [[3, false], [0, true]] as const) {
      const rows = projectorOptions(options, total, "single", revealed);
      expect(rows.map((row) => row.id)).toEqual([1, 2, 3, 4]);
      expect(rows.map((row) => row.rank)).toEqual([null, null, null, null]);
    }
  });
  it("keeps multi-choice denominators across paginated subsets", () => {
    const rows = projectorOptions(options, 1, "multi", true);
    const pages = projectorPages(rows, [60, 60, 60, 60], 130, 10, true);
    expect(pages[0].options.map((row) => row.percent)).toEqual([100, 100]);
    expect(pages[0].cutoffTies).toBe(1);
    expect(pages.flatMap((page) => page.options.map((row) => row.id))).toEqual(rows.map((row) => row.id));
  });
  it("leaves fitting polls on one view with all answers", () => {
    const rows = projectorOptions(options, 3, "single", true);
    const pages = projectorPages(rows, [20, 20, 20, 20], 110, 10, true);
    expect(pages).toHaveLength(1);
    expect(pages[0].leaders).toBe(false);
    expect(pages[0].options).toHaveLength(4);
  });
  it("caps the leading view at three positive answers without omitting the remainder", () => {
    const rows = projectorOptions(Array.from({ length: 10 }, (_, id) => ({ id, label: String(id), count: 1 })), 10, "single", true);
    const pages = projectorPages(rows, Array(10).fill(20), 120, 10, true);
    expect(pages[0].options).toHaveLength(3);
    expect(pages[0].cutoffTies).toBe(7);
    expect(pages.flatMap((page) => page.options)).toEqual(rows);
    expect(pages.slice(1).every((page) => !page.leaders)).toBe(true);
  });
  it("does not put zero-count answers in the leading view", () => {
    const rows = projectorOptions(options.map((option, index) => ({ ...option, count: index === 0 ? 1 : 0 })), 1, "single", true);
    expect(projectorPages(rows, [20, 20, 20, 20], 70, 10, true)[0].options).toHaveLength(1);
  });
  it("allows enough reading time for long unbroken labels", () => {
    const rows = projectorOptions([{ id: 1, label: "W".repeat(200), count: 0 }], 0, "single", false);
    expect(projectorDwell("Question", rows, false)).toBe(12000);
    expect(projectorDwell("W".repeat(500), rows, true)).toBe(39000);
  });
  it("handles coalesced commands and backwards baselines", () => {
    expect(projectorAdvance(4, 7, 1, 3)).toEqual({ index: 1, wrapped: true });
    expect(projectorAdvance(7, 1, 1, 3)).toEqual({ index: 1, wrapped: false });
    expect(projectorAdvance(4, 6, 1, 4)).toEqual({ index: 3, wrapped: false });
  });
});
