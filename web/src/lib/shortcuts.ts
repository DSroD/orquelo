/** key -> [enabled, run]. A key that is bound but disabled is still swallowed (preventDefault). */
export type Shortcuts = Record<string, [enabled: () => boolean, run: () => void]>;

/** Plain-key dispatch: ignores modifiers and typing in form fields; letter keys do not auto-repeat. */
export function handleShortcut(e: KeyboardEvent, map: Shortcuts) {
  if (e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return;
  if ((e.target as HTMLElement).closest("input,textarea,select")) return;
  const hit = Object.hasOwn(map, e.key) ? map[e.key] : undefined;
  if (!hit) return;
  e.preventDefault();
  if (hit[0]() && !(e.repeat && e.key.length === 1)) hit[1]();
}
