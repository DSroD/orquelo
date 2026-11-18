import { expect, test, type Locator, type Page } from "@playwright/test";

const step = <T>(title: string, body: () => Promise<T>): Promise<T> => test.step(title, body);

export const PHONE = { viewport: { width: 360, height: 740 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 };

// A student on a 360px phone, no login.
export class Student {
  constructor(readonly page: Page) {}

  private item = (text: string): Locator => this.page.getByRole("listitem").filter({ hasText: text });

  joins = (url: string) => step("joins from the QR code", async () => {
    await this.page.goto(url);
  });
  seesPoll = (question: string) => step(`sees the poll "${question}"`, () =>
    expect(this.page.getByRole("heading", { level: 1, name: question })).toBeVisible());
  // one label is a single choice (sent on tap); several are a multiple choice (sent with Submit)
  votes = (...labels: string[]) => step(`votes ${labels.join(" + ")}`, async () => {
    if (labels.length === 1) await this.page.getByRole("radio", { name: labels[0] }).click();
    else {
      for (const l of labels) await this.page.getByRole("checkbox", { name: l }).click();
      await this.page.getByRole("button", { name: /^Submit/ }).click();
    }
    await expect(this.page.getByText("Vote recorded")).toBeVisible();
  });
  seesVotingClosed = ({ recorded }: { recorded: boolean }) => step("sees voting closed", async () => {
    const closed = this.page.getByRole("status").filter({ hasText: "Voting closed" });
    await expect(closed).toBeVisible();
    if (recorded) await expect(closed).toContainText("Your vote was recorded.");
  });
  asks = (text: string) => step(`asks "${text}"`, async () => {
    await this.page.getByRole("tab", { name: "Q&A" }).click();
    await this.page.getByLabel("Your question").fill(text);
    await this.page.getByRole("button", { name: "Send question" }).click();
    await expect(this.item(text)).toContainText("received");
  });
  seesQuestionStatus = (text: string, status: string) => step(`sees "${text}" ${status}`, () =>
    expect(this.item(text)).toContainText(status));
  doesNotSee = (text: string) => step(`does not see "${text}"`, async () => {
    await this.page.getByRole("tab", { name: "Q&A" }).click();
    await expect(this.item(text)).toHaveCount(0);
  });
  fitsThePhone = () => step("fits the phone screen", async () => {
    const width = await this.page.evaluate(() => document.documentElement.scrollWidth);
    expect(width).toBeLessThanOrEqual(PHONE.viewport.width);
  });
}
