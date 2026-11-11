// Serverless bug-report relay for figg (Vercel Node function, zero dependencies).
//
// The figg app POSTs a JSON report here; this function holds the GitHub token
// server-side and files an issue in the figg repo. The app NEVER holds a GitHub
// token (a token embedded in a .app is extractable, and figg's hard rule 2
// forbids secrets on disk).
//
// Deploy this folder (root directory: relay) as its own Vercel project.
//
// Required env (set on the Vercel project, never committed):
//   GITHUB_TOKEN              fine-grained PAT: Contents R/W + Issues R/W on the repo
// Optional env:
//   GITHUB_BUG_REPORT_REPO    target "owner/repo" (default adamclark64/figg)
//   GITHUB_BUG_REPORT_BRANCH  branch for screenshot commits (default bug-report-assets;
//                             an orphan branch, so screenshots never trigger builds)

const GITHUB_API = "https://api.github.com";
const MAX_IMAGES = 3; // Vercel body limit ~4.5MB; base64 inflates ~33%.
const MAX_IMAGE_BYTES = 3 * 1024 * 1024; // 3MB per screenshot (decoded)
const MAX_EXTRA_ENTRIES = 20;

// Report types double as GitHub labels: `bug` | `enhancement` | `question`
// (all GitHub default labels).
const ALLOWED_TYPES = ["bug", "enhancement", "question"];
const TITLE_PREFIX = {
  bug: "[Figg bug]",
  enhancement: "[Feature request]",
  question: "[Question]",
};
const SOURCE_LABEL = "macos";

function repo() {
  return process.env.GITHUB_BUG_REPORT_REPO || "adamclark64/figg";
}

function assetsBranch() {
  return process.env.GITHUB_BUG_REPORT_BRANCH || "bug-report-assets";
}

function ghHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "Content-Type": "application/json",
  };
}

function str(v, max) {
  return String(v ?? "").slice(0, max);
}

// Best-effort per-instance rate limit: 10 reports per 10 minutes per IP.
// Serverless instances are ephemeral, so this only blunts bursts; it is not
// a security boundary (the endpoint is public and unauthenticated).
const hits = new Map();
function rateLimited(ip, limit = 10, windowMs = 10 * 60_000) {
  const now = Date.now();
  const arr = (hits.get(ip) ?? []).filter((t) => now - t < windowMs);
  arr.push(now);
  hits.set(ip, arr);
  if (hits.size > 5000) hits.clear();
  return arr.length > limit;
}

// Strip a `data:image/jpeg;base64,` prefix if the client sent a full data URL,
// returning { mime, b64 }. Falls back to the passed-in mime otherwise.
function splitDataUrl(raw, fallbackMime) {
  const m = /^data:([^;]+);base64,(.*)$/s.exec(raw || "");
  if (m) return { mime: m[1], b64: m[2] };
  return { mime: fallbackMime || "", b64: raw || "" };
}

// Upload one screenshot to the assets branch via the Contents API and return
// the markdown to embed. Returns a note line (not a throw) on failure so a
// flaky image never blocks the issue from being filed.
async function uploadScreenshot(token, shot, index) {
  const safeName = String(shot.name || `screenshot-${index + 1}.jpg`)
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(-60);
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const path = `bug-reports/${stamp}-${index + 1}-${safeName}`;

  try {
    const res = await fetch(
      `${GITHUB_API}/repos/${repo()}/contents/${encodeURIComponent(path).replace(
        /%2F/g,
        "/",
      )}`,
      {
        method: "PUT",
        headers: ghHeaders(token),
        body: JSON.stringify({
          message: `chore(bug-report): screenshot ${path}`,
          content: shot.b64,
          branch: assetsBranch(),
        }),
        signal: AbortSignal.timeout(20_000),
      },
    );
    if (!res.ok) {
      console.error("bug-report screenshot upload failed", res.status);
      return `- _screenshot ${index + 1} (\`${safeName}\`) could not be uploaded (${res.status})_`;
    }
    const data = await res.json();
    // Link to the stable blob page rather than inlining the image: the raw
    // download_url can be a short-lived tokenized URL.
    const blob = data?.content?.html_url;
    if (blob) return `- [screenshot ${index + 1}: \`${safeName}\`](${blob})`;
    const raw = data?.content?.download_url;
    if (raw) return `- [screenshot ${index + 1}: \`${safeName}\`](${raw})`;
    return `- _screenshot ${index + 1} uploaded but no URL returned_`;
  } catch (err) {
    console.error("bug-report screenshot upload error", err);
    return `- _screenshot ${index + 1} (\`${safeName}\`) upload errored_`;
  }
}

// Vercel's Node runtime usually parses JSON bodies onto req.body, but read the
// raw stream if it didn't.
async function readJson(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") {
    try {
      return JSON.parse(req.body);
    } catch {
      return null;
    }
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return null;
  }
}

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }

  const ip =
    String(req.headers["x-forwarded-for"] ?? "").split(",")[0].trim() ||
    req.socket?.remoteAddress ||
    "unknown";
  if (rateLimited(ip)) {
    res.status(429).json({ error: "rate_limited" });
    return;
  }

  const token = process.env.GITHUB_TOKEN;
  if (!token) {
    res.status(503).json({ error: "bug_reporting_unconfigured" });
    return;
  }

  const parsed = await readJson(req);
  if (!parsed) {
    res.status(400).json({ error: "invalid_body" });
    return;
  }

  const description = str(parsed.description, 10_000).trim();
  if (!description) {
    res.status(400).json({ error: "missing_description" });
    return;
  }

  // Whitelist-guard `type`: an unknown value must NOT silently become `bug`,
  // but an empty field defaults to bug.
  const rawType = str(parsed.type ?? "bug", 32);
  const type = ALLOWED_TYPES.includes(rawType) ? rawType : "bug";

  const email = str(parsed.email, 200);
  const appVersion = str(parsed.appVersion, 100);
  // figg sends { macOS, hardware, engine, build }; keep it generic and capped.
  const extra =
    parsed.extra && typeof parsed.extra === "object" && !Array.isArray(parsed.extra)
      ? parsed.extra
      : null;

  // Normalize screenshots to { name, mime, b64 } and validate.
  const rawShots = Array.isArray(parsed.screenshots) ? parsed.screenshots : [];
  if (rawShots.length > MAX_IMAGES) {
    res.status(400).json({ error: "too_many_screenshots" });
    return;
  }
  const shots = [];
  for (const s of rawShots) {
    const { mime, b64 } = splitDataUrl(s?.base64, s?.mime);
    if (!b64) continue;
    if (!String(mime).startsWith("image/")) {
      res.status(400).json({ error: "screenshots_must_be_images" });
      return;
    }
    // base64 decodes to ~3/4 of its length.
    if (Math.floor((b64.length * 3) / 4) > MAX_IMAGE_BYTES) {
      res.status(413).json({ error: "screenshot_too_large" });
      return;
    }
    shots.push({ name: s?.name, mime, b64 });
  }

  const embeds = [];
  for (let i = 0; i < shots.length; i++) {
    embeds.push(await uploadScreenshot(token, shots[i], i));
  }

  const title = `${TITLE_PREFIX[type]} ${description.split("\n")[0].slice(0, 72)}`;
  // Context is the app version plus the flat `extra` object (macOS,
  // hardware, engine, build).
  const contextLines = [
    `- **Type:** ${type}`,
    appVersion ? `- **App version:** ${appVersion}` : null,
    ...(extra
      ? Object.entries(extra)
          .slice(0, MAX_EXTRA_ENTRIES)
          .map(
            ([k, v]) =>
              `- **${str(k, 40)}:** ${str(typeof v === "object" ? JSON.stringify(v) : v, 200)}`,
          )
      : []),
    email ? `- **Reporter:** ${email}` : null,
  ]
    .filter(Boolean)
    .join("\n");

  const body = [
    "_Reported from figg's in-app bug reporter._",
    "",
    description,
    "",
    "---",
    "### Context",
    contextLines || "_none captured_",
    embeds.length ? "\n### Screenshots\n" + embeds.join("\n") : "",
  ].join("\n");

  let issueRes;
  try {
    issueRes = await fetch(`${GITHUB_API}/repos/${repo()}/issues`, {
      method: "POST",
      headers: ghHeaders(token),
      body: JSON.stringify({
        title,
        body,
        labels: [type, "user-report", SOURCE_LABEL],
      }),
      signal: AbortSignal.timeout(20_000),
    });
  } catch (err) {
    console.error("bug-report issue create error", err);
    res.status(502).json({ error: "github_unreachable" });
    return;
  }

  if (!issueRes.ok) {
    const detail = await issueRes.text();
    console.error("bug-report issue create failed", issueRes.status, detail);
    res.status(502).json({ error: "issue_create_failed" });
    return;
  }

  const issue = await issueRes.json();
  res.status(200).json({ number: issue?.number, url: issue?.html_url });
};
