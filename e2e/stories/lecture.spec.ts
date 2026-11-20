import { expect, test } from "../support";

test("A lecture with a projector and two students voting", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.uploadsDeck("Algebra", { pages: 3 });
  await ada.addsPoll({ question: "Pick one", options: ["First", "Second"], slide: 2 });

  await ada.startsSession("Class A");
  const navigation = ada.page.getByRole("navigation", { name: "Main navigation" });
  await expect(navigation.getByRole("link", { name: "Decks" })).toBeVisible();
  await expect(navigation.getByRole("link", { name: "Account" })).toBeVisible();
  const screen = await cast.screen(await ada.screenLink());
  await ada.putsOnScreen("QR code");
  const joinUrl = await screen.joinUrl();
  const eve = await cast.student();
  const max = await cast.student();
  await eve.joins(joinUrl);
  await max.joins(joinUrl);

  await ada.nextSlide();
  await ada.putsOnScreen("Slide only");
  await screen.showsSlide(2);

  await ada.opensPoll("Pick one");
  await eve.seesPoll("Pick one");
  await max.seesPoll("Pick one");
  const settings = eve.page.locator("footer details");
  const summary = settings.getByText("Cookie settings", { exact: true });
  const enable = settings.getByRole("button", { name: "Allow across sessions" });
  await expect(enable).toBeVisible();
  await summary.click();
  await expect(enable).toBeVisible();
  await enable.click();
  await expect(enable).toBeHidden();
  await summary.click();
  await expect(settings.getByText("Cross-session recognition is on.")).toBeVisible();
  await settings.getByRole("button", { name: "Only this session" }).click();
  await expect(enable).toBeHidden();
  const preference = eve.page.waitForResponse((r) => r.url().endsWith("/api/s/cookies"));
  await eve.page.reload();
  expect(await (await preference).json()).toEqual({ remember: false });
  await eve.seesPoll("Pick one");
  await expect(summary).toBeVisible();
  await expect(enable).toBeHidden();
  await eve.votes("First");
  await max.votes("Second");
  await screen.showsPoll("Pick one");
  await screen.showsVoters(2, { revealed: false });
  await screen.hidesCounts();

  await ada.revealsResults();
  await screen.showsVoters(2, { revealed: true });
  await screen.showsResult("First", 1, 50);
  await screen.showsResult("Second", 1, 50);

  await ada.closesVoting();
  await eve.seesVotingClosed({ recorded: true });
  await max.seesVotingClosed({ recorded: true });
  await eve.fitsThePhone();
  await max.fitsThePhone();
});
