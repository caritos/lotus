import { useEffect, useState, type FormEvent } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { client, errorMessage, putPhoto, type Note } from "../api/client";
import { NotFound } from "./NotFound";

export function NoteEdit() {
  const { id = "" } = useParams();
  const navigate = useNavigate();
  const [note, setNote] = useState<Note | null>(null);
  const [missing, setMissing] = useState(false);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    client.GET("/api/notes/{id}", { params: { path: { id } } }).then(({ data, response }) => {
      if (!active) return;
      if (data) {
        setNote(data);
        setTitle(data.title);
        setBody(data.body);
      } else if (response.status === 404) {
        setMissing(true);
      } else if (response.status !== 401) {
        setError("Could not load the note.");
      }
    });
    return () => {
      active = false;
    };
  }, [id]);

  if (missing) return <NotFound />;
  if (!note) return error ? <p role="alert">{error}</p> : <p>Loading...</p>;

  async function onSave(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setStatus(null);
    const { data, error: err } = await client.PATCH("/api/notes/{id}", { params: { path: { id } }, body: { title, body } });
    if (data) {
      setNote(data);
      setStatus("Saved");
    } else if (err) {
      setError(errorMessage(err, "Could not save the note."));
    }
  }

  async function onDelete() {
    setError(null);
    const { response } = await client.DELETE("/api/notes/{id}", { params: { path: { id } } });
    if (response.ok) navigate("/notes");
    else if (response.status !== 401) setError("Could not delete the note.");
  }

  async function onUpload() {
    if (!file) return;
    setError(null);
    const { data, error: err } = await putPhoto(id, file);
    if (data) {
      setNote(data);
      setFile(null);
    } else if (err) {
      setError(errorMessage(err, "Could not upload the photo."));
    }
  }

  async function onRemovePhoto() {
    setError(null);
    const { response } = await client.DELETE("/api/notes/{id}/photo", { params: { path: { id } } });
    if (response.ok) setNote({ ...note!, photo: false });
    else if (response.status !== 401) setError("Could not remove the photo.");
  }

  return (
    <main>
      <p><Link to="/notes">Back to notes</Link></p>
      <h1>Edit note</h1>
      {error && <p role="alert">{error}</p>}
      <form onSubmit={onSave}>
        <label htmlFor="title">Title</label>
        <input id="title" required value={title} onChange={(e) => setTitle(e.target.value)} />
        <label htmlFor="body">Body</label>
        <textarea id="body" value={body} onChange={(e) => setBody(e.target.value)} />
        <button type="submit">Save</button>
        {status && <p role="status">{status}</p>}
      </form>
      <h2>Photo</h2>
      {note.photo && (
        <>
          <img src={`/api/notes/${note.id}/photo?v=${note.updated_at}`} alt={`Photo for ${note.title}`} className="photo" />
          <button type="button" onClick={() => void onRemovePhoto()}>Remove photo</button>
        </>
      )}
      <label htmlFor="photo">Photo</label>
      <input id="photo" type="file" accept="image/*" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
      <button type="button" disabled={!file} onClick={() => void onUpload()}>Upload photo</button>
      <h2>Danger zone</h2>
      <button type="button" onClick={() => void onDelete()}>Delete note</button>
    </main>
  );
}
