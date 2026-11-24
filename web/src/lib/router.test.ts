import { describe, expect, it } from "vitest";
import ext from "$ext";
import { match } from "./router";

const code = "abcde23456";

describe("router.match", () => {
  it("matches every route", () => {
    expect(match("/")).toEqual({ name: "home" });
    expect(match(`/7/${code}`)).toEqual({ name: "audience", pid: 7, code });
    expect(match(`/screen/7/${code}`)).toEqual({ name: "screen", pid: 7, code });
    expect(match("/login")).toEqual({ name: "login" });
    expect(match("/login/x").name).toBe("not-found");
    expect(match("/decks")).toEqual({ name: "decks" });
    expect(match("/decks/")).toEqual({ name: "decks" });
    expect(match("/decks/12")).toEqual({ name: "deck", id: 12 });
    expect(match(`/sessions/${code}`)).toEqual({ name: "session-live", code });
    expect(match(`/sessions/${code}/results`)).toEqual({ name: "session-results", code });
  });
  it("matches the OAuth pages", () => {
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    expect(match(`/connect/${id}`)).toEqual({ name: "connect", id });
    expect(match("/connect/short").name).toBe("not-found");
    expect(match(`/connect/${id}/x`).name).toBe("not-found");
    expect(match("/connect").name).toBe("not-found");
    expect(match("/connected-apps")).toEqual({ name: "connected-apps" });
    expect(match("/connected-apps/x").name).toBe("not-found");
  });
  it("serves /account through core's own extension", () => {
    expect(match("/account", ext.routes)).toEqual({ name: "ext", i: 0, params: {} });
  });
  it("rejects reserved first segments", () => {
    for (const r of ["api", "auth", "decks", "screen", "assets", "healthz", "login"]) {
      expect(match(`/${r}/${code}`).name).toBe("not-found");
    }
  });
  it("rejects bad codes and ids", () => {
    expect(match("/7/ABCDE23456").name).toBe("not-found");
    expect(match("/7/abcde1").name).toBe("not-found");
    expect(match("/7/abcde89019").name).toBe("not-found");
    expect(match(`/x/${code}`).name).toBe("not-found");
    expect(match(`/screen/x/${code}`).name).toBe("not-found");
    expect(match("/decks/x").name).toBe("not-found");
    expect(match("/sessions/short").name).toBe("not-found");
    expect(match(`/sessions/${code}/other`).name).toBe("not-found");
    expect(match(`/sessions/${code}/results/x`).name).toBe("not-found");
    expect(match("/sessions/short/results").name).toBe("not-found");
  });
  it("routes to extension pages without letting them shadow core", () => {
    const ext = [
      { match: (s: readonly string[]) => (s.length === 1 && s[0] === "x" ? {} : s[0] === "decks" ? {} : null), load: async () => ({ default: null as any }) },
    ];
    expect(match("/x", ext)).toEqual({ name: "ext", i: 0, params: {} });
    expect(match("/x/extra", ext).name).toBe("not-found");
    expect(match("/decks", ext)).toEqual({ name: "decks" });
  });
});
