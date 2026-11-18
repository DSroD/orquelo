import { describe, expect, it } from "vitest";
import { ApiError } from "./api";
import { limitMessage, mb, usage } from "./quota";
import { fixture } from "../test/net";
import type { Me } from "./types";

const membership = fixture<Me>("me").membership;
const unlimited = fixture<Me>("me-unlimited").membership;

describe("quota text", () => {
  it("formats MB with at most one decimal", () => {
    expect(mb(2097152)).toBe("2");
    expect(mb(1572864)).toBe("1.5");
    expect(usage(membership)).toBe("2 / 32 MB");
  });

  it("omits the quota when it is unlimited", () => {
    expect(usage(unlimited)).toBe("2 MB used");
  });

  it("names the size limit for too_large and the storage for quota_exceeded", () => {
    expect(limitMessage(new ApiError(413, "too_large", "x"), membership)).toBe("Deck over the 5 MB per-deck limit");
    expect(limitMessage(new ApiError(413, "quota_exceeded", "x"), membership)).toBe("Not enough storage left");
    expect(limitMessage(new ApiError(500, "internal", "boom"), membership)).toBe("boom");
  });
});
