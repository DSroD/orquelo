import { test } from "../support";

test("Sharing a deck by email lets a colleague moderate it", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  const bob = await cast.presenter("Bob");
  await ada.signsIn();
  await ada.uploadsDeck("Shared deck");
  await ada.sharesDeckWith(bob.email, ["moderate"]);

  await bob.signsIn();
  await bob.seesDeck("Shared deck", { tag: "shared · moderate" });
  await bob.opensDeck("Shared deck");
  await bob.cannotShare();
});
