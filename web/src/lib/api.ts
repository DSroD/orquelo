import { loginRedirect } from "./expired";
import type { ApiErrorBody, Me } from "./types";

export class ApiError extends Error {
  constructor(public status: number, public error: string, message: string, public field?: string, public retryAfter?: number) {
    super(message);
  }
}

async function toError(res: Response): Promise<ApiError> {
  let body: Partial<ApiErrorBody> = {};
  try { body = await res.json(); } catch { /* non-JSON */ }
  return new ApiError(res.status, body.error ?? "internal", body.message ?? res.statusText, body.field, Number(res.headers.get("Retry-After")) || undefined);
}

export async function request<T>(method: string, url: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, credentials: "same-origin", headers: {} };
  if (body instanceof FormData) init.body = body;
  else if (body !== undefined) {
    (init.headers as Record<string, string>)["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const res = await fetch(url, init);
  if (!res.ok) throw await toError(res);
  if (res.status === 204) return undefined as T;
  return res.json();
}

export const get = <T>(url: string) => request<T>("GET", url);
export const post = <T = void>(url: string, body?: unknown) => request<T>("POST", url, body ?? {});
export const put = <T>(url: string, body: unknown) => request<T>("PUT", url, body);
export const patch = <T>(url: string, body: unknown) => request<T>("PATCH", url, body);
export const del = (url: string) => request<void>("DELETE", url);

/** Signed-in guard: redirects to the login page on 401 (never resolving), otherwise returns the signed-in user. */
export async function requireUser(): Promise<Me> {
  try {
    return await get<Me>("/api/me");
  } catch (e) {
    const to = loginRedirect(e, location.pathname);
    if (to) {
      location.href = to;
      return new Promise(() => {});
    }
    throw e;
  }
}
