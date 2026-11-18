import { pending } from "./pending.svelte";

/** Runs keyed async actions (see pending), then reloads; an action resolving to "left" (navigated away) skips the reload. */
export function actions(opts: { reload?: () => Promise<unknown>; onError?: (e: unknown) => void } = {}) {
  const pend = pending();
  let error = $state("");
  return {
    is: (k: string) => pend.is(k),
    async run(k: string, fn: () => Promise<unknown>): Promise<void> {
      await pend.run(k, async () => {
        error = "";
        try {
          if ((await fn()) !== "left") await opts.reload?.();
        } catch (e) {
          error = (e as Error).message;
          opts.onError?.(e);
        }
      });
    },
    get error() { return error; },
  };
}

export type Actions = ReturnType<typeof actions>;
