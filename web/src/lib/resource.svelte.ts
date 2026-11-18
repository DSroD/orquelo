import { ApiError, get } from "./api";

/** Reactive GET: refetches when url() changes (null = idle), keeps the previous data while loading,
 *  and drops responses that arrive after the url changed. An error (and its status) stays until a fetch succeeds. */
export function useResource<T>(url: () => string | null) {
  const st = $state<{ data: T | null; error: string; status: number }>({ data: null, error: "", status: 0 });
  let gen = 0;

  async function load(u: string | null) {
    if (u === null) return;
    const mine = ++gen;
    try {
      const r = await get<T>(u);
      if (mine !== gen) return;
      st.data = r; st.error = ""; st.status = 0;
    } catch (e) {
      if (mine !== gen) return;
      st.error = (e as Error).message;
      st.status = e instanceof ApiError ? e.status : 0;
    }
  }

  $effect(() => {
    const u = url();
    load(u);
    return () => { gen++; };
  });

  return {
    get data() { return st.data; },
    get error() { return st.error; },
    /** HTTP status of the failed fetch, 0 when it was not an API error. */
    get status() { return st.status; },
    reload: () => load(url()),
  };
}
