import { admin, test } from "../support";

test("A lecturer signs in with the password the admin gave them", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();
  await ada.seesTheirAccount();
});

test("A wrong password and an unknown email get the same answer", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.triesToSignIn("not the password");
  await ada.seesSignInError("Wrong email or password.");

  const mallory = await cast.stranger("mallory@example.org");
  await mallory.triesToSignIn("not the password");
  await mallory.seesSignInError("Wrong email or password.");
});

test("Changing the password signs out every other browser", async ({ cast }) => {
  const laptop = await cast.presenter("Ada");
  const office = await laptop.inAnotherBrowser();
  await laptop.signsIn();
  await office.signsIn();

  const oldPassword = laptop.password;
  await laptop.changesPassword("a brand new password");
  await office.isSignedOut();
  await laptop.opensDeckList();

  await office.triesToSignIn(oldPassword);
  await office.seesSignInError("Wrong email or password.");
  await office.signsIn("a brand new password");
});

test("A suspended lecturer is turned away", async ({ cast }) => {
  const ada = await cast.presenter("Ada");
  await ada.signsIn();

  admin.suspendUser(ada.email);
  await ada.isSignedOut(); // suspending ends the sessions
  await ada.triesToSignIn(ada.password);
  await ada.seesSignInError("This account is suspended");

  admin.activateUser(ada.email);
  await ada.signsIn();
});
