import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import Login from "./Login.svelte";
import { failure, stubFetch } from "../test/net";

const user = userEvent.setup();
afterEach(() => { vi.unstubAllGlobals(); history.replaceState(null, "", "/"); });

async function submit() {
  await user.type(screen.getByLabelText("Email"), "ada@example.org");
  await user.type(screen.getByLabelText("Password"), "hunter2hunter2");
  await user.click(screen.getByRole("button", { name: "Log in" }));
}

describe("password Login", () => {
  it("posts the credentials and goes to return_to", async () => {
    history.replaceState(null, "", "/login?return_to=/decks/7");
    const net = stubFetch(() => new Response(null, { status: 204 }));
    render(Login);
    await submit();
    await vi.waitFor(() => expect(location.pathname).toBe("/decks/7"));
    expect(net.calls).toEqual([{ method: "POST", url: "/auth/password", body: { email: "ada@example.org", password: "hunter2hunter2" } }]);
  });

  it("falls back to /decks for a foreign return_to", async () => {
    history.replaceState(null, "", "/login?return_to=//evil.example");
    stubFetch(() => new Response(null, { status: 204 }));
    render(Login);
    await submit();
    await vi.waitFor(() => expect(location.pathname).toBe("/decks"));
  });

  it("says the password is wrong on 401", async () => {
    stubFetch(() => failure(401, { error: "invalid_credentials", message: "x" }));
    render(Login);
    await submit();
    expect((await screen.findByRole("alert")).textContent).toBe("Wrong email or password.");
  });

  it("says the account is suspended on 403", async () => {
    stubFetch(() => failure(403, { error: "suspended", message: "x" }));
    render(Login);
    await submit();
    expect((await screen.findByRole("alert")).textContent).toContain("This account is suspended");
  });

  it("shows the retry delay on 429", async () => {
    stubFetch(() => new Response(JSON.stringify({ error: "rate_limited", message: "slow" }), { status: 429, headers: { "Retry-After": "4" } }));
    render(Login);
    await submit();
    expect((await screen.findByRole("alert")).textContent).toBe("Too many attempts. Try again in 4 s.");
  });

  it("asks for both fields on 422", async () => {
    stubFetch(() => failure(422, { error: "invalid", message: "x" }));
    render(Login);
    await submit();
    expect((await screen.findByRole("alert")).textContent).toBe("Enter your email and password.");
  });

  it("reports an unreachable server", async () => {
    vi.stubGlobal("fetch", async () => { throw new TypeError("network"); });
    render(Login);
    await submit();
    expect((await screen.findByRole("alert")).textContent).toBe("Could not reach the server.");
  });
});
