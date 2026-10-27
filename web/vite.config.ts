import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  base: "/app/",
  plugins: [react()],
  build: {
    outDir: "api/internal/web/app",
    // The Go embed directory holds a committed .gitkeep; scripts/clean-app.mjs
    // (the prebuild step) removes stale files instead.
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
    exclude: ["e2e/**", "node_modules/**"],
  },
});
