import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import List from "./List.svelte";
import { failure, fixture, stubFetch } from "../test/net";
import type { Me } from "../lib/types";

const me = fixture<Me>("me");
const shared = fixture("presentation-listing");
const own = { ...shared, id: 8, title: "Mine", access: { owner: true, edit: true, moderate: true, copy: true, results: true } };
const user = userEvent.setup();
afterEach(() => vi.unstubAllGlobals());

describe("Deck list", () => {
  it("tags shared decks with their flags and leaves own decks untagged", async () => {
    stubFetch(() => [own, shared]);
    render(List, { me });
    expect((await screen.findByText("shared · moderate"))).toBeTruthy();
    expect(screen.queryAllByText(/^shared/)).toHaveLength(1);
  });

  it("links to the account page in the password edition", async () => {
    stubFetch(() => []);
    render(List, { me });
    expect(screen.getByRole("link", { name: "Account" }).getAttribute("href")).toBe("/account");
  });

  it("shows plan, usage against quota and logs out", async () => {
    const net = stubFetch(() => []);
    render(List, { me });
    const strip = screen.getByLabelText("Account");
    expect(strip.textContent).toContain("free");
    expect(strip.textContent).toContain("2 / 32 MB");
    await user.click(screen.getByRole("button", { name: "Log out" }));
    await vi.waitFor(() => expect(location.pathname).toBe("/login"));
    expect(net.posts()).toEqual([{ method: "POST", url: "/auth/logout", body: {} }]);
  });

  it("shows no plan tag and no quota when the account has neither", () => {
    stubFetch(() => []);
    render(List, { me: { ...me, membership: { ...me.membership, plan: null, storage_quota: null } } });
    const strip = screen.getByLabelText("Account");
    expect(strip.textContent).not.toContain("free");
    expect(strip.textContent).toContain("2 MB used");
  });

  async function upload(err: object) {
    stubFetch((c) => (c.method === "POST" ? failure(413, err) : []));
    render(List, { me });
    await user.click(screen.getByText("New deck"));
    await user.upload(screen.getByLabelText(/PDF file/), new File(["%PDF-"], "a.pdf", { type: "application/pdf" }));
    // jsdom does not see the uploaded file for the form's `required` check, so submit the form directly
    await fireEvent.submit(screen.getByRole("button", { name: "Upload" }).closest("form")!);
    return (await screen.findByRole("alert")).textContent;
  }

  it("names the per-deck limit", async () => {
    expect(await upload({ error: "too_large", message: "raw" })).toBe("Deck over the 5 MB per-deck limit");
  });

  it("refuses a file over the per-deck limit without uploading it", async () => {
    const net = stubFetch(() => []);
    render(List, { me });
    await user.click(screen.getByText("New deck"));
    await user.upload(screen.getByLabelText(/PDF file/), new File([new Uint8Array(me.membership.max_upload_bytes + 1)], "big.pdf", { type: "application/pdf" }));
    await fireEvent.submit(screen.getByRole("button", { name: "Upload" }).closest("form")!);
    expect((await screen.findByRole("alert")).textContent).toBe("Deck over the 5 MB per-deck limit");
    expect(net.posts()).toEqual([]);
  });

  it("says when storage is full", async () => {
    expect(await upload({ error: "quota_exceeded", message: "raw" })).toBe("Not enough storage left");
  });
});
