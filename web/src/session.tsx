import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { client, errorMessage, setUnauthorizedHandler, type User } from "./api/client";

interface Session {
  user: User | null;
  loading: boolean;
  /** Resolves to an error message, or null on success. */
  login: (email: string, password: string) => Promise<string | null>;
  logout: () => Promise<void>;
}

const SessionContext = createContext<Session | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setUnauthorizedHandler(() => setUser(null));
    client.GET("/api/me").then(({ data }) => {
      if (!active) return;
      setUser(data ?? null);
      setLoading(false);
    });
    return () => {
      active = false;
      setUnauthorizedHandler(undefined);
    };
  }, []);

  const login = useCallback(async (email: string, password: string) => {
    const { data, error } = await client.POST("/api/login", { body: { email, password } });
    if (data) {
      setUser(data);
      return null;
    }
    return errorMessage(error, "Could not sign in. Try again.");
  }, []);

  const logout = useCallback(async () => {
    await client.POST("/api/logout");
    setUser(null);
  }, []);

  const value = useMemo(() => ({ user, loading, login, logout }), [user, loading, login, logout]);
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): Session {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useSession must be used inside SessionProvider");
  return ctx;
}
