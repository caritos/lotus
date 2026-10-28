import { expect, test, type Page } from "@playwright/test";
import { signInAndWait } from "./support";

// The harness builds the binary with web/scripts/build-id.sh, so the id is a real one:
// YYYYMMDD-<7 hex>, "unknown" outside git, "-dirty" for a modified tree.
const FORMAT = /^[0-9]{8}-([0-9a-f]{7}|unknown)(-dirty)?$/;

async function healthBuildId(page: Page): Promise<string> {
  const res = await page.request.get("/healthz");
  expect(res.status()).toBe(200);
  const body = (await res.json()) as { build_id?: string };
  expect(body.build_id).toBeTruthy();
  return body.build_id ?? "";
}

test("/healthz reports a real build id", async ({ page }) => {
  const id = await healthBuildId(page);
  expect(id).toMatch(FORMAT);
  expect(id).not.toBe("00000000-unknown"); // the default of a binary built without web/scripts/build-id.sh
});

test("the footer shows the same build id on the public page, sign-in, notes and 404", async ({ page }) => {
  const id = await healthBuildId(page);
  const footer = page.locator("footer .build-id");

  await page.goto("/");
  await expect(footer).toHaveText(`Build ${id}`);

  await page.goto("/app/login");
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await expect(footer).toHaveText(`Build ${id}`);

  await signInAndWait(page);
  await expect(footer).toHaveText(`Build ${id}`);

  const res = await page.goto("/nope");
  expect(res?.status()).toBe(404);
  await expect(footer).toHaveText(`Build ${id}`);
});

test("curl-style fetches of / and /app/ contain the footer text", async ({ page }) => {
  const id = await healthBuildId(page);
  for (const path of ["/", "/app/"]) {
    const res = await page.request.get(path);
    expect(res.status(), path).toBe(200);
    const html = await res.text();
    expect(html, path).toContain(id);
    expect(html, path).not.toContain("__BUILD_ID__");
    expect(html, path).not.toContain("@@BUILD_ID@@");
  }
});
