import { randomBytes } from "node:crypto";
import type { Browser, BrowserContext } from "@playwright/test";
import { newEmail } from "./admin";
import type { Edition } from "./edition";
import { McpClient } from "./mcp-client";
import { Presenter } from "./presenter";
import { Projector } from "./screen";
import { PHONE, Student } from "./student";

// The people of a story. Each actor gets its own browser context; all are closed with the story.
export class Cast {
  private contexts: BrowserContext[] = [];

  constructor(private readonly browser: Browser, private readonly baseURL: string, private readonly edition: Edition) {}

  private async context(options = {}): Promise<BrowserContext> {
    const context = await this.browser.newContext({ baseURL: this.baseURL, ...options });
    this.contexts.push(context);
    return context;
  }

  private async presenterAt(email: string, password: string): Promise<Presenter> {
    const context = await this.context();
    return new Presenter(email, password, await context.newPage(), context, () => this.presenterAt(email, password), this.edition.login);
  }

  // a lecturer the admin has given an account
  presenter(name: string): Promise<Presenter> {
    const email = newEmail(name);
    const password = randomBytes(16).toString("hex");
    this.edition.accounts.create(email, password, name);
    return this.presenterAt(email, password);
  }

  // an email address nobody has an account for
  stranger = (email: string): Promise<Presenter> => this.presenterAt(email, "not-a-real-password");

  async screen(url: string): Promise<Projector> {
    const page = await (await this.context()).newPage();
    await page.goto(url);
    return new Projector(page);
  }

  async student(url?: string): Promise<Student> {
    const student = new Student(await (await this.context(PHONE)).newPage());
    if (url) await student.joins(url);
    return student;
  }

  // an agent that connects to Orquelo over OAuth and MCP
  mcpClient = (name = "Claude Agent"): McpClient => new McpClient(name, this.baseURL);

  close = () => Promise.all(this.contexts.map((c) => c.close()));
}
