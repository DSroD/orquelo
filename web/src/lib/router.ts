import type { ExtRoute } from "./ext";

export type Route =
  | { name: "home" }
  | { name: "ext"; i: number; params: Record<string, string> }
  | { name: "audience"; pid: number; code: string }
  | { name: "screen"; pid: number; code: string }
  | { name: "login" }
  | { name: "connect"; id: string }
  | { name: "connected-apps" }
  | { name: "decks" }
  | { name: "deck"; id: number }
  | { name: "session-live"; code: string }
  | { name: "session-results"; code: string }
  | { name: "not-found" };

const CODE = /^[a-z2-7]{10}$/;
const PENDING_ID = /^[A-Za-z0-9_-]{43}$/;
const INT = /^[0-9]+$/;
export const CORE_RESERVED = ["api", "auth", "decks", "sessions", "screen", "assets", "healthz", "login", "connect", "connected-apps", "oauth", "mcp", ".well-known"];

/** Core routes come first and cannot be shadowed by an extension route; extension routes come before the audience route. */
export function match(pathname: string, ext: readonly ExtRoute[] = []): Route {
  const seg = pathname.split("/").filter(Boolean);
  const [a, b, c] = seg;
  if (seg.length === 0) return { name: "home" };
  if (a === "login") return seg.length === 1 ? { name: "login" } : { name: "not-found" };
  if (a === "connect") return seg.length === 2 && PENDING_ID.test(b) ? { name: "connect", id: b } : { name: "not-found" };
  if (a === "connected-apps") return seg.length === 1 ? { name: "connected-apps" } : { name: "not-found" };
  if (a === "decks") {
    if (seg.length === 1) return { name: "decks" };
    return seg.length === 2 && INT.test(b) ? { name: "deck", id: Number(b) } : { name: "not-found" };
  }
  if (a === "sessions" && CODE.test(b ?? "")) {
    if (seg.length === 2) return { name: "session-live", code: b };
    if (seg.length === 3 && c === "results") return { name: "session-results", code: b };
  }
  if (a === "sessions") return { name: "not-found" };
  if (a === "screen") {
    return seg.length === 3 && INT.test(b) && CODE.test(c)
      ? { name: "screen", pid: Number(b), code: c }
      : { name: "not-found" };
  }
  const i = ext.findIndex((r) => r.match(seg) !== null);
  if (i >= 0) return { name: "ext", i, params: ext[i].match(seg)! };
  if (seg.length === 2 && !CORE_RESERVED.includes(a) && INT.test(a) && CODE.test(b)) {
    return { name: "audience", pid: Number(a), code: b };
  }
  return { name: "not-found" };
}

export function navigate(path: string) {
  history.pushState(null, "", path);
  window.dispatchEvent(new PopStateEvent("popstate"));
}

/** A same-site path to come back to after login; anything else falls back to /decks. */
export function safeReturnTo(p: string | null): string {
  return p && p.startsWith("/") && !p.startsWith("//") ? p : "/decks";
}
