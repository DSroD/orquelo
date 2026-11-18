import { ApiError } from "./api";
import type { Me } from "./types";

const MIB = 1024 * 1024;

/** Bytes as MB with at most one decimal: 2097152 -> "2", 1572864 -> "1.5". */
export const mb = (bytes: number): string => String(Math.round((bytes / MIB) * 10) / 10);

/** Storage strip text, e.g. "2 / 32 MB"; just "2 MB used" when the quota is unlimited. */
export const usage = (m: Me["membership"]): string =>
  m.storage_quota === null ? `${mb(m.storage_used)} MB used` : `${mb(m.storage_used)} / ${mb(m.storage_quota)} MB`;

export const tooLargeMessage = (m: Me["membership"]): string => `Deck over the ${mb(m.max_upload_bytes)} MB per-deck limit`;

/** Upload or copy failure in the user's terms: size limits by name, anything else as the server said it. */
export function limitMessage(e: unknown, m: Me["membership"] | null): string {
  if (e instanceof ApiError && e.error === "too_large" && m) return tooLargeMessage(m);
  if (e instanceof ApiError && e.error === "quota_exceeded") return "Not enough storage left";
  return (e as Error).message;
}
