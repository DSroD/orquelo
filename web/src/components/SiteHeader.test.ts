import { afterEach, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/svelte";
import type { NavigationLink } from "../lib/ext";
import { deferred, failure, fixture, stubFetch } from "../test/net";
import SiteHeader from "./SiteHeader.svelte";

const props = {
  path: "/pricing",
  home: "/",
  links: [
    { href: "/pricing", label: "Pricing" },
    { href: "/account", label: "Account", when: "signed-in" },
  ] satisfies NavigationLink[],
};

afterEach(() => {
  history.replaceState(null, "", "/");
  vi.unstubAllGlobals();
});

it("shows public links while checking the session, then offers login to a visitor", async () => {
  const session = deferred<Response>();
  stubFetch(() => session.promise);
  render(SiteHeader, props);
  expect(screen.getByRole("link", { name: "Pricing" }).getAttribute("aria-current")).toBe("page");
  expect(screen.queryByRole("link", { name: "Log in" })).toBeNull();
  session.resolve(failure(401, {}));
  expect((await screen.findByRole("link", { name: "Log in" })).getAttribute("href")).toBe("/login");
  expect(screen.queryByRole("link", { name: "Account" })).toBeNull();
});

it("shows signed-in links and logs out from the header", async () => {
  const net = stubFetch(({ url }) => url === "/api/me" ? fixture("me") : new Response(null, { status: 204 }));
  render(SiteHeader, props);
  expect((await screen.findByRole("link", { name: "Account" })).getAttribute("href")).toBe("/account");
  expect(screen.getByRole("link", { name: "Decks" }).getAttribute("href")).toBe("/decks");
  expect(screen.queryByRole("link", { name: "Log in" })).toBeNull();
  await fireEvent.click(screen.getByRole("button", { name: "Log out" }));
  await vi.waitFor(() => expect(location.pathname).toBe("/login"));
  expect(net.posts()).toEqual([{ method: "POST", url: "/auth/logout", body: {} }]);
});
