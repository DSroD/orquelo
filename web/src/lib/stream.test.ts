import { expect, it } from "vitest";
import { nextDelay } from "./stream";

it("nextDelay backs off 1s..15s", () => {
  expect([0, 1, 2, 3, 4].map(nextDelay)).toEqual([1000, 2000, 4000, 8000, 15000]);
  expect(nextDelay(10)).toBe(15000);
  expect(nextDelay(-1)).toBe(1000);
});
