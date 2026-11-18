export type Columns = 1 | 2 | "compact" | "dense";

/** 1 column up to 6 options, 2 up to 12, compact (2 small) up to 20, dense (3 small) beyond. */
export function columnsFor(n: number): Columns {
  if (n <= 6) return 1;
  if (n <= 12) return 2;
  if (n <= 20) return "compact";
  return "dense";
}
