import net from "node:net";

function tryListen(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once("error", () => resolve(false));
    srv.listen(port, "127.0.0.1", () => srv.close(() => resolve(true)));
  });
}

/** Picks a random free loopback port in 20000-40000, retrying a few times. */
export async function freePort(): Promise<number> {
  for (let i = 0; i < 20; i++) {
    const port = 20000 + Math.floor(Math.random() * 20001);
    if (await tryListen(port)) return port;
  }
  throw new Error("e2e: could not find a free port in 20000-40000");
}
