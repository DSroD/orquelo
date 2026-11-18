import { afterEach, describe, expect, it, vi } from "vitest";
import { createRawSnippet } from "svelte";
import { render, screen } from "@testing-library/svelte";
import SignedIn from "./SignedIn.svelte";
import { failure, fixture, stubFetch } from "../test/net";
import type { Me } from "../lib/types";

afterEach(() => vi.unstubAllGlobals());
const page = () => render(SignedIn, { children: createRawSnippet((me: () => Me) => ({ render: () => `<p>hello ${me().user.name}</p>` })) });

describe("SignedIn", () => {
  it("renders the page for a signed-in user", async () => {
    stubFetch(() => fixture("me"));
    page();
    expect(await screen.findByText("hello Ada Teacher")).toBeTruthy();
  });

  it("redirects a 401 to /login with return_to", async () => {
    const hrefs: string[] = [];
    vi.stubGlobal("location", { pathname: "/decks/7", set href(v: string) { hrefs.push(v); } });
    stubFetch(() => failure(401, { error: "unauthorized", message: "no" }));
    page();
    await vi.waitFor(() => expect(hrefs).toEqual(["/login?return_to=%2Fdecks%2F7"]));
  });

  it("shows a suspended account page", async () => {
    stubFetch(() => failure(403, { error: "suspended", message: "no" }));
    page();
    expect(await screen.findByRole("heading", { name: "Account suspended" })).toBeTruthy();
  });
});
