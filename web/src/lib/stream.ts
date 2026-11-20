/** Backoff: 1s, 2s, 4s ... capped at 15s. attempt is 0-based. */
export function nextDelay(attempt: number): number {
  return Math.min(1000 * 2 ** Math.max(0, attempt), 15000);
}

export interface StreamHandlers<S> {
  onSnapshot: (s: S) => void;
  onEnded: () => void;
  onAudienceFull?: () => void;
  onStatus?: (connected: boolean) => void;
}

/** EventSource with manual backoff reconnect. Returns a close function. */
export function openStream<S>(url: string, h: StreamHandlers<S>): () => void {
  let es: EventSource | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let attempt = 0;
  let stopped = false;

  const connect = () => {
    es = new EventSource(url);
    es.addEventListener("snapshot", (e) => {
      attempt = 0;
      h.onStatus?.(true);
      h.onSnapshot(JSON.parse((e as MessageEvent).data));
    });
    es.addEventListener("ended", () => {
      stop();
      h.onEnded();
    });
    es.addEventListener("audience-full", () => h.onAudienceFull?.());
    es.onerror = () => {
      es?.close();
      h.onStatus?.(false);
      if (stopped) return;
      timer = setTimeout(connect, nextDelay(attempt++));
    };
  };
  const stop = () => {
    stopped = true;
    clearTimeout(timer);
    es?.close();
  };
  connect();
  return stop;
}
