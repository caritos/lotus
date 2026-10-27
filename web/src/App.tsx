import { Navigate, Route, Routes } from "react-router-dom";
import { Footer } from "./Footer";
import { RequireAuth } from "./RequireAuth";
import { Login } from "./pages/Login";
import { NoteEdit } from "./pages/NoteEdit";
import { NotFound } from "./pages/NotFound";
import { Notes } from "./pages/Notes";
import { SessionProvider } from "./session";

/** The app routes; the caller supplies the router so tests can use a memory router. */
export function App() {
  return (
    <SessionProvider>
      <Routes>
        <Route path="/" element={<Navigate to="/notes" replace />} />
        <Route path="/login" element={<Login />} />
        <Route element={<RequireAuth />}>
          <Route path="/notes" element={<Notes />} />
          <Route path="/notes/:id" element={<NoteEdit />} />
        </Route>
        <Route path="*" element={<NotFound />} />
      </Routes>
      <Footer />
    </SessionProvider>
  );
}
