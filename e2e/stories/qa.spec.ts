import { test } from "../support";

test("Students ask questions and the presenter puts one on screen", async ({ cast }) => {
  const question = "Why is the sky blue?";
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.uploadsDeck("Optics");
  await ada.enablesQA();
  await ada.startsSession("Class B");

  const screen = await cast.screen(await ada.screenLink());
  await ada.putsOnScreen("QR code");
  const joinUrl = await screen.joinUrl();
  const eve = await cast.student();
  const max = await cast.student();
  await eve.joins(joinUrl);
  await max.joins(joinUrl);
  await ada.opensQA();
  await ada.putsQAOnScreen();
  await screen.showsQA();

  await eve.asks(question);
  await max.doesNotSee(question);
  await ada.seesQuestion(question);
  await ada.putsQuestionOnScreen(question);
  await screen.showsQuestion(question);

  await ada.marksAnswered(question);
  await eve.seesQuestionStatus(question, "answered");
});
