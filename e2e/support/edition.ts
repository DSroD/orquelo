import type { Page } from "@playwright/test";
import { admin } from "./admin";
import { passwordLogin } from "./login";

// How a lecturer signs in on this edition.
export interface Login {
  submit(page: Page, email: string, password: string): Promise<void>;
  expectPage(page: Page): Promise<void>;
  expectError(page: Page, text: string | RegExp): Promise<void>;
}

// How accounts come to exist and change state on this edition.
export interface Accounts {
  create(email: string, password: string, name?: string): void;
  suspend(email: string): void;
  activate(email: string): void;
}

// What differs between editions; stories and actors are written against this seam only.
export interface Edition {
  login: Login;
  accounts: Accounts;
}

export const coreEdition: Edition = {
  login: passwordLogin,
  accounts: { create: admin.addUser, suspend: admin.suspendUser, activate: admin.activateUser },
};
