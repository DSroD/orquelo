import { expect, test, type Page } from "@playwright/test";

const step = <T>(title: string, body: () => Promise<T>): Promise<T> => test.step(title, body);

// The projector: a desktop browser on the screen link, no login.
export class Projector {
  constructor(readonly page: Page) {}

  // the QR code carries the students' link, so reading its alt text is "scanning" it
  joinUrl = () => step("scans the QR code", async () => {
    const qr = this.page.getByRole("img", { name: /^QR code for / });
    await expect(qr).toBeVisible();
    return (await qr.getAttribute("alt"))!.replace(/^QR code for /, "");
  });
  showsSlide = (n: number) => step(`shows slide ${n}`, () => expect(this.page.getByRole("img", { name: `Slide ${n}` })).toBeVisible());
  showsPoll = (question: string) => step(`shows the poll "${question}"`, () =>
    expect(this.page.getByRole("heading", { level: 1, name: question })).toBeVisible());
  showsVoters = (n: number, { revealed }: { revealed: boolean }) => step(`shows ${n} voters`, () =>
    expect(this.page.getByText(new RegExp(`^${n} ${revealed ? (n === 1 ? "vote" : "votes") : "voted"}\\b`))).toBeVisible());
  hidesCounts = () => step("hides the counts", () => expect(this.page.getByText(/· \d+%/)).toHaveCount(0));
  showsResult = (label: string, count: number, pct: number) => step(`shows ${label}: ${count} · ${pct}%`, () =>
    expect(this.page.getByRole("listitem").filter({ hasText: label }).filter({ hasText: `${count} · ${pct}%` })).toBeVisible());
  showsQA = () => step("shows the Q&A screen", () => expect(this.page.getByRole("heading", { level: 1, name: "Q&A" })).toBeVisible());
  showsQuestion = (text: string) => step(`shows the question "${text}"`, () => expect(this.page.getByText(text)).toBeVisible());
}
