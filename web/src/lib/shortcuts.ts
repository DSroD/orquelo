/** key -> [enabled, run]. A key that is bound but disabled is still swallowed (preventDefault). */
export type Shortcuts = Record<string, [enabled: () => boolean, run: () => void]>;

const letterKeysSetting = "orquelo:letter-shortcuts";

export function readLetterKeys() {
  try { return localStorage.getItem(letterKeysSetting) !== "off"; } catch { return true; }
}

export function saveLetterKeys(enabled: boolean) {
  try { localStorage.setItem(letterKeysSetting, enabled ? "on" : "off"); } catch { /* The current cockpit still honors the setting. */ }
}

/** Plain-key dispatch: ignores modifiers and typing in form fields; letter keys do not auto-repeat. */
export function handleShortcut(e: KeyboardEvent, map: Shortcuts, letterKeys: boolean) {
  if (e.defaultPrevented || e.isComposing || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return;
  if (e.target instanceof HTMLElement && (e.target.isContentEditable || e.target.closest("input,textarea,select"))) return;
  if (e.key.length === 1 && (!letterKeys || e.repeat)) return;
  const hit = Object.hasOwn(map, e.key) ? map[e.key] : undefined;
  if (!hit) return;
  e.preventDefault();
  if (hit[0]()) hit[1]();
}
