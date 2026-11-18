import { describe, expect, it } from "vitest";
import { formatDuration, formatParticipation, formatSeconds } from "./results";

describe("formatParticipation", () => {
  it("formats fractions and null", () => {
    expect(formatParticipation(0.9)).toBe("90%");
    expect(formatParticipation(0.855)).toBe("86%");
    expect(formatParticipation(1)).toBe("100%");
    expect(formatParticipation(null)).toBe("—");
  });
});
describe("formatSeconds", () => {
  it("formats seconds, minutes and null", () => {
    expect(formatSeconds(12.5)).toBe("12.5 s");
    expect(formatSeconds(9)).toBe("9 s");
    expect(formatSeconds(65)).toBe("1 m 05 s");
    expect(formatSeconds(null)).toBe("—");
  });
});
describe("formatDuration", () => {
  const t = (m: string) => `2026-11-15T10:${m}:00.000Z`;
  it("formats minutes, hours and open runs", () => {
    expect(formatDuration(t("20"), t("25"))).toBe("5 min");
    expect(formatDuration(t("20"), t("20"))).toBe("<1 min");
    expect(formatDuration(t("00"), "2026-11-15T11:05:00.000Z")).toBe("1 h 05 min");
    expect(formatDuration(t("20"), null)).toBe("—");
  });
});
