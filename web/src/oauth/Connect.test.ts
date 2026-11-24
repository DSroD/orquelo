import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import Connect from "./Connect.svelte";
import { failure, fixture, stubFetch } from "../test/net";
import type { OAuthRequest } from "../lib/types";

const request = fixture<OAuthRequest>("oauth-request");
const redirect = fixture("oauth-redirect");
const user = userEvent.setup();
const url = `/api/oauth/requests/${request.id}`;
afterEach(() => vi.unstubAllGlobals());
const host = (redirect_host: string, redirect_host_differs = true) => ({ ...request, redirect_host, redirect_host_differs });

function stubLocation() {
  const assigned: string[] = [];
  vi.stubGlobal("location", { pathname: `/connect/${request.id}`, assign: (u: string) => assigned.push(u), set href(v: string) { assigned.push(v); } });
  return assigned;
}
const serve = (r: OAuthRequest = request) => stubFetch((c) => (c.method === "GET" ? r : redirect));

describe("Connect", () => {
  it("shows the verified host first and only the requested scopes", async () => {
    stubLocation(); serve();
    render(Connect, { id: request.id });
    expect((await screen.findAllByText(request.client.host!))[0].className).toContain("who");
    expect(screen.getByText(`calls itself “${request.client.name}”`)).toBeTruthy();
    const boxes = screen.getAllByRole("checkbox") as HTMLInputElement[];
    expect(boxes.map((b) => b.value)).toEqual(request.scopes.filter((s) => s.requested).map((s) => s.name));
    expect(boxes.every((b) => b.checked)).toBe(true);
  });

  it("labels an unverified client and warns about a different redirect host", async () => {
    stubLocation();
    serve({ ...request, client: { ...request.client, host: null, verified: false }, redirect_host_differs: true });
    render(Connect, { id: request.id });
    expect(await screen.findByText("unverified")).toBeTruthy();
    expect(screen.getByRole("alert").textContent).toContain("not the app's own site");
  });

  it("approves with the narrowed scopes and leaves for the redirect", async () => {
    const assigned = stubLocation();
    const net = serve({ ...request, scopes: request.scopes.map((s) => ({ ...s, requested: true })) });
    render(Connect, { id: request.id });
    const boxes = await screen.findAllByRole("checkbox");
    await user.click(boxes[1]);
    await user.click(screen.getByRole("button", { name: "Approve" }));
    await vi.waitFor(() => expect(assigned).toEqual([(redirect as any).redirect_to]));
    expect(net.posts()).toEqual([{ method: "POST", url: `${url}/approve`, body: { scopes: [request.scopes[0].name] } }]);
  });

  it("disables Approve when nothing is checked", async () => {
    stubLocation(); serve();
    render(Connect, { id: request.id });
    for (const b of await screen.findAllByRole("checkbox")) await user.click(b);
    expect((screen.getByRole("button", { name: "Approve" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("denies", async () => {
    const assigned = stubLocation(); const net = serve();
    render(Connect, { id: request.id });
    await user.click(await screen.findByRole("button", { name: "Deny" }));
    await vi.waitFor(() => expect(assigned).toEqual([(redirect as any).redirect_to]));
    expect(net.posts()).toEqual([{ method: "POST", url: `${url}/deny`, body: {} }]);
  });

  it("explains an expired request", async () => {
    stubLocation();
    stubFetch(() => failure(404, { error: "not_found", message: "x" }));
    render(Connect, { id: request.id });
    expect((await screen.findByRole("alert")).textContent).toContain("expired or was already used");
  });

  it("goes to login on 401 with a return_to", async () => {
    const assigned = stubLocation();
    stubFetch(() => failure(401, { error: "unauthorized", message: "x" }));
    render(Connect, { id: request.id });
    await vi.waitFor(() => expect(assigned).toEqual([`/login?return_to=${encodeURIComponent(`/connect/${request.id}`)}`]));
  });

  it("shows a neutral note instead of the warning for a loopback redirect", async () => {
    stubLocation(); serve(host("127.0.0.1"));
    render(Connect, { id: request.id });
    expect(await screen.findByText("You'll be sent back to an app on this device.")).toBeTruthy();
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("keeps the warning for another differing host", async () => {
    stubLocation(); serve(host("elsewhere.example"));
    render(Connect, { id: request.id });
    expect((await screen.findByRole("alert")).textContent).toContain("not the app's own site");
  });

  it("explains an expired request when approve answers 404", async () => {
    stubLocation();
    stubFetch((c) => (c.method === "GET" ? request : failure(404, { error: "not_found", message: "x" })));
    render(Connect, { id: request.id });
    await user.click(await screen.findByRole("button", { name: "Approve" }));
    expect((await screen.findByRole("alert")).textContent).toContain("expired or was already used");
  });

  it("shows the error and re-enables the buttons when approve answers 422", async () => {
    stubLocation();
    stubFetch((c) => (c.method === "GET" ? request : failure(422, { error: "invalid", message: "unknown scope", field: "scopes" })));
    render(Connect, { id: request.id });
    await user.click(await screen.findByRole("button", { name: "Approve" }));
    expect((await screen.findByRole("alert")).textContent).toBeTruthy();
    expect((screen.getByRole("button", { name: "Approve" }) as HTMLButtonElement).disabled).toBe(false);
    expect((screen.getByRole("button", { name: "Deny" }) as HTMLButtonElement).disabled).toBe(false);
  });

  it("refuses to show the consent UI when framed", async () => {
    stubLocation(); const net = serve();
    vi.stubGlobal("top", {});
    render(Connect, { id: request.id });
    expect(screen.getByText("Open this page directly")).toBeTruthy();
    expect(screen.queryByRole("button")).toBeNull();
    expect(net.posts()).toEqual([]);
  });
});
