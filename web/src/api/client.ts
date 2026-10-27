import createClient from "openapi-fetch";
import type { components, paths } from "./schema";

export type Note = components["schemas"]["Note"];
export type User = components["schemas"]["User"];

// An absolute base keeps Request construction valid outside a browser page
// (jsdom tests); in the browser it is the page's own origin.
export const client = createClient<paths>({
  baseUrl: globalThis.location?.origin ?? "",
  credentials: "include",
  // Resolve fetch per call (not at creation) so test interceptors installed
  // after this module loads still apply.
  fetch: (request) => globalThis.fetch(request),
});

let onUnauthorized: (() => void) | undefined;

/** Registers the callback run when any API call other than login returns 401. */
export function setUnauthorizedHandler(fn: (() => void) | undefined): void {
  onUnauthorized = fn;
}

client.use({
  onResponse({ response }) {
    if (response.status === 401 && !new URL(response.url, "http://x").pathname.endsWith("/api/login")) {
      onUnauthorized?.();
    }
  },
});

/** Message from an API error body, or a fallback. */
export function errorMessage(error: { error: string } | undefined, fallback: string): string {
  return error?.error ?? fallback;
}

/** Uploads or replaces a note's photo as multipart/form-data with field "photo". */
export function putPhoto(id: string, file: File) {
  return client.PUT("/api/notes/{id}/photo", {
    params: { path: { id } },
    // The generated type models the binary field as a string; the real
    // payload is built by the serializer below.
    body: { photo: file.name },
    bodySerializer: () => {
      const form = new FormData();
      form.append("photo", file);
      return form;
    },
  });
}
