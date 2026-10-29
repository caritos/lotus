// Empties the Go embed directory of build output, keeping .gitkeep, so stale
// hashed assets never accumulate (vite's emptyOutDir is off).
import { existsSync, readdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function cleanApp(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    if (name === ".gitkeep") continue;
    rmSync(join(dir, name), { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const here = fileURLToPath(new URL(".", import.meta.url));
  cleanApp(resolve(here, "..", "api", "embed", "spa"));
}
