import { ApiError } from "./api";

/** Login URL when a probe error means the session expired (401), else null. */
export function loginRedirect(err: unknown, path: string): string | null {
  if (!(err instanceof ApiError) || err.status !== 401) return null;
  return `/login?return_to=${encodeURIComponent(path)}`;
}
