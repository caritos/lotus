import path from "node:path";
import { expect, test, type Page } from "@playwright/test";
import { createNote, signInAndWait, uniqueTitle } from "./support";

const fixture = path.join(import.meta.dirname, "fixtures", "photo.png");

async function openNewNote(page: Page): Promise<string> {
  await signInAndWait(page);
  const title = uniqueTitle("Photo note");
  await createNote(page, title);
  await page.getByRole("link", { name: title }).click();
  await expect(page.getByRole("heading", { name: "Edit note" })).toBeVisible();
  return title;
}

async function expectLoadedImage(page: Page, title: string): Promise<void> {
  const img = page.getByRole("img", { name: `Photo for ${title}` });
  await expect(img).toBeVisible();
  await expect.poll(() => img.evaluate((el: HTMLImageElement) => el.naturalWidth)).toBeGreaterThan(0);
}

test("upload photo and see it after reload", async ({ page }) => {
  const title = await openNewNote(page);
  await page.getByLabel("Photo", { exact: true }).setInputFiles(fixture);
  await page.getByRole("button", { name: "Upload photo" }).click();
  await expectLoadedImage(page, title);

  await page.reload();
  await expectLoadedImage(page, title);
});

test("remove photo", async ({ page }) => {
  const title = await openNewNote(page);
  await page.getByLabel("Photo", { exact: true }).setInputFiles(fixture);
  await page.getByRole("button", { name: "Upload photo" }).click();
  await expectLoadedImage(page, title);

  await page.getByRole("button", { name: "Remove photo" }).click();
  await expect(page.getByRole("img")).toHaveCount(0);

  await page.reload();
  await expect(page.getByRole("heading", { name: "Edit note" })).toBeVisible();
  await expect(page.getByRole("img")).toHaveCount(0);
});

test("oversized or non-image upload shows an error", async ({ page }) => {
  await openNewNote(page);
  await page.getByLabel("Photo", { exact: true }).setInputFiles({
    name: "not-really.png",
    mimeType: "image/png",
    buffer: Buffer.from("this is plain text, not an image\n"),
  });
  await page.getByRole("button", { name: "Upload photo" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(page.getByRole("img")).toHaveCount(0);
});
