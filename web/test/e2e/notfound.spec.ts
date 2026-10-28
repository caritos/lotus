import { expect, test } from "@playwright/test";
import { signInAndWait } from "./support";

test("unknown URL shows 404 page", async ({ page }) => {
  const res = await page.request.get("/nope");
  expect(res.status()).toBe(404);
  expect(res.headers()["content-type"]).toContain("text/html");
  expect(await res.text()).toContain("Page not found");

  const nav = await page.goto("/nope");
  expect(nav?.status()).toBe(404);
  await expect(page.getByText("Page not found").first()).toBeVisible();
});

test("signed-out visit to /app/notes redirects to login", async ({ browser, baseURL }) => {
  const context = await browser.newContext({ baseURL });
  const page = await context.newPage();
  await page.goto("/app/notes");
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await expect(page).toHaveURL(/\/app\/login$/);
  await context.close();
});

test("unknown in-app route shows not found", async ({ page }) => {
  await signInAndWait(page);
  await page.goto("/app/does/not/exist");
  await expect(page.getByRole("heading", { name: "Page not found" })).toBeVisible();
});

test("public pages are served", async ({ request }) => {
  for (const path of ["/", "/faq", "/privacy", "/terms", "/support"]) {
    const res = await request.get(path);
    expect(res.status(), path).toBe(200);
    expect(res.headers()["content-type"], path).toContain("text/html");
    expect((await res.text()).replace(/<[^>]*>/g, "").trim().length, path).toBeGreaterThan(50);
  }
});
