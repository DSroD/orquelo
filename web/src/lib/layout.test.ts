import { expect, it } from "vitest";
import { columnsFor } from "./layout";

it("columnsFor", () => {
  expect(columnsFor(2)).toBe(1);
  expect(columnsFor(6)).toBe(1);
  expect(columnsFor(7)).toBe(2);
  expect(columnsFor(12)).toBe(2);
  expect(columnsFor(13)).toBe("compact");
  expect(columnsFor(20)).toBe("compact");
  expect(columnsFor(21)).toBe("dense");
  expect(columnsFor(30)).toBe("dense");
});
