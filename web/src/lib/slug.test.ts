import { expect, test } from "vitest";
import { slug } from "./slug";

test("slug lowercases and hyphenates, keeping diacritics", () => {
  expect(slug("Audit deck")).toBe("audit-deck");
  expect(slug("  Úvod  do   práva ")).toBe("úvod-do-práva");
  expect(slug("   ")).toBe("untitled");
});
