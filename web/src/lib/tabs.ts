/** Index of the tab a key moves to (arrows wrap, Home/End jump), or null for any other key. */
export function nextTabIndex(count: number, i: number, key: string): number | null {
  const j = key === "ArrowRight" ? i + 1 : key === "ArrowLeft" ? i - 1 : key === "Home" ? 0 : key === "End" ? count - 1 : null;
  return j === null ? null : (j + count) % count;
}
