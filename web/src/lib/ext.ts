import type { Component } from "svelte";

/** A lazily loaded page component. */
export type Lazy = () => Promise<{ default: Component<any> }>;

/** A page an edition adds: how a path maps to props (null: not this page) and its component. */
export interface ExtRoute {
  match(seg: readonly string[]): Record<string, string> | null;
  load: Lazy;
}

/** What an edition plugs into the SPA (`$ext`): extra pages, the login page, an optional home page and whether accounts have passwords. */
export interface Extension {
  routes: readonly ExtRoute[];
  Login: Lazy;
  Home?: Lazy;
  passwordAccount: boolean;
}
