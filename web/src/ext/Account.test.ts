import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import Account from "./Account.svelte";
import { failure, fixture, stubFetch } from "../test/net";
import type { Me } from "../lib/types";

const me = fixture<Me>("me");
const user = userEvent.setup();
afterEach(() => vi.unstubAllGlobals());

const answer = (put: () => Response) => (c: { method: string }) => (c.method === "PUT" ? put() : me);

async function fill(current = "old-password-1", next = "new-password-22", repeat = next) {
  await user.type(await screen.findByLabelText("Current password"), current);
  await user.type(screen.getByLabelText("New password"), next);
  await user.type(screen.getByLabelText("Repeat new password"), repeat);
  await user.click(screen.getByRole("button", { name: "Change password" }));
}

describe("Account", () => {
  it("sends nothing when the repeat differs", async () => {
    const net = stubFetch(answer(() => new Response(null, { status: 204 })));
    render(Account);
    await fill("old-password-1", "new-password-22", "new-password-23");
    expect((await screen.findByRole("alert")).textContent).toBe("The new passwords do not match.");
    expect(net.posts()).toEqual([]);
  });

  it("changes the password and clears the form", async () => {
    const net = stubFetch(answer(() => new Response(null, { status: 204 })));
    render(Account);
    await fill();
    expect((await screen.findByRole("status")).textContent).toBe("Password changed. Your other browsers were signed out.");
    expect(net.posts()).toEqual([{ method: "PUT", url: "/api/me/password", body: { current: "old-password-1", new: "new-password-22" } }]);
    expect((screen.getByLabelText("Current password") as HTMLInputElement).value).toBe("");
  });

  it("says the current password is wrong", async () => {
    stubFetch(answer(() => failure(401, { error: "invalid_credentials", message: "x" })));
    render(Account);
    await fill();
    expect((await screen.findByRole("alert")).textContent).toBe("The current password is wrong.");
  });

  it("explains a too short new password", async () => {
    stubFetch(answer(() => failure(422, { error: "invalid", message: "x", field: "new" })));
    render(Account);
    await fill();
    expect((await screen.findByRole("alert")).textContent).toBe("The new password must be 10 to 1024 characters.");
  });

  it("shows the retry delay on 429", async () => {
    stubFetch(answer(() => new Response(JSON.stringify({ error: "rate_limited", message: "slow" }), { status: 429, headers: { "Retry-After": "9" } })));
    render(Account);
    await fill();
    expect((await screen.findByRole("alert")).textContent).toBe("Too many attempts. Try again in 9 s.");
  });

  it("goes to login when the session expired", async () => {
    const hrefs: string[] = [];
    vi.stubGlobal("location", { pathname: "/account", set href(v: string) { hrefs.push(v); } });
    stubFetch(answer(() => failure(401, { error: "unauthorized", message: "x" })));
    render(Account);
    await fill();
    await vi.waitFor(() => expect(hrefs).toEqual(["/login?return_to=%2Faccount"]));
  });

  it("links to the connected apps", async () => {
    stubFetch(() => me);
    render(Account);
    expect((await screen.findByRole("link", { name: "Connected apps" })).getAttribute("href")).toBe("/connected-apps");
  });
});
