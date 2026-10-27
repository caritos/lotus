import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { File as NodeFile } from "node:buffer";
import { afterAll, afterEach, beforeAll } from "vitest";
import { resetState, server } from "./handlers";

beforeAll(() => server.listen({ onUnhandledFrame: "error" }));
afterEach(() => {
  cleanup();
  server.resetHandlers();
  resetState();
});
afterAll(() => server.close());

// Vitest's jsdom compat layer rebuilds jsdom FormData/File bodies for fetch and
// loses the file's bytes and name. Use Node's own FormData, File and Request
// (what undici understands, and what a browser's native classes do) so the
// multipart body the app builds is sent intact.
const nodeForm = await new Response("a=b", {
  headers: { "content-type": "application/x-www-form-urlencoded" },
}).formData();
globalThis.FormData = nodeForm.constructor as typeof FormData;
globalThis.File = NodeFile as unknown as typeof File;
globalThis.Request = Object.getPrototypeOf(globalThis.Request) as typeof Request;
