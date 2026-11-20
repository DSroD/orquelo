import { getContext, setContext } from "svelte";
import { ApiError, get } from "./api";
import type { Me } from "./types";

const key = Symbol("session");

function createSession(path: () => string | null) {
  let me = $state<Me | null | undefined>(undefined);
  let failure = $state<Error | null>(null);
  let resolvedPath = $state<string | null>(null);
  let generation = 0;

  async function load(requestedPath: string, mine: number) {
    try {
      const user = await get<Me>("/api/me");
      if (mine !== generation) return;
      me = user;
      failure = null;
      resolvedPath = requestedPath;
    } catch (error) {
      if (mine !== generation) return;
      me = error instanceof ApiError && error.status === 401 ? null : undefined;
      failure = error instanceof Error ? error : new Error("Could not check your session.");
      resolvedPath = requestedPath;
    }
  }

  $effect(() => {
    const requestedPath = path();
    if (requestedPath !== null) void load(requestedPath, ++generation);
    return () => { generation++; };
  });

  return {
    get me() { return resolvedPath === path() ? me : undefined; },
    get failure() { return resolvedPath === path() ? failure : null; },
    get lastKnownUser() { return me; },
    clear() {
      generation++;
      resolvedPath = path();
      me = null;
      failure = null;
    },
  };
}

export function provideSession(path: () => string | null) {
  return setContext(key, createSession(path));
}

export function useSession() {
  return getContext<ReturnType<typeof createSession> | undefined>(key) ?? createSession(() => location.pathname);
}
