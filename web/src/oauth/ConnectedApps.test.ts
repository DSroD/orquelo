import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import ConnectedApps from "./ConnectedApps.svelte";
import { failure, fixture, stubFetch } from "../test/net";
import type { OAuthGrant } from "../lib/types";

const grants = fixture<OAuthGrant[]>("oauth-grants");
const user = userEvent.setup();
afterEach(() => vi.unstubAllGlobals());

const serve = (list: OAuthGrant[], del = () => new Response(null, { status: 204 })) =>
  stubFetch((c) => (c.method === "GET" ? list : del()));

describe("ConnectedApps", () => {
  it("lists grants", async () => {
    serve([grants[0], { ...grants[0], id: "b", needs_reconnect: true }]);
    render(ConnectedApps);
    expect(await screen.findAllByText(grants[0].client.host!)).toHaveLength(2);
    expect(screen.getAllByText(`Access: ${grants[0].scopes.join(", ")}`)).toHaveLength(2);
    expect(screen.getAllByText("reconnect needed")).toHaveLength(1);
  });

  it("disconnects and removes the row", async () => {
    const net = serve(grants);
    render(ConnectedApps);
    await user.click(await screen.findByRole("button", { name: "Disconnect" }));
    await vi.waitFor(() => expect(screen.getByText("No apps are connected.")).toBeTruthy());
    expect(net.posts()).toEqual([{ method: "DELETE", url: `/api/oauth/grants/${grants[0].id}`, body: undefined }]);
  });

  it("removes the row when the grant is already gone", async () => {
    serve(grants, () => failure(404, { error: "not_found", message: "x" }));
    render(ConnectedApps);
    await user.click(await screen.findByRole("button", { name: "Disconnect" }));
    await vi.waitFor(() => expect(screen.getByText("No apps are connected.")).toBeTruthy());
  });

  it("goes to login when Disconnect answers 401", async () => {
    const assigned: string[] = [];
    vi.stubGlobal("location", { pathname: "/settings/apps", set href(v: string) { assigned.push(v); } });
    serve(grants, () => failure(401, { error: "unauthorized", message: "x" }));
    render(ConnectedApps);
    await user.click(await screen.findByRole("button", { name: "Disconnect" }));
    await vi.waitFor(() => expect(assigned).toEqual([`/login?return_to=${encodeURIComponent("/settings/apps")}`]));
  });

  it("shows the empty state", async () => {
    serve([]);
    render(ConnectedApps);
    expect(await screen.findByText("No apps are connected.")).toBeTruthy();
  });
});
