import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import SharePanel from "./SharePanel.svelte";
import { fixture, stubFetch } from "../../test/net";
import type { Share } from "../../lib/types";

const BASE = "/api/decks/7";
const bob = fixture<Share[]>("shares")[0];
const user = userEvent.setup();
afterEach(() => vi.unstubAllGlobals());

function open(shares: Share[] = [bob]) {
  const net = stubFetch((c) => (c.method === "GET" ? shares : c.method === "PUT" ? { ...(c.body as object), email: "x" } : undefined));
  render(SharePanel, { base: BASE });
  return net;
}

describe("Share panel", () => {
  it("lists the shares with their flags", async () => {
    open();
    const row = (await screen.findByText(bob.email)).closest("li")!;
    expect((within(row).getByRole("checkbox", { name: "moderate" }) as HTMLInputElement).checked).toBe(true);
    expect((within(row).getByRole("checkbox", { name: "edit" }) as HTMLInputElement).checked).toBe(false);
  });

  it("adds an email with the chosen flags", async () => {
    const net = open();
    await screen.findByText(bob.email);
    await user.type(screen.getByRole("textbox", { name: "Email" }), "carol@example.org");
    const add = screen.getByRole("button", { name: "Share" }).closest("form")!;
    await user.click(within(add).getByRole("checkbox", { name: "edit" }));
    await user.click(within(add).getByRole("checkbox", { name: "results" }));
    await user.click(screen.getByRole("button", { name: "Share" }));
    await vi.waitFor(() => expect(net.posts()).toEqual([
      { method: "PUT", url: `${BASE}/shares/carol%40example.org`, body: { edit: true, moderate: false, copy: false, results: true } },
    ]));
  });

  it("edits one flag inline, sending all four", async () => {
    const net = open();
    const row = (await screen.findByText(bob.email)).closest("li")!;
    await user.click(within(row).getByRole("checkbox", { name: "copy" }));
    await vi.waitFor(() => expect(net.posts()).toEqual([
      { method: "PUT", url: `${BASE}/shares/bob%40example.org`, body: { edit: false, moderate: true, copy: true, results: false } },
    ]));
  });

  it("removes a share", async () => {
    const net = open();
    await user.click(await screen.findByRole("button", { name: `Remove ${bob.email}` }));
    await vi.waitFor(() => expect(net.posts()).toEqual([{ method: "DELETE", url: `${BASE}/shares/bob%40example.org`, body: undefined }]));
  });
});
