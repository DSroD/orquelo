/** Percent per count. single: largest-remainder (sums to 100 when total>0); multi: plain rounding. */
export function percents(counts: number[], total: number, kind: "single" | "multi"): number[] {
  if (total <= 0) return counts.map(() => 0);
  const raw = counts.map((c) => (c / total) * 100);
  if (kind === "multi") return raw.map(Math.round);
  const floors = raw.map(Math.floor);
  let left = 100 - floors.reduce((s, n) => s + n, 0);
  const order = raw
    .map((r, i) => ({ i, frac: r - floors[i] }))
    .sort((x, y) => y.frac - x.frac || x.i - y.i);
  for (const { i } of order) {
    if (left-- <= 0) break;
    floors[i]++;
  }
  return floors;
}
