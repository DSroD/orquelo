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
  });

  it("shows storage usage and the percentage of the quota", () => {
    expect(usage(membership)).toBe("2 MB / 32 MB · 6% used");
    const pro = { ...membership, storage_quota: 10_000_000_000 };
    expect(usage(pro)).toBe("2 MB / 10 GB · <1% used");
    expect(usage({ ...pro, storage_used: 3_500_000_000 })).toBe("3.5 GB / 10 GB · 35% used");
    expect(usage({ ...pro, storage_used: 0 })).toBe("0 MB / 10 GB · 0% used");
    expect(usage({ ...membership, storage_quota: 0 })).toBe("2 MB / 0 MB");
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
