import { expect, test } from "@playwright/test";
import { createNote, signInAndWait, uniqueTitle } from "./support";

test("create edit delete note", async ({ page }) => {
  await signInAndWait(page);
  const title = uniqueTitle("Note");
  await createNote(page, title, "first body");

  await page.getByRole("link", { name: title }).click();
  await expect(page.getByRole("heading", { name: "Edit note" })).toBeVisible();
  await expect(page.getByLabel("Title")).toHaveValue(title);
  const noteUrl = page.url();

  const edited = `${title} edited`;
  await page.getByLabel("Title").fill(edited);
  await page.getByLabel("Body").fill("second body");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("status")).toHaveText("Saved");

  await page.reload();
  await expect(page.getByLabel("Title")).toHaveValue(edited);
  await expect(page.getByLabel("Body")).toHaveValue("second body");

  await page.getByRole("button", { name: "Delete note" }).click();
  await expect(page.getByRole("heading", { name: "Notes" })).toBeVisible();
  await expect(page.getByRole("link", { name: edited })).toHaveCount(0);

  await page.goto(noteUrl);
  await expect(page.getByRole("heading", { name: "Page not found" })).toBeVisible();
});
