import { expect, test, type BrowserContext, type Locator, type Page } from "@playwright/test";
import type { Login } from "./edition";
import { makePdf, type PdfOptions } from "./pdf";

type Text = string | RegExp;
export type Overlay = "QR code" | "Slide only" | "Poll";
export type NewPoll = { question: string; options: string[]; slide?: number; kind?: "single" | "multi" };

const SCOPE_LABEL: Record<string, RegExp> = { decks: /Read and edit your decks/, results: /Read aggregate poll results/ };

const step = <T>(title: string, body: () => Promise<T>): Promise<T> => test.step(title, body);

export class Presenter {
  constructor(
    readonly email: string,
    public password: string,
    readonly page: Page,
    private readonly context: BrowserContext,
    private readonly another: () => Promise<Presenter>,
    private readonly login: Login,
  ) {}

  private item = (text: string): Locator => this.page.getByRole("listitem").filter({ hasText: text });
  private tab = (name: Text): Locator => this.page.getByRole("tab", { name });
  private region = (name: string): Locator => this.page.getByRole("region", { name });

  // signing in and out

  signsIn = (pw = this.password) => step(`${this.email} signs in`, async () => {
    await this.login.submit(this.page, this.email, pw);
    await expect(this.page.getByRole("heading", { name: "Decks" })).toBeVisible();
  });
  triesToSignIn = (pw: string) => step(`${this.email} tries to sign in`, () => this.login.submit(this.page, this.email, pw));
  seesSignInError = (text: Text) => step("sees a sign-in error", () => this.login.expectError(this.page, text));
  seesTheirAccount = () => step("sees their email on the Account page", async () => {
    await expect(this.page.getByText(this.email, { exact: true })).toHaveCount(0);
    await this.page.getByRole("link", { name: "Account", exact: true }).click();
    await expect(this.page.getByText(this.email, { exact: true })).toBeVisible();
    await expect(this.page.getByRole("navigation", { name: "Path" })).toHaveCount(0);
  });
  isSignedOut = () => step(`${this.email} is signed out`, async () => {
    await this.page.goto("/decks");
    await expect(this.page).toHaveURL(/\/login\?return_to=/);
    await this.login.expectPage(this.page);
  });
  logsOut = () => step("logs out", async () => {
    await this.page.getByRole("button", { name: "Log out" }).click();
    await expect(this.page).toHaveURL(/\/login/);
  });
  signsInWhereSent = (pw = this.password) => step(`${this.email} signs in where the redirect sent them`, async () => {
    await expect(this.page).toHaveURL(/\/login\?return_to=/);
    await this.login.submit(this.page, this.email, pw);
  });
  inAnotherBrowser = () => this.another();

  changesPassword = (to: string) => step("changes the password", async () => {
    await this.page.getByRole("link", { name: "Account" }).click();
    await this.page.getByLabel("Current password").fill(this.password);
    await this.page.getByLabel("New password", { exact: true }).fill(to);
    await this.page.getByLabel("Repeat new password").fill(to);
    await this.page.getByRole("button", { name: "Change password" }).click();
    await expect(this.page.getByRole("status")).toContainText("Password changed");
    this.password = to;
  });

  // connecting apps

  seesConsentFor = (app: string, scopes: string[]) => step(`sees the consent page for "${app}"`, async () => {
    await expect(this.page.getByRole("heading", { name: "Connect an app to Orquelo" })).toBeVisible();
    await expect(this.page.getByText(app)).toBeVisible();
    await expect(this.page.getByText("unverified", { exact: true })).toBeVisible();
    await expect(this.page.getByText(/sent back to\s+127\.0\.0\.1/)).toBeVisible();
    for (const s of scopes) await expect(this.page.getByRole("checkbox", { name: SCOPE_LABEL[s] })).toBeChecked();
  });
  approvesConnection = (scopes?: string[]) => step("approves the connection", async () => {
    if (scopes)
      for (const [name, label] of Object.entries(SCOPE_LABEL))
        await this.page.getByRole("checkbox", { name: label }).setChecked(scopes.includes(name));
    await this.page.getByRole("button", { name: "Approve" }).click();
  });
  deniesConnection = () => step("denies the connection", () => this.page.getByRole("button", { name: "Deny" }).click());
  disconnects = (app: string) => step(`disconnects "${app}"`, async () => {
    await this.page.goto("/connected-apps");
    const row = this.item(app);
    await row.getByRole("button", { name: "Disconnect" }).click();
    await expect(row).toHaveCount(0);
  });

  // decks

  opensDeckList = () => step("opens the deck list", async () => {
    await this.page.goto("/decks");
    await expect(this.page.getByRole("heading", { name: "Decks" })).toBeVisible();
  });

  private async submitsDeck(title: string, pdf: PdfOptions): Promise<void> {
    await this.page.getByText("New deck", { exact: true }).click();
    await this.page.getByLabel("Title (optional)").fill(title);
    await this.page.getByLabel(/^PDF file/).setInputFiles({ name: "lecture.pdf", mimeType: "application/pdf", buffer: makePdf(pdf) });
    await this.page.getByRole("button", { name: "Upload" }).click();
  }
  uploadsDeck = (title: string, pdf: PdfOptions = {}) => step(`uploads the deck "${title}"`, async () => {
    await this.submitsDeck(title, pdf);
    await expect(this.page).toHaveURL(/\/decks\/\d+$/);
  });
  triesToUploadDeck = (title: string, pdf: PdfOptions = {}) => step(`tries to upload the deck "${title}"`, () => this.submitsDeck(title, pdf));
  seesUploadError = (text: Text) => step("sees an upload error", () => expect(this.page.getByRole("alert")).toContainText(text));
  seesStorageUsed = (text: Text) => step(`sees ${text} in the account strip`, () => expect(this.page.getByText(text)).toBeVisible());
  seesDeck = (title: string, expected: { slides?: number; tag?: Text } = {}) => step(`sees the deck "${title}"`, async () => {
    const row = this.item(title);
    await expect(row).toBeVisible();
    if (expected.slides !== undefined) await expect(row).toContainText(`${expected.slides} slides`);
    if (expected.tag) await expect(row).toContainText(expected.tag);
  });
  opensDeck = (title: string) => step(`opens the deck "${title}"`, async () => {
    await this.page.getByRole("link", { name: title }).click();
    await expect(this.page).toHaveURL(/\/decks\/\d+$/);
  });

  // editing a deck

  addsPoll = ({ question, options, slide, kind = "single" }: NewPoll) => step(`adds the poll "${question}"`, async () => {
    await this.tab(/^Polls/).click();
    await this.page.getByRole("button", { name: "New poll" }).click();
    await this.page.getByLabel("Question", { exact: true }).fill(question);
    if (slide !== undefined) await this.page.getByLabel(/^Slide \(/).fill(String(slide));
    await this.page.getByLabel("Type").selectOption(kind);
    for (const [i, label] of options.entries()) {
      if (i >= 2) await this.page.getByRole("button", { name: "Add option" }).click();
      await this.page.getByLabel(`Option ${i + 1}`, { exact: true }).fill(label);
    }
    await this.page.getByRole("button", { name: "Save poll" }).click();
    await expect(this.item(question)).toBeVisible();
  });
  seesPoll = (question: string, kind: "single" | "multi") => step(`sees the ${kind} poll "${question}"`, () =>
    expect(this.item(question)).toContainText(kind));
  enablesQA = () => step("allows Q&A for the deck", async () => {
    await this.tab("Q&A").click();
    await this.page.getByLabel("Allow Q&A").check();
    await expect(this.page.getByLabel("Allow Q&A")).toBeChecked();
  });
  sharesDeckWith = (email: string, flags: string[]) => step(`shares the deck with ${email} (${flags.join(", ")})`, async () => {
    await this.tab("Share").click();
    const form = this.page.locator("form").filter({ has: this.page.getByLabel("Email") });
    await form.getByLabel("Email").fill(email);
    for (const flag of flags) await form.getByLabel(flag, { exact: true }).check();
    await form.getByRole("button", { name: "Share" }).click();
    await expect(this.item(email)).toBeVisible();
  });
  cannotShare = () => step("cannot share the deck", async () => {
    await expect(this.tab(/^Sessions/)).toBeVisible();
    await expect(this.tab("Share")).toHaveCount(0);
  });

  // running a session

  startsSession = (label: string) => step(`starts the session "${label}"`, async () => {
    await this.tab(/^Sessions/).click();
    await this.page.getByLabel("Session label").fill(label);
    await this.page.getByRole("button", { name: "Start session" }).click();
    await expect(this.page).toHaveURL(/\/sessions\/[^/]+$/);
  });
  // read from the link instead of the clipboard
  screenLink = () => step("gets the screen link", async () => {
    await this.page.getByText("Session", { exact: true }).click();
    const href = await this.page.getByRole("navigation", { name: "Session" }).getByRole("link", { name: "Open screen" }).getAttribute("href");
    await this.page.keyboard.press("Escape");
    return href!;
  });
  nextSlide = () => step("goes to the next slide", () =>
    this.region("Slides").getByRole("button", { name: /^Next/ }).click());
  putsOnScreen = (what: Overlay) => step(`puts ${what} on the screen`, () =>
    this.region("On screen").getByRole("group", { name: "Over the slide" }).getByRole("button", { name: new RegExp(`^${what}`) }).click());

  // polls

  opensPoll = (question: string) => step(`opens the poll "${question}"`, () =>
    this.region("Polls").getByRole("listitem").filter({ hasText: question }).getByRole("button", { name: /^Open/ }).click());
  revealsResults = () => step("reveals the results", () => this.region("On screen").getByRole("button", { name: /^Reveal results/ }).click());
  closesVoting = () => step("closes voting", () => this.region("Voting").getByRole("button", { name: /^Close voting/ }).click());

  // Q&A

  opensQA = () => step("opens Q&A to the audience", () => this.page.getByRole("button", { name: "Open Q&A" }).click());
  putsQAOnScreen = () => step("shows the Q&A screen", () => this.page.getByRole("button", { name: "Show Q&A screen" }).click());
  seesQuestion = (text: string) => step(`sees the question "${text}"`, () => expect(this.item(text)).toBeVisible());
  putsQuestionOnScreen = (text: string) => step(`puts the question "${text}" on the screen`, () =>
    this.item(text).getByRole("button", { name: "Show question" }).click());
  marksAnswered = (text: string) => step(`marks "${text}" answered`, () =>
    this.item(text).getByRole("button", { name: "Mark answered" }).click());
}
