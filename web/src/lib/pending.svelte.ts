/** Tracks in-flight async actions by key so buttons can disable themselves and double-clicks are ignored. */
export function pending() {
  const keys = $state<Record<string, boolean>>({});
  return {
    is: (k: string) => !!keys[k],
    /** Runs fn unless the same key is already in flight. */
    async run<T>(k: string, fn: () => Promise<T>): Promise<T | undefined> {
      if (keys[k]) return;
      keys[k] = true;
      try { return await fn(); } finally { keys[k] = false; }
    },
  };
}
