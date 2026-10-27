import { screen } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { afterEach, describe, expect, test } from "vitest";
import { server } from "./test/handlers";
import { renderApp } from "./test/render";

function setMeta(content: string | null) {
  document.head.querySelectorAll('meta[name="build-id"]').forEach((m) => m.remove());
  if (content === null) return;
  const meta = document.createElement("meta");
  meta.name = "build-id";
  meta.content = content;
  document.head.append(meta);
}

afterEach(() => setMeta(null));

describe("Footer", () => {
  test("shows the build id from the meta tag", async () => {
    setMeta("20261027-37434d8");
    renderApp("/notes");
    expect(await screen.findByText("Build 20261027-37434d8")).toBeInTheDocument();
  });

  test("shows a -dirty id unchanged", async () => {
    setMeta("20261027-37434d8-dirty");
    renderApp("/notes");
    expect(await screen.findByText("Build 20261027-37434d8-dirty")).toBeInTheDocument();
  });

  test("shows dev while the placeholder is not replaced (Vite dev server)", async () => {
    setMeta("__BUILD_ID__");
    renderApp("/notes");
    expect(await screen.findByText("Build dev")).toBeInTheDocument();
  });

  test("shows dev when the meta tag is missing or empty", async () => {
    renderApp("/notes");
    expect(await screen.findByText("Build dev")).toBeInTheDocument();
    setMeta("");
    renderApp("/notes");
    expect(await screen.findAllByText("Build dev")).toHaveLength(2);
  });

  test.each([
    ["login", "/login", true],
    ["notes", "/notes", false],
    ["not-found", "/no/such/page", false],
  ])("is present on the %s route", async (_name, path, signedOut) => {
    if (signedOut) {
      server.use(http.get("*/api/me", () => HttpResponse.json({ error: "unauthorized" }, { status: 401 })));
    }
    setMeta("20261027-37434d8");
    renderApp(path);
    expect(await screen.findByText("Build 20261027-37434d8")).toBeInTheDocument();
    expect(screen.getByRole("contentinfo")).toBeInTheDocument();
  });
});
