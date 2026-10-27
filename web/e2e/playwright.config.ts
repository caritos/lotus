import { defineConfig } from "@playwright/test";
import { freePort } from "./ports";

// Evaluated in the runner before globalSetup; workers inherit the env var, so
// everyone agrees on the port.
if (!process.env.E2E_PORT) process.env.E2E_PORT = String(await freePort());
const port = process.env.E2E_PORT;

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  outputDir: "./test-results",
  globalSetup: "./global-setup.ts",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"], ["html", { outputFolder: "./playwright-report", open: "never" }]],
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
  },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
});
