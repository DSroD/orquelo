import { expect, test } from "../support";

const question = "What evidence supports the choice of a template when cases share some fields but lead to different recursion patterns? ".repeat(5).slice(0, 500);
const prefix = "This answer describes the examples used to test the base and recursive cases, including which properties hold for empty, repeated, and differently ordered inputs.";
const options = Array.from({ length: 30 }, (_, i) => `${i === 28 ? "W".repeat(185) : prefix} Check case ${i + 1}.`);

test("The lecturer controls the projector rotation through every long answer", async ({ cast }) => {
  const lecturer = await cast.presenter("Grace");
  await lecturer.signsIn();
  await lecturer.uploadsDeck("Data definitions");
  const short = "Which case comes first?";
  await lecturer.addsPoll({ question: short, options: ["Base", "Recursive"], slide: 1 });
  await lecturer.addsPoll({ question, options, slide: 1 });
  await lecturer.startsSession("Projector pages");
  const onScreen = lecturer.page.getByRole("region", { name: "On screen" });
  const setup = onScreen.getByRole("link", { name: "Open screen" });
  await expect(setup).toBeVisible();
  await expect(onScreen.getByRole("button", { name: "Copy audience link" })).toBeVisible();
  const projector = await cast.screen((await setup.getAttribute("href"))!);
  await projector.page.setViewportSize({ width: 1280, height: 720 });
  await projector.page.clock.install();
  await expect(setup).toHaveCount(0);

  const shortReport = projector.page.waitForResponse((res) => res.url().endsWith("/page") && res.status() === 204);
  await lecturer.opensPoll(short);
  await projector.showsPoll(short);
  expect((await shortReport).request().postDataJSON()).toMatchObject({ page: 1, total: 1 });
  await expect(onScreen.getByRole("group", { name: "Projector pages" })).toHaveCount(0);
  await lecturer.closesVoting();

  await lecturer.opensPoll(question);
  await projector.showsPoll(question);
  const audienceUrl = await projector.joinUrl();
  const student = await cast.student(audienceUrl);
  await student.votes(options[29]);
  await projector.hidesCounts();
  const rows = projector.page.getByRole("listitem");
  await expect(rows.first()).toContainText(options[0]);
  await expect(rows.first()).not.toContainText("#1");

  await lecturer.revealsResults();
  await projector.showsResult(options[29], 1, 100);
  await expect(rows.first()).toContainText(options[29]);
  await expect(projector.page.getByRole("button")).toHaveCount(0);
  await expect(lecturer.page.getByRole("region", { name: "Voting" }).getByRole("button", { name: /^Close voting/ }))
    .toBeInViewport({ ratio: 1 });

  await lecturer.page.setViewportSize({ width: 360, height: 740 });
  const dock = lecturer.page.getByRole("group", { name: "Lecture controls" });
  await expect(dock.getByRole("button", { name: "Close voting" })).toHaveAccessibleDescription(question.trim());
  const controls = lecturer.page.getByRole("group", { name: "Projector pages" });
  await controls.getByRole("button", { name: "Pause rotation" }).click();
  const view = projector.page.getByText(/^View \d+ \/ \d+/);
  await expect(view).toHaveText(/^View 1 \/ \d+ · paused/);
  await projector.page.clock.runFor(60_000);
  await expect(view).toHaveText(/^View 1 \/ \d+ · paused/);
  await expect(controls.getByRole("status")).toHaveText(/^View 1 \/ \d+$/);
  await controls.getByRole("button", { name: "Next page" }).click();
  await expect(controls.getByRole("status")).toHaveText(/^View 2 \/ \d+$/);

  const modes = onScreen.getByRole("group", { name: "Over the slide" });
  await modes.getByRole("button", { name: /^Slide only/ }).focus();
  await lecturer.page.keyboard.press("Tab");
  const qr = modes.getByRole("button", { name: /^QR code/ });
  await expect(qr).toBeFocused();
  await expect(qr).toBeInViewport({ ratio: 1 });

  const lateStudent = await cast.student(audienceUrl);
  await lateStudent.votes(options[0]);
  await dock.getByRole("button", { name: "Close voting" }).click();
  await expect(projector.page.getByText(/^2 votes · voting closed/)).toBeVisible();
  await expect(view).toHaveText(/^View 1 \/ \d+ · paused$/);
  await expect(rows.first()).toContainText(options[0]);
  await expect(controls.getByRole("status")).toHaveText(/^View 1 \/ \d+$/);

  const fits = () => rows.evaluateAll((items) => items.length > 0 && items.every((item) => {
    const area = item.closest(".answers")!.getBoundingClientRect();
    const rect = item.getBoundingClientRect();
    const label = item.querySelector(".label")!;
    return rect.bottom <= area.bottom + 1 && rect.right <= area.right + 1
      && label.scrollWidth <= label.clientWidth + 1 && label.scrollHeight <= label.clientHeight + 1;
  }));
  for (const [width, height] of [[1280, 720], [1920, 1080], [1024, 768]]) {
    await projector.page.setViewportSize({ width, height });
    await projector.page.clock.runFor(50);
    await expect.poll(fits).toBe(true);
    expect(await projector.page.getByRole("heading", { name: question }).evaluate((heading) =>
      heading.scrollWidth <= heading.clientWidth + 1 && heading.scrollHeight <= heading.clientHeight + 1)).toBe(true);
  }

  const pageCount = Number((await view.textContent())?.match(/\/ (\d+)/)?.[1]);
  expect(pageCount).toBeGreaterThan(1);
  const seen = [];
  for (let page = 1; page <= pageCount; page++) {
    await expect(view).toContainText(`View ${page} / ${pageCount} · paused`);
    seen.push(...await rows.locator(".label").allTextContents());
    expect(await fits()).toBe(true);
    if (page < pageCount) await controls.getByRole("button", { name: "Next page" }).click();
  }
  expect(seen.toSorted()).toEqual(options.toSorted());

  await controls.getByRole("button", { name: "Resume rotation" }).click();
  await expect(view).not.toContainText("paused");
  await projector.page.clock.runFor(60_000);
  await expect(view).not.toContainText(`View ${pageCount} / ${pageCount}`);
});
