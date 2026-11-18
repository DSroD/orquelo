import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { vi } from "vitest";

export const fixture = <T = any>(name: string): T =>
  JSON.parse(readFileSync(resolve(import.meta.dirname, "../../../docs/api-fixtures", `${name}.json`), "utf8"));

export type Call = { method: string; url: string; body: unknown };
type Reply = Response | unknown;

/** Replaces fetch. The handler answers by method and url with a JSON value or a Response; every call is recorded. */
export function stubFetch(handler: (c: Call) => Reply | Promise<Reply>) {
  const calls: Call[] = [];
  vi.stubGlobal("fetch", async (url: string, init: RequestInit = {}) => {
    const call: Call = { method: init.method ?? "GET", url, body: typeof init.body === "string" ? JSON.parse(init.body) : init.body };
    calls.push(call);
    const r = await handler(call);
    return r instanceof Response ? r : new Response(JSON.stringify(r ?? {}));
  });
  return { calls, posts: () => calls.filter((c) => c.method !== "GET") };
}

export const failure = (status: number, body: object) => new Response(JSON.stringify(body), { status });

export function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

/** Stand-in for the browser's EventSource; tests push server messages with emit. */
export class FakeEventSource {
  static all: FakeEventSource[] = [];
  static last = () => FakeEventSource.all[FakeEventSource.all.length - 1];
  onerror: (() => void) | null = null;
  private listeners: Record<string, ((e: { data: string }) => void)[]> = {};
  constructor(public url: string) { FakeEventSource.all.push(this); }
  addEventListener(type: string, fn: (e: { data: string }) => void) { (this.listeners[type] ??= []).push(fn); }
  close() {}
  emit(type: string, data: unknown = {}) { for (const fn of this.listeners[type] ?? []) fn({ data: JSON.stringify(data) }); }
}

export const stubEventSource = () => { FakeEventSource.all = []; vi.stubGlobal("EventSource", FakeEventSource); };
