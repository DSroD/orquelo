import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { dirname } from "node:path";

const env = (name: string): string => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set: run through scripts/e2e`);
  return v;
};

// the server's own `user` command line, the way an admin creates accounts (the password goes in on stdin)
function user(args: string[], password?: string): void {
  execFileSync("racket", [env("E2E_ORQUELO_MAIN"), "user", ...args], {
    cwd: dirname(dirname(env("E2E_ORQUELO_MAIN"))), // the repo root: migrations are found relative to it
    input: password === undefined ? "" : `${password}\n`,
    env: { ...process.env, DATABASE_URL: env("E2E_DATABASE_URL") },
    stdio: ["pipe", "ignore", "pipe"],
  });
}

export const newEmail = (name: string): string => `${name.toLowerCase()}-${randomUUID().slice(0, 8)}@example.org`;

export const admin = {
  addUser: (email: string, password: string, name?: string) => user(["add", email, ...(name ? ["--name", name] : [])], password),
  setPassword: (email: string, password: string) => user(["passwd", email], password),
  suspendUser: (email: string) => user(["suspend", email]),
  activateUser: (email: string) => user(["activate", email]),
};
