import type { Extension } from "../lib/ext";

// annotated, not `satisfies`: App reads the optional Home through the interface
const ext: Extension = {
  routes: [
    { match: (s) => (s.length === 1 && s[0] === "account" ? {} : null), load: () => import("./Account.svelte") },
  ],
  Login: () => import("./Login.svelte"),
  passwordAccount: true,
};
export default ext;
