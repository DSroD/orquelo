export const NONE = "—";

/** 0..1 fraction or null -> "90%" or "—" */
export const formatParticipation = (p: number | null): string => (p === null ? NONE : `${Math.round(p * 100)}%`);

/** seconds or null -> "12.5 s", "1 m 05 s" or "—" */
export function formatSeconds(s: number | null): string {
  if (s === null) return NONE;
  if (s < 60) return `${Math.round(s * 10) / 10} s`;
  const t = Math.round(s);
  return `${Math.floor(t / 60)} m ${String(t % 60).padStart(2, "0")} s`;
}

/** ISO open/close times -> "5 min", "1 h 05 min", "<1 min", or "—" while still open */
export function formatDuration(opened: string, closed: string | null): string {
  if (closed === null) return NONE;
  const min = Math.round((Date.parse(closed) - Date.parse(opened)) / 60000);
  if (min < 1) return "<1 min";
  return min < 60 ? `${min} min` : `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, "0")} min`;
}
