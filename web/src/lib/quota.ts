import { ApiError } from "./api";
import type { Me } from "./types";

const MIB = 1024 * 1024;
const GB = 1_000_000_000;
const oneDecimal = (n: number): string => String(Math.round(n * 10) / 10);

/** Bytes as MB with at most one decimal: 2097152 -> "2", 1572864 -> "1.5". */
export const mb = (bytes: number): string => oneDecimal(bytes / MIB);

const storageSize = (bytes: number): string =>
  bytes >= GB ? `${oneDecimal(bytes / GB)} GB` : `${mb(bytes)} MB`;

/** Shows usage against the quota, including the percentage when the quota is positive. */
export function usage(m: Me["membership"]): string {
  const used = storageSize(m.storage_used);
  if (m.storage_quota === null) return `${used} used`;
  const total = `${used} / ${storageSize(m.storage_quota)}`;
  if (m.storage_quota === 0) return total;
  const percent = Math.floor(m.storage_used * 100 / m.storage_quota);
  const label = percent === 0 && m.storage_used > 0 ? "<1%" : `${percent}%`;
  return `${total} · ${label} used`;
}

export const tooLargeMessage = (m: Me["membership"]): string => `Deck over the ${mb(m.max_upload_bytes)} MB per-deck limit`;

/** Upload or copy failure in the user's terms: size limits by name, anything else as the server said it. */
export function limitMessage(e: unknown, m: Me["membership"] | null): string {
  if (e instanceof ApiError && e.error === "too_large" && m) return tooLargeMessage(m);
  if (e instanceof ApiError && e.error === "quota_exceeded") return "Not enough storage left";
  return (e as Error).message;
}
