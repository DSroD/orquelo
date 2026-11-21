import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import App from "./App.svelte";
import { navigate } from "./lib/router";
import { stubFetch } from "./test/net";

vi.mock("$ext", () => ({
  default: {
    routes: [
      { match: (s: string[]) => (s.length === 1 && s[0] === "terms" ? { page: s[0] } : null), load: () => import("./test/ParamRoute.svelte") },
      { match: (s: string[]) => (s.length === 1 && s[0] === "plain" ? {} : null), load: () => import("./test/PlainRoute.svelte") },
    ],
    Login: () => import("./ext/Login.svelte"),
    navigation: [],
  },
}));

afterEach(() => { vi.unstubAllGlobals(); history.replaceState(null, "", "/"); });

describe("App with an edition's routes", () => {
  it("moves from a route with params to one without", async () => {
    history.replaceState(null, "", "/terms");
    stubFetch(() => null);
    render(App);
    expect(await screen.findByRole("heading", { name: "Param TERMS" })).toBeTruthy();
    navigate("/plain");
    expect(await screen.findByRole("heading", { name: "Plain" })).toBeTruthy();
  });
});
