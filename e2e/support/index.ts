import { test as base } from "@playwright/test";
import { Cast } from "./cast";
import { coreEdition, type Edition } from "./edition";

export { expect } from "@playwright/test";
export type { Locator, Page } from "@playwright/test";
export { admin, newEmail } from "./admin";
export { type Accounts, type Edition, type Login } from "./edition";
export { Cast } from "./cast";
export { Presenter } from "./presenter";
export { Projector } from "./screen";
export { Student } from "./student";

// Specs import test and expect from here only, never from @playwright/test (one copy of Playwright per run).
export const makeTest = (edition: Edition) =>
  base.extend<{ cast: Cast }>({
    cast: async ({ browser, baseURL }, use) => {
      const cast = new Cast(browser, baseURL!, edition);
      await use(cast);
      await cast.close();
    },
  });

export const test = makeTest(coreEdition);
