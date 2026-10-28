// After ship.sh uploads: make sure TestFlight can actually deliver the build.
//   1. the app record exists
//   2. an Internal TestFlight group with automatic distribution exists (created if missing)
//   3. (optional) TESTER_EMAIL is in that group
//   4. the uploaded build reaches processingState VALID
//
// Usage: bun asc-verify.mjs <bundle-id> <build-number>      (node works too)
// Credentials: API_KEY_ID / API_ISSUER_ID from the environment or ~/.appstoreconnect/env.
// Env: TESTER_EMAIL=you@example.com  add this App Store Connect user to the Internal group
//      WAIT_MINUTES=40               how long to wait for Apple's processing (default 40)
// Exit: 0 VALID, 1 failed/invalid, 2 setup problem (no app record, no credentials), 3 timed out.
import { createPrivateKey, sign } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";

const [bundleId, buildNumber] = process.argv.slice(2);
if (!bundleId || !buildNumber) {
  console.error("usage: asc-verify.mjs <bundle-id> <build-number>");
  process.exit(2);
}

const home = `${homedir()}/.appstoreconnect`;
const envFile = `${home}/env`;
if (existsSync(envFile)) {
  for (const line of readFileSync(envFile, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_]+)=(.*)$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}
let keyId = process.env.API_KEY_ID;
if (!keyId) {
  const keys = existsSync(`${home}/private_keys`)
    ? readdirSync(`${home}/private_keys`).filter((f) => /^AuthKey_.+\.p8$/.test(f))
    : [];
  if (keys.length === 1) keyId = keys[0].slice(8, -4);
}
const issuer = process.env.API_ISSUER_ID;
const keyPath = `${home}/private_keys/AuthKey_${keyId}.p8`;
if (!keyId || !issuer || !existsSync(keyPath)) {
  console.error("asc-verify: App Store Connect credentials missing (see ship.sh header).");
  process.exit(2);
}

const b64u = (b) => Buffer.from(b).toString("base64url");
function jwt() {
  const header = b64u(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const now = Math.floor(Date.now() / 1000);
  const body = b64u(JSON.stringify({ iss: issuer, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" }));
  const sig = sign("sha256", Buffer.from(`${header}.${body}`), {
    key: createPrivateKey(readFileSync(keyPath, "utf8")),
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${body}.${b64u(sig)}`;
}

async function asc(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    body: body ? JSON.stringify(body) : undefined,
    headers: { Authorization: `Bearer ${jwt()}`, "Content-Type": "application/json" },
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const detail = (json.errors ?? []).map((e) => e.detail ?? e.title).join("; ");
    throw new Error(`${method} ${path} -> ${res.status} ${detail}`);
  }
  return json;
}

const q = encodeURIComponent;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 1. app record
const apps = await asc("GET", `/v1/apps?filter[bundleId]=${q(bundleId)}`);
const app = apps.data?.[0];
if (!app) {
  console.error(`asc-verify: no App Store Connect app record for ${bundleId}.`);
  console.error("  Create it once: App Store Connect -> My Apps -> + -> New App (the API cannot).");
  process.exit(2);
}

// 2. Internal group with automatic distribution
const groups = await asc("GET", `/v1/apps/${app.id}/betaGroups?limit=50`);
let group = groups.data.find((g) => g.attributes.isInternalGroup);
if (!group) {
  const created = await asc("POST", "/v1/betaGroups", {
    data: {
      type: "betaGroups",
      attributes: { name: "Internal", isInternalGroup: true, hasAccessToAllBuilds: true },
      relationships: { app: { data: { type: "apps", id: app.id } } },
    },
  });
  group = created.data;
  console.log(`asc-verify: created Internal TestFlight group for ${bundleId}`);
} else if (!group.attributes.hasAccessToAllBuilds) {
  await asc("PATCH", `/v1/betaGroups/${group.id}`, {
    data: { type: "betaGroups", id: group.id, attributes: { hasAccessToAllBuilds: true } },
  });
  console.log("asc-verify: enabled automatic distribution on the Internal group");
}

// 3. tester
const email = process.env.TESTER_EMAIL;
if (email) {
  const testers = await asc("GET", `/v1/betaGroups/${group.id}/betaTesters?limit=200`);
  if (!testers.data.some((t) => t.attributes.email?.toLowerCase() === email.toLowerCase())) {
    try {
      await asc("POST", "/v1/betaTesters", {
        data: {
          type: "betaTesters",
          attributes: { email },
          relationships: { betaGroups: { data: [{ type: "betaGroups", id: group.id }] } },
        },
      });
      console.log(`asc-verify: added ${email} to the Internal group`);
    } catch (e) {
      console.error(`asc-verify: could not add ${email} (must be an App Store Connect user): ${e.message}`);
    }
  }
}

// 4. wait for processing
const deadline = Date.now() + Number(process.env.WAIT_MINUTES ?? 40) * 60_000;
let last = "";
while (Date.now() < deadline) {
  const builds = await asc(
    "GET",
    `/v1/builds?filter[app]=${app.id}&filter[version]=${q(buildNumber)}&sort=-uploadedDate&limit=1`,
  );
  const state = builds.data?.[0]?.attributes.processingState ?? "NOT_VISIBLE_YET";
  if (state !== last) console.log(`asc-verify: build ${buildNumber} is ${state}`);
  last = state;
  if (state === "VALID") {
    console.log(`asc-verify: build ${buildNumber} is VALID and available to the Internal group.`);
    process.exit(0);
  }
  if (state === "FAILED" || state === "INVALID") {
    console.error(`asc-verify: build ${buildNumber} ${state}. Check the email from App Store Connect for the reason.`);
    process.exit(1);
  }
  await sleep(30_000);
}
console.error(`asc-verify: build ${buildNumber} still ${last} after the wait; check TestFlight later.`);
process.exit(3);
