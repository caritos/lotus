import { http, HttpResponse } from "msw";
import { setupServer } from "msw/node";
import type { components } from "../api/schema";

type Note = components["schemas"]["Note"];
type User = components["schemas"]["User"];

export const testUser: User = { id: "u1", email: "me@example.com" };

export const sampleNotes: Note[] = [
  { id: "n1", title: "First note", body: "Hello", photo: false, created_at: 1000, updated_at: 1000 },
  { id: "n2", title: "Second note", body: "World", photo: false, created_at: 2000, updated_at: 2000 },
];

export let notes: Note[] = [];

export function resetState(): void {
  notes = sampleNotes.map((n) => ({ ...n }));
}
resetState();

/** Requests the handlers received, for assertions on what the UI sent. */
export const received = {
  patches: [] as unknown[],
  photoForms: [] as FormData[],
};

export const handlers = [
  http.get("*/api/me", () => HttpResponse.json(testUser)),
  http.post("*/api/login", async ({ request }) => {
    const body = (await request.json()) as { email: string; password: string };
    if (body.password === "secret-pass") return HttpResponse.json({ id: testUser.id, email: body.email });
    return HttpResponse.json({ error: "invalid email or password" }, { status: 401 });
  }),
  http.post("*/api/logout", () => new HttpResponse(null, { status: 204 })),
  http.get("*/api/notes", () => HttpResponse.json(notes)),
  http.post("*/api/notes", async ({ request }) => {
    const input = (await request.json()) as { title: string; body: string };
    const note: Note = { id: `n${notes.length + 1}`, ...input, photo: false, created_at: 3000, updated_at: 3000 };
    notes = [note, ...notes];
    return HttpResponse.json(note, { status: 201 });
  }),
  http.get("*/api/notes/:id", ({ params }) => {
    const note = notes.find((n) => n.id === params["id"]);
    return note ? HttpResponse.json(note) : HttpResponse.json({ error: "not found" }, { status: 404 });
  }),
  http.patch("*/api/notes/:id", async ({ params, request }) => {
    const patch = (await request.json()) as { title?: string; body?: string };
    received.patches.push(patch);
    const note = notes.find((n) => n.id === params["id"]);
    if (!note) return HttpResponse.json({ error: "not found" }, { status: 404 });
    Object.assign(note, patch, { updated_at: note.updated_at + 1 });
    return HttpResponse.json(note);
  }),
  http.delete("*/api/notes/:id", ({ params }) => {
    notes = notes.filter((n) => n.id !== params["id"]);
    return new HttpResponse(null, { status: 204 });
  }),
  http.put("*/api/notes/:id/photo", async ({ params, request }) => {
    received.photoForms.push(await request.formData());
    const note = notes.find((n) => n.id === params["id"]);
    if (!note) return HttpResponse.json({ error: "not found" }, { status: 404 });
    note.photo = true;
    note.updated_at = 9999;
    return HttpResponse.json(note);
  }),
  http.delete("*/api/notes/:id/photo", ({ params }) => {
    const note = notes.find((n) => n.id === params["id"]);
    if (note) note.photo = false;
    return new HttpResponse(null, { status: 204 });
  }),
];

export const server = setupServer(...handlers);
