import type { Access } from "./types";

const FLAGS = ["edit", "moderate", "copy", "results"] as const;

/** Tag text for a deck the user does not own, e.g. "shared · edit moderate"; null for the owner's decks. */
export function accessTag(a: Access): string | null {
  if (a.owner) return null;
  const on = FLAGS.filter((f) => a[f]);
  return `shared · ${on.length ? on.join(" ") : "view"}`;
}
