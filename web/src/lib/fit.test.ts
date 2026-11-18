import { expect, it } from "vitest";
import { fitScale } from "./fit";

const box = (h: number) => (s: number) => ({ scrollHeight: 1000 * s, clientHeight: h });

it("keeps full size when content fits", () => expect(fitScale(box(1000))).toBe(1));
it("steps down until it fits", () => expect(fitScale(box(700))).toBe(0.65));
it("stops at the floor", () => expect(fitScale(box(10))).toBe(0.42));
