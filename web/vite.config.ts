import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  base: "/app/",
  // web/public holds the pages and static files Go renders (sync-public.sh copies them to
  // web/api/embed); Vite's default would also copy them into the React bundle.
  publicDir: false,
  plugins: [react()],
  build: {
    outDir: "api/embed/spa",
    // The React bundle goes to web/api/embed/spa (served under the /app/ URL); the embed
    // directory also holds pages/ and static/ from sync-public.sh, so web/scripts/clean-app.mjs
    // (the prebuild step) removes only stale spa/ files instead.
    emptyOutDir: false,
  },
  server: {
    port: 5173,
    proxy: {
      // The dev API listens on loopback IPv4 only (make dev sets ADDR=127.0.0.1:8080).
      "/api": "http://127.0.0.1:8080",
      "/healthz": "http://127.0.0.1:8080",
    },
    watch: {
      ignored: ["**/db/**", "**/logs/**", "**/storage/**", "**/api/**"],
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}", "scripts/**/*.test.ts"],
    exclude: ["test/e2e/**", "node_modules/**"],
  },
});
