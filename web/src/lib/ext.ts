import type { Component } from "svelte";

/** A lazily loaded page component. */
export type Lazy = () => Promise<{ default: Component<any> }>;

/** A page an edition adds: how a path maps to props (null: not this page) and its component. */
export interface ExtRoute {
  match(seg: readonly string[]): Record<string, string> | null;
  load: Lazy;
}

export interface NavigationLink {
  label: string;
  href: string;
  when?: "signed-in" | "signed-out";
}

/** The routes, pages and navigation an edition plugs into the SPA. */
export interface Extension {
  routes: readonly ExtRoute[];
  Login: Lazy;
  Home?: Lazy;
  navigation?: readonly NavigationLink[];
}
