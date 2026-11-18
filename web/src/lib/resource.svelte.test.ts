import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import ResourceHarness from "../test/ResourceHarness.svelte";
import { deferred, failure, stubFetch } from "../test/net";

const user = userEvent.setup();
afterEach(() => vi.unstubAllGlobals());

const data = () => screen.getByLabelText("data").textContent;
const error = () => screen.getByLabelText("error").textContent;
const settle = () => new Promise((r) => setTimeout(r));

describe("useResource", () => {
  it("fetches its url and exposes the data", async () => {
    const net = stubFetch(() => "A");
    render(ResourceHarness, { url: "/a" });
    await vi.waitFor(() => expect(data()).toBe("A"));
    expect(net.calls.map((c) => c.url)).toEqual(["/a"]);
  });

  it("keeps the previous data while a new url loads", async () => {
    const b = deferred<string>();
    stubFetch((c) => (c.url === "/a" ? "A" : b.promise));
    const { rerender } = render(ResourceHarness, { url: "/a" });
    await vi.waitFor(() => expect(data()).toBe("A"));
    await rerender({ url: "/b" });
    await settle();
    expect(data()).toBe("A");
    b.resolve("B");
    await vi.waitFor(() => expect(data()).toBe("B"));
  });

  it("drops a response that arrives after the url changed", async () => {
    const slow = deferred<string>();
    stubFetch((c) => (c.url === "/a" ? slow.promise : "B"));
    const { rerender } = render(ResourceHarness, { url: "/a" });
    await rerender({ url: "/b" });
    await vi.waitFor(() => expect(data()).toBe("B"));
    slow.resolve("A");
    await settle();
    expect(data()).toBe("B");
  });

  it("makes no request for a null url until it gets one", async () => {
    const net = stubFetch(() => "X");
    const { rerender } = render(ResourceHarness, { url: null });
    await settle();
    expect(net.calls).toEqual([]);
    await rerender({ url: "/x" });
    await vi.waitFor(() => expect(data()).toBe("X"));
  });

  it("reload fetches the url again", async () => {
    let n = 0;
    const net = stubFetch(() => `v${++n}`);
    render(ResourceHarness, { url: "/a" });
    await vi.waitFor(() => expect(data()).toBe("v1"));
    await user.click(screen.getByRole("button", { name: "reload" }));
    await vi.waitFor(() => expect(data()).toBe("v2"));
    expect(net.calls.map((c) => c.url)).toEqual(["/a", "/a"]);
  });

  it("keeps an error, and the data it interrupted, until a fetch succeeds", async () => {
    let fail = false;
    const next = deferred<string>();
    stubFetch((c) => (c.url === "/c" ? next.promise : fail ? failure(500, { error: "internal", message: "boom" }) : "ok"));
    const { rerender } = render(ResourceHarness, { url: "/a" });
    await vi.waitFor(() => expect(data()).toBe("ok"));
    fail = true;
    await user.click(screen.getByRole("button", { name: "reload" }));
    await vi.waitFor(() => expect(error()).toBe("boom"));
    expect(data()).toBe("ok");
    await rerender({ url: "/c" });
    await settle();
    expect(error()).toBe("boom");
    next.resolve("fresh");
    await vi.waitFor(() => expect(error()).toBe(""));
    expect(data()).toBe("fresh");
  });
});
