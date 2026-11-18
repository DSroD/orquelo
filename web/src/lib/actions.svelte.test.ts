import { expect, it, vi } from "vitest";
import { actions } from "./actions.svelte";

it("ignores a duplicate key while in flight and reloads after", async () => {
  const reload = vi.fn(async () => {});
  const a = actions({ reload });
  let done!: () => void;
  const fn = vi.fn(() => new Promise<void>((r) => (done = r)));
  const first = a.run("k", fn);
  await a.run("k", fn);
  expect(a.is("k")).toBe(true);
  done(); await first;
  expect(fn).toHaveBeenCalledTimes(1);
  expect(reload).toHaveBeenCalledTimes(1);
  expect(a.is("k")).toBe(false);
});

it("skips the reload when fn resolves to left", async () => {
  const reload = vi.fn(async () => {});
  await actions({ reload }).run("k", async () => "left");
  expect(reload).not.toHaveBeenCalled();
});

it("sets the error, calls onError, and clears it on the next run", async () => {
  const onError = vi.fn();
  const a = actions({ onError });
  await a.run("k", async () => { throw new Error("nope"); });
  expect(a.error).toBe("nope");
  expect(onError).toHaveBeenCalledOnce();
  await a.run("k", async () => {});
  expect(a.error).toBe("");
});
