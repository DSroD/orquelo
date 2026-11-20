import { test } from "../support";

const MiB = 1024 * 1024;

test("A lecturer uploads a PDF and writes polls for it", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.uploadsDeck("Algebra", { pages: 3 });
  await ada.addsPoll({ question: "Pick one", options: ["First", "Second"], slide: 2 });
  await ada.addsPoll({ question: "Pick all", options: ["A", "B", "C"], kind: "multi" });
  await ada.seesPoll("Pick one", "single");
  await ada.seesPoll("Pick all", "multi");

  await ada.opensDeckList();
  await ada.seesDeck("Algebra", { slides: 3 });
});

test("A deck that would exceed the storage quota is refused", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.uploadsDeck("First half", { padTo: 1.6 * MiB });

  await ada.opensDeckList();
  await ada.triesToUploadDeck("Second half", { padTo: 1.6 * MiB });
  await ada.seesUploadError("Not enough storage left");
  await ada.seesStorageUsed("1.6 MB / 3 MB · 53% used");
});

test("A PDF over the per-deck limit is refused", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.triesToUploadDeck("Too big", { padTo: 2.5 * MiB });
  await ada.seesUploadError("Deck over the 2 MB per-deck limit");
});
