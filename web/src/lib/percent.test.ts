import { describe, expect, it } from "vitest";
import { percents } from "./percent";

const sum = (a: number[]) => a.reduce((s, n) => s + n, 0);

describe("percents", () => {
  it("single sums to 100 (thirds)", () => {
    const p = percents([1, 1, 1], 3, "single");
    expect(sum(p)).toBe(100);
    expect(p).toEqual([34, 33, 33]);
  });
  it("single handles ties deterministically", () => {
    expect(percents([1, 1], 2, "single")).toEqual([50, 50]);
    expect(sum(percents([2, 2, 2, 1], 7, "single"))).toBe(100);
  });
  it("zero voters yields zeros", () => {
    expect(percents([0, 0], 0, "single")).toEqual([0, 0]);
    expect(percents([0, 0], 0, "multi")).toEqual([0, 0]);
  });
  it("multi rounds independently", () => {
    expect(percents([21, 3, 18], 27, "multi")).toEqual([78, 11, 67]);
    expect(percents([3, 3], 3, "multi")).toEqual([100, 100]);
  });
});
