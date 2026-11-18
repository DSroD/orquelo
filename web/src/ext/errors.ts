import { ApiError } from "../lib/api";

/** Text for a failed request that none of the page's own cases handled. */
export function genericMessage(e: unknown): string {
  if (!(e instanceof ApiError)) return "Could not reach the server.";
  if (e.status === 429) return e.retryAfter ? `Too many attempts. Try again in ${e.retryAfter} s.` : "Too many attempts. Try again later.";
  return e.message;
}
