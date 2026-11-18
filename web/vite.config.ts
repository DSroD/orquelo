import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { svelteTesting } from "@testing-library/svelte/vite";

const target = `http://localhost:${process.env.PORT ?? 8080}`;
// the server's CSRF guard wants the public Origin, which differs from the vite port
const origin = process.env.PUBLIC_BASE_URL;
const proxied = { target, ...(origin ? { headers: { origin } } : {}) };
const root = fileURLToPath(new URL(".", import.meta.url));
// An edition's web extension (`$ext`); core's own lives in src/ext.
const extDir = resolve(root, process.env.ORQUELO_WEB_EXT ?? "src/ext");
const custom = extDir !== resolve(root, "src/ext");

export default defineConfig({
  plugins: [svelte(), svelteTesting()],
  resolve: {
    alias: [
      { find: /^\$ext$/, replacement: resolve(extDir, "index.ts") },
      { find: /^\$core\//, replacement: resolve(root, "src") + "/" },
    ],
    // an ext dir outside web/ has no node_modules of its own, so these must resolve from here
    dedupe: ["svelte", "@testing-library/svelte", "@testing-library/user-event"],
  },
  server: {
    port: Number(process.env.VITE_PORT ?? 5173),
    strictPort: true,
    fs: { allow: [root, extDir] },
    proxy: { "/api": proxied, "/auth": proxied, "/healthz": proxied },
  },
  // core's tests assume core's ext (the Account link), so a custom ext runs only its own
  test: { include: custom ? [`${extDir}/**/*.test.ts`] : ["src/**/*.test.ts"], environment: "jsdom", setupFiles: ["src/test/setup.ts"] },
});
