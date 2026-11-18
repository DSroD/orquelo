import { expect, it } from "vitest";
import { localDate, localDateTime, localTime } from "./time";

// built from local components, so the test holds in any time zone
const iso = new Date(2026, 0, 5, 9, 7).toISOString();
const midnight = new Date(2026, 11, 31, 0, 5).toISOString();

it("formats local date and 24 h time", () => {
  expect(localDate(iso)).toBe("2026-01-05");
  expect(localTime(iso)).toBe("09:07");
  expect(localDateTime(iso)).toBe("2026-01-05 09:07");
});

it("shows midnight as 00:xx, never 24:xx", () => {
  expect(localTime(midnight)).toBe("00:05");
  expect(localDateTime(midnight)).toBe("2026-12-31 00:05");
});
