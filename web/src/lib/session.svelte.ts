import { ApiError, get } from "./api";
import { loginRedirect } from "./expired";
import { openStream } from "./stream";

export type Phase = "live" | "ended" | "missing" | "forbidden";

/** Reactive wrapper over openStream; probes the info endpoint when the stream drops so 404/410 stop the retry loop.
 *  A 401 on the probe redirects to login. */
export function useStream<S>(streamUrl: () => string, infoUrl: () => string) {
  const st = $state<{ snap: S | null; phase: Phase; connected: boolean }>({ snap: null, phase: "live", connected: false });

  $effect(() => {
    const stream = streamUrl(), info = infoUrl();
    let close = () => {};
    let dead = false;
    close = openStream<S>(stream, {
      onSnapshot: (s) => { st.snap = s; },
      onEnded: () => { st.phase = "ended"; },
      onStatus: (c) => {
        st.connected = c;
        if (c) return;
        get(info).catch((e) => {
          if (dead) return;
          const to = loginRedirect(e, location.pathname);
          if (to) { close(); location.href = to; return; }
          if (!(e instanceof ApiError)) return;
          if (e.status === 410) { st.phase = "ended"; close(); }
          else if (e.status === 404) { st.phase = "missing"; close(); }
          // only before the first snapshot: a moderator without the results flag also gets 403 on this probe
          else if (e.status === 403 && st.snap === null) { st.phase = "forbidden"; close(); }
        });
      },
    });
    return () => { dead = true; close(); };
  });
  return st;
}
