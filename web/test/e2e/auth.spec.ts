import { expect, test } from "@playwright/test";
import { signIn, signInAndWait } from "./support";

test("sign in and out", async ({ page }) => {
  await signInAndWait(page);
  await expect(page).toHaveURL(/\/app\/notes$/);

  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await expect(page).toHaveURL(/\/app\/login$/);

  await page.goto("/app/notes");
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
});

test("wrong password shows error", async ({ page, context }) => {
  await signIn(page, "definitely-the-wrong-password");
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await expect(page).toHaveURL(/\/app\/login$/);
  const cookies = await context.cookies();
  expect(cookies.filter((c) => c.name === "goweb_session")).toEqual([]);
});
