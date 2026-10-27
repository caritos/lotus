import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { client, errorMessage, type Note } from "../api/client";
import { useSession } from "../session";

export function Notes() {
  const { user, logout } = useSession();
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");

  useEffect(() => {
    let active = true;
    client.GET("/api/notes").then(({ data, error: err }) => {
      if (!active) return;
      if (data) setNotes(data);
      else if (err) setError(errorMessage(err, "Could not load notes."));
    });
    return () => {
      active = false;
    };
  }, []);

  async function onAdd(e: FormEvent) {
    e.preventDefault();
    setError(null);
    const { data, error: err } = await client.POST("/api/notes", { body: { title, body } });
    if (data) {
      setNotes((prev) => [data, ...(prev ?? [])]);
      setTitle("");
      setBody("");
    } else if (err) {
      setError(errorMessage(err, "Could not add the note."));
    }
  }

  return (
    <main>
      <header className="bar">
        <h1>Notes</h1>
        <span>{user?.email}</span>
        <button type="button" onClick={() => void logout()}>Sign out</button>
      </header>
      {error && <p role="alert">{error}</p>}
      {notes === null && !error && <p>Loading...</p>}
      {notes?.length === 0 && <p>No notes yet.</p>}
      <ul>
        {notes?.map((n) => (
          <li key={n.id}><Link to={`/notes/${n.id}`}>{n.title}</Link></li>
        ))}
      </ul>
      <h2>New note</h2>
      <form onSubmit={onAdd}>
        <label htmlFor="new-title">Title</label>
        <input id="new-title" required value={title} onChange={(e) => setTitle(e.target.value)} />
        <label htmlFor="new-body">Body</label>
        <textarea id="new-body" value={body} onChange={(e) => setBody(e.target.value)} />
        <button type="submit">Add note</button>
      </form>
    </main>
  );
}
