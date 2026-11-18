import { test } from "../support";

test("A lecture with a projector and two students voting", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.uploadsDeck("Algebra", { pages: 3 });
  await ada.addsPoll({ question: "Pick one", options: ["First", "Second"], slide: 2 });

  await ada.startsSession("Class A");
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
