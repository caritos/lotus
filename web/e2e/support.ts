import { expect, type Page } from "@playwright/test";

// Throwaway credentials for the temp database the harness creates. Never used anywhere real.
export const TEST_EMAIL = "e2e@example.com";
export const TEST_PASSWORD = "e2e-throwaway-password";

export async function signIn(page: Page, password: string = TEST_PASSWORD): Promise<void> {
  await page.goto("/app/login");
  await page.getByLabel("Email").fill(TEST_EMAIL);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Sign in" }).click();
}

export async function signInAndWait(page: Page): Promise<void> {
  await signIn(page);
  await expect(page.getByRole("heading", { name: "Notes" })).toBeVisible();
}

let counter = 0;
export function uniqueTitle(prefix: string): string {
  counter += 1;
  return `${prefix} ${Date.now()}-${counter}`;
}

export async function createNote(page: Page, title: string, body = ""): Promise<void> {
  await page.getByLabel("Title").fill(title);
  await page.getByLabel("Body").fill(body);
  await page.getByRole("button", { name: "Add note" }).click();
  await expect(page.getByRole("link", { name: title })).toBeVisible();
}
