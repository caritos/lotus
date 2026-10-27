import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { http, HttpResponse } from "msw";
import { describe, expect, test } from "vitest";
import { received, server } from "./test/handlers";
import { renderApp } from "./test/render";

const signedOut = () =>
  server.use(http.get("*/api/me", () => HttpResponse.json({ error: "unauthorized" }, { status: 401 })));

describe("Login", () => {
  test("Login shows error on 401", async () => {
    signedOut();
    renderApp("/login");
    await userEvent.type(await screen.findByLabelText("Email"), "me@example.com");
    await userEvent.type(screen.getByLabelText("Password"), "wrong");
    await userEvent.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("invalid email or password");
    expect(screen.getByRole("heading", { name: "Sign in" })).toBeInTheDocument();
  });

  test("Login redirects to notes on success", async () => {
    signedOut();
    renderApp("/login");
    await userEvent.type(await screen.findByLabelText("Email"), "me@example.com");
    await userEvent.type(screen.getByLabelText("Password"), "secret-pass");
    await userEvent.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByRole("heading", { name: "Notes" })).toBeInTheDocument();
    expect(await screen.findByText("First note")).toBeInTheDocument();
  });
});

describe("Notes", () => {
  test("Notes lists notes from the API", async () => {
    renderApp("/notes");
    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(await screen.findByRole("link", { name: "First note" })).toHaveAttribute("href", "/notes/n1");
    expect(screen.getByRole("link", { name: "Second note" })).toBeInTheDocument();
  });

  test("new note form adds a note to the list", async () => {
    renderApp("/notes");
    await userEvent.type(await screen.findByLabelText("Title"), "Fresh");
    await userEvent.type(screen.getByLabelText("Body"), "text");
    await userEvent.click(screen.getByRole("button", { name: "Add note" }));
    expect(await screen.findByRole("link", { name: "Fresh" })).toBeInTheDocument();
  });
});

describe("NoteEdit", () => {
  test("NoteEdit saves title and body", async () => {
    renderApp("/notes/n1");
    const title = await screen.findByLabelText("Title");
    expect(title).toHaveValue("First note");
    await userEvent.clear(title);
    await userEvent.type(title, "Renamed");
    const body = screen.getByLabelText("Body");
    await userEvent.clear(body);
    await userEvent.type(body, "New body");
    await userEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByRole("status")).toHaveTextContent("Saved");
    expect(received.patches).toEqual([{ title: "Renamed", body: "New body" }]);
  });

  test("NoteEdit uploads a photo and shows it", async () => {
    renderApp("/notes/n1");
    const input = await screen.findByLabelText("Photo");
    const file = new File(["fake-bytes"], "cat.png", { type: "image/png" });
    await userEvent.upload(input, file);
    await userEvent.click(screen.getByRole("button", { name: "Upload photo" }));
    const img = await screen.findByRole("img", { name: /photo/i });
    expect(img).toHaveAttribute("src", "/api/notes/n1/photo?v=9999");
    expect(received.photoForms).toHaveLength(1);
    const sent = received.photoForms[0]?.get("photo");
    expect(sent).toBeInstanceOf(File);
    expect((sent as File).name).toBe("cat.png");
  });

  test("NoteEdit removes a photo", async () => {
    renderApp("/notes/n1");
    await userEvent.upload(await screen.findByLabelText("Photo"), new File(["x"], "a.png", { type: "image/png" }));
    await userEvent.click(screen.getByRole("button", { name: "Upload photo" }));
    await screen.findByRole("img", { name: /photo/i });
    await userEvent.click(screen.getByRole("button", { name: "Remove photo" }));
    await waitFor(() => expect(screen.queryByRole("img", { name: /photo/i })).not.toBeInTheDocument());
  });

  test("NoteEdit deletes the note and returns to the list", async () => {
    renderApp("/notes/n1");
    await userEvent.click(await screen.findByRole("button", { name: "Delete note" }));
    expect(await screen.findByRole("heading", { name: "Notes" })).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByText("First note")).not.toBeInTheDocument());
  });
});

describe("routing and session", () => {
  test("unauthenticated visit redirects to login", async () => {
    signedOut();
    renderApp("/notes");
    expect(await screen.findByRole("heading", { name: "Sign in" })).toBeInTheDocument();
  });

  test("root redirects to notes", async () => {
    renderApp("/");
    expect(await screen.findByRole("heading", { name: "Notes" })).toBeInTheDocument();
  });

  test("unknown route shows the not-found page", async () => {
    renderApp("/nope/at/all");
    expect(await screen.findByRole("heading", { name: "Page not found" })).toBeInTheDocument();
  });

  test("401 during a call returns to login", async () => {
    server.use(http.get("*/api/notes", () => HttpResponse.json({ error: "unauthorized" }, { status: 401 })));
    renderApp("/notes");
    expect(await screen.findByRole("heading", { name: "Sign in" })).toBeInTheDocument();
  });
});
