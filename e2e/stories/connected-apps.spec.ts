import { expect, test } from "../support";

test("An agent connects with the lecturer's consent, reads their decks, and loses access when disconnected", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.uploadsDeck("Intro to Racket");
  await ada.logsOut();

  const agent = cast.mcpClient("Claude Agent");
  await agent.startsConnecting(ada.page);
  await ada.signsInWhereSent();
  await ada.seesConsentFor("Claude Agent", ["decks", "results"]);
  await ada.approvesConnection();
  await agent.exchangesCode();

  const { decks } = await agent.call("list_decks");
  expect(decks.map((d: { title: string }) => d.title)).toEqual(["Intro to Racket"]);

  await ada.disconnects("Claude Agent");
  expect(await agent.callStatus("list_decks")).toBe(401);
});

test("Denying a connection sends the agent back with access_denied and no code", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();

  const agent = cast.mcpClient();
  await agent.startsConnecting(ada.page);
  await ada.seesConsentFor("Claude Agent", ["decks", "results"]);
  await ada.deniesConnection();

  const cb = await agent.receivesCallback();
  expect(cb.error).toBe("access_denied");
  expect(cb.code).toBeNull();
});
