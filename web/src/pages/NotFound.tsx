import { Link } from "react-router-dom";

export function NotFound() {
  return (
    <main>
      <h1>Page not found</h1>
      <p>We could not find that page. <Link to="/notes">Go to your notes</Link>.</p>
    </main>
  );
}
