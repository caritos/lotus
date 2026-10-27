import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
// @ts-expect-error plain ESM script without type declarations
import { cleanApp } from "./clean-app.mjs";

let dir = "";
afterEach(() => rmSync(dir, { recursive: true, force: true }));

test("cleanApp removes everything except .gitkeep", () => {
  dir = mkdtempSync(join(tmpdir(), "clean-app-"));
  writeFileSync(join(dir, ".gitkeep"), "");
  writeFileSync(join(dir, "index.html"), "x");
  mkdirSync(join(dir, "assets"));
  writeFileSync(join(dir, "assets", "old-abc123.js"), "x");
  cleanApp(dir);
  expect(readdirSync(dir)).toEqual([".gitkeep"]);
});

test("cleanApp is a no-op for a missing directory", () => {
  dir = join(tmpdir(), "clean-app-missing-" + Date.now());
  expect(() => cleanApp(dir)).not.toThrow();
});
