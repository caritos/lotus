import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { TEST_EMAIL, TEST_PASSWORD } from "./support";

const webDir = path.resolve(import.meta.dirname, "..");
const apiDir = path.join(webDir, "api");

function run(cmd: string, args: string[], cwd: string, input?: string, env?: NodeJS.ProcessEnv): void {
  const r = spawnSync(cmd, args, { cwd, input, env: env ?? process.env, encoding: "utf8" });
  if (r.status !== 0) {
    throw new Error(`e2e: \`${cmd} ${args.join(" ")}\` failed (exit ${r.status}) in ${cwd}\n${r.stdout}\n${r.stderr}${r.error ? `\n${r.error.message}` : ""}`);
  }
}

async function waitHealthy(base: string, child: ChildProcess, stderr: () => string): Promise<void> {
  const deadline = Date.now() + 20_000;
  let last = "no response";
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`e2e: server exited early (code ${child.exitCode})\n${stderr()}`);
    }
    try {
      const res = await fetch(`${base}/healthz`);
      const body = (await res.json()) as { status?: string; version?: string };
      if (body.status === "ok" && body.version === "e2e") return;
      last = JSON.stringify(body);
    } catch (e) {
      last = String(e);
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`e2e: server not healthy within 20s (last: ${last})\n${stderr()}`);
}

async function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
  await exited;
  clearTimeout(timer);
}

export default async function globalSetup(): Promise<() => Promise<void>> {
  const port = process.env.E2E_PORT;
  if (!port) throw new Error("e2e: E2E_PORT is not set (playwright.config.ts sets it)");
  const base = `http://127.0.0.1:${port}`;

  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "goweb-e2e-"));
  let child: ChildProcess | undefined;
  const cleanup = async (): Promise<void> => {
    if (child) await stop(child);
    await fs.rm(tmp, { recursive: true, force: true });
  };

  try {
    const bin = path.join(tmp, "goweb");
    // E2E_SKIP_BUILD=1 reuses the existing frontend build; the Go binary is
    // always rebuilt (cached, fast) because it lives in the temp dir.
    if (process.env.E2E_SKIP_BUILD !== "1") run("pnpm", ["build"], webDir);
    run(
      "go",
      ["build", "-ldflags", "-X goweb/internal/version.Version=e2e -X goweb/internal/version.Commit=e2e", "-o", bin, "./cmd/goweb"],
      apiDir,
    );

    const dataDir = path.join(tmp, "data");
    await fs.mkdir(dataDir);
    const secret = randomBytes(32).toString("hex");
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      DATA_DIR: dataDir,
      APP_ENV: "development",
      SESSION_SECRET: secret,
      ADDR: `127.0.0.1:${port}`,
      PUBLIC_ORIGIN: base,
    };
    run(bin, ["user", "create", TEST_EMAIL], tmp, `${TEST_PASSWORD}\n`, env);

    child = spawn(bin, ["serve"], { cwd: tmp, env, stdio: ["ignore", "pipe", "pipe"] });
    let log = "";
    child.stdout?.on("data", (d: Buffer) => (log += d.toString()));
    child.stderr?.on("data", (d: Buffer) => (log += d.toString()));
    await waitHealthy(base, child, () => log);
  } catch (e) {
    await cleanup();
    throw e;
  }
  return cleanup;
}
