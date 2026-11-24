import { expect, type Page } from "@playwright/test";
import type { Login } from "./edition";

// How the core edition logs in (email + password form). Another edition supplies its own Login
// through the Edition seam (edition.ts); the actors call nothing else.
export const passwordLogin: Login = {
  async submit(page: Page, email: string, password: string): Promise<void> {
    if (!new URL(page.url()).pathname.startsWith("/login")) await page.goto("/login"); // a redirect already brought us here, keeping return_to
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.getByRole("button", { name: "Log in" }).click();
  },
  expectPage: (page: Page) => expect(page.getByRole("heading", { name: "Log in" })).toBeVisible(),
  expectError: (page: Page, text: string | RegExp) => expect(page.getByRole("alert")).toContainText(text),
};
