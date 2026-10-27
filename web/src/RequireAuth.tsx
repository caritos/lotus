import { Navigate, Outlet } from "react-router-dom";
import { useSession } from "./session";

export function RequireAuth() {
  const { user, loading } = useSession();
  if (loading) return <p>Loading...</p>;
  if (!user) return <Navigate to="/login" replace />;
  return <Outlet />;
}
