import { defineConfig, devices } from "@playwright/test";

const required = (name: string): string => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set: run through scripts/e2e`);
  return v;
};

export default defineConfig({
  // an edition runs its own stories on this install (its scripts/e2e sets E2E_STORIES)
  testDir: process.env.E2E_STORIES ?? "stories",
  fullyParallel: true,
  workers: 2,
  retries: 0,
  forbidOnly: true,
  reporter: [["list"], ["html", { open: "never" }]],
  use: { baseURL: required("E2E_BASE_URL"), trace: "retain-on-failure", screenshot: "only-on-failure" },
  // the phone is per actor (support/student.ts), not a project
  projects: [{ name: "chromium", use: devices["Desktop Chrome"] }],
});
