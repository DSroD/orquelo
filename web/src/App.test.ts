import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import App from "./App.svelte";
import { fixture, stubFetch } from "./test/net";
import type { Me } from "./lib/types";

afterEach(() => { vi.unstubAllGlobals(); history.replaceState(null, "", "/"); });

describe("App with core's extension", () => {
  it("sends / to the decks, since there is no home page", async () => {
    stubFetch(() => []);
    render(App);
    await vi.waitFor(() => expect(location.pathname).toBe("/decks"));
  });

  it("serves /account", async () => {
    history.replaceState(null, "", "/account");
    stubFetch(() => fixture<Me>("me"));
    render(App);
    expect(await screen.findByRole("heading", { name: "Account" })).toBeTruthy();
  });
});
