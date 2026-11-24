import { createHash, randomBytes } from "node:crypto";
import { expect, type Page } from "@playwright/test";

const b64url = (b: Buffer): string => b.toString("base64url");

export type Callback = { code: string | null; state: string | null; iss: string | null; error: string | null };

// An AI agent as an OAuth client: registers itself, sends the presenter's browser to the consent page,
// catches the redirect to its loopback callback (nothing listens there) and calls /mcp with the token.
export class McpClient {
  private readonly port = 20000 + Math.floor(Math.random() * 30000);
  private readonly redirect = `http://127.0.0.1:${this.port}/cb`;
  private readonly verifier = b64url(randomBytes(32));
  private readonly state = b64url(randomBytes(12));
  private clientId = "";
  private token = "";
  private callback: Promise<Callback> | null = null;

  constructor(readonly name: string, private readonly baseURL: string) {}

  private url = (path: string): string => new URL(path, this.baseURL).toString();

  private async registers(): Promise<void> {
    const r = await fetch(this.url("/oauth/register"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ client_name: this.name, redirect_uris: [this.redirect], grant_types: ["authorization_code", "refresh_token"] }),
    });
    expect(r.status).toBe(201);
    this.clientId = (await r.json()).client_id;
  }

  private authorizeUrl(scopes: string[]): string {
    const challenge = createHash("sha256").update(this.verifier).digest("base64url");
    const q = new URLSearchParams({
      response_type: "code", client_id: this.clientId, redirect_uri: this.redirect, code_challenge: challenge,
      code_challenge_method: "S256", state: this.state, scope: scopes.join(" "),
    });
    return this.url(`/oauth/authorize?${q}`);
  }

  // Registers, then sends `page` (the presenter's browser) to the authorize URL. Where the page ends up
  // is the presenter's business; the callback is captured when the browser is redirected to it.
  async startsConnecting(page: Page, scopes: string[] = ["decks", "results"]): Promise<void> {
    await this.registers();
    this.callback = new Promise<Callback>((resolve) =>
      page.route(`${new URL(this.redirect).origin}/**`, async (route) => {
        const q = new URL(route.request().url()).searchParams;
        resolve({ code: q.get("code"), state: q.get("state"), iss: q.get("iss"), error: q.get("error") });
        await route.fulfill({ status: 200, contentType: "text/plain", body: "callback" });
      }));
    await page.goto(this.authorizeUrl(scopes));
  }

  // what the browser delivered to the callback
  async receivesCallback(): Promise<Callback> {
    return await this.callback!;
  }

  // exchanges the code of the callback for the tokens
  async exchangesCode(): Promise<void> {
    const cb = await this.receivesCallback();
    expect(cb.state).toBe(this.state);
    expect(cb.code).toBeTruthy();
    const r = await fetch(this.url("/oauth/token"), {
      method: "POST",
      body: new URLSearchParams({
        grant_type: "authorization_code", code: cb.code!, client_id: this.clientId,
        redirect_uri: this.redirect, code_verifier: this.verifier,
      }),
    });
    expect(r.status).toBe(200);
    this.token = (await r.json()).access_token;
  }

  private rpc(method: string, params: object = {}): Promise<Response> {
    return fetch(this.url("/mcp"), {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", Authorization: `Bearer ${this.token}` },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
  }

  // the HTTP status of a tool call, for when it is expected to be refused
  async callStatus(tool: string, args: object = {}): Promise<number> {
    return (await this.rpc("tools/call", { name: tool, arguments: args })).status;
  }

  // the structured result of a tool call
  async call(tool: string, args: object = {}): Promise<any> {
    const r = await this.rpc("tools/call", { name: tool, arguments: args });
    expect(r.status).toBe(200);
    const result = (await r.json()).result;
    expect(result.isError).toBeFalsy();
    return result.structuredContent;
  }
}
