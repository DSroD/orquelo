import { describe, expect, it } from "vitest";
import { accessTag } from "./accessTag";

describe("accessTag", () => {
  const a = { owner: false, edit: false, moderate: false, copy: false, results: false };
  it("lists the flags of a share, and nothing for the owner", () => {
    expect(accessTag({ ...a, edit: true, moderate: true })).toBe("shared · edit moderate");
    expect(accessTag(a)).toBe("shared · view");
    expect(accessTag({ ...a, owner: true, edit: true })).toBeNull();
  });
});
