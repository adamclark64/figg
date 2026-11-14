// POST /v1/bug-report: files a figg bug report as a GitHub issue.
//
// figg's Report a Bug posts here by default (BugReportRelay.hostedEndpoint
// in the app), at https://figg-api.vercel.app/v1/bug-report. Installed copies
// keep that URL, so never move or rename it; add /v2 beside it instead.
// Without it every copy falls back to opening the issue in the browser.
//
// This function holds the GitHub token server-side and files the issue. The
// app NEVER holds a GitHub token (a token embedded in a .app is extractable,
// and figg's hard rule 2 forbids secrets on disk). To run your own, deploy
// api/ and set feedback.bug_report_endpoint in config.yaml to its URL.
//
// Required env (set on the Vercel project, never committed):
//   GITHUB_TOKEN              fine-grained PAT: Contents R/W + Issues R/W on the repo
// Optional env:
//   GITHUB_BUG_REPORT_REPO    target "owner/repo" (default adamclark64/figg)
//   GITHUB_BUG_REPORT_BRANCH  branch for screenshot commits (default
//                             bug-report-assets; an orphan branch, so
//                             screenshots never trigger builds). It must exist
//                             before the first screenshot is sent.
//
// Error codes in the JSON replies are part of the contract: the app maps
// them to messages in BugReportErrorMessage (app/Sources/FiggFeedback).

const GITHUB_API = "https://api.github.com";
export const MAX_IMAGES = 3; // Vercel body limit ~4.5 MB; base64 inflates ~33%.
const MAX_IMAGE_BYTES = 3 * 1024 * 1024; // 3 MB per screenshot (decoded)
const MAX_EXTRA_ENTRIES = 20;

// Report types double as GitHub labels (all GitHub default labels).
const ALLOWED_TYPES = ["bug", "enhancement", "question"] as const;
type ReportType = (typeof ALLOWED_TYPES)[number];
const TITLE_PREFIX: Record<ReportType, string> = {
  bug: "[Figg bug]",
  enhancement: "[Feature request]",
  question: "[Question]",
};
const SOURCE_LABEL = "macos";

interface Shot {
  name?: unknown;
  mime: string;
  b64: string;
}

function repo(): string {
  return process.env.GITHUB_BUG_REPORT_REPO || "adamclark64/figg";
}

function assetsBranch(): string {
  return process.env.GITHUB_BUG_REPORT_BRANCH || "bug-report-assets";
}

function ghHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "Content-Type": "application/json",
  };
}

function str(v: unknown, max: number): string {
  return String(v ?? "").slice(0, max);
}

function json(status: number, body: unknown): Response {
  return Response.json(body, { status });
}

// Best-effort per-instance rate limit: 10 reports per 10 minutes per IP.
// Serverless instances are ephemeral, so this only blunts bursts; it is not
// a security boundary (the endpoint is public and unauthenticated).
const hits = new Map<string, number[]>();
export function rateLimited(ip: string, limit = 10, windowMs = 10 * 60_000): boolean {
  const now = Date.now();
  const arr = (hits.get(ip) ?? []).filter((t) => now - t < windowMs);
  arr.push(now);
  hits.set(ip, arr);
  if (hits.size > 5000) hits.clear();
  return arr.length > limit;
}

/** Clears the rate limiter; for tests. */
export function resetRateLimit(): void {
  hits.clear();
}

// Strip a `data:image/jpeg;base64,` prefix if the client sent a full data
// URL. Falls back to the passed-in mime otherwise.
function splitDataUrl(raw: unknown, fallbackMime: unknown): { mime: string; b64: string } {
  const m = /^data:([^;]+);base64,(.*)$/s.exec(String(raw ?? ""));
  if (m) return { mime: m[1], b64: m[2] };
  return { mime: String(fallbackMime ?? ""), b64: String(raw ?? "") };
}

// Upload one screenshot to the assets branch via the Contents API and return
// the markdown to embed. Returns a note line (not a throw) on failure so a
// flaky image never blocks the issue from being filed.
async function uploadScreenshot(token: string, shot: Shot, index: number): Promise<string> {
  const safeName = String(shot.name || `screenshot-${index + 1}.jpg`)
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(-60);
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const path = `bug-reports/${stamp}-${index + 1}-${safeName}`;

  try {
    const res = await fetch(
      `${GITHUB_API}/repos/${repo()}/contents/${encodeURIComponent(path).replace(/%2F/g, "/")}`,
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
    const data = (await res.json()) as { content?: { html_url?: string; download_url?: string } };
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

export async function POST(request: Request): Promise<Response> {
  const ip = (request.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  if (rateLimited(ip)) return json(429, { error: "rate_limited" });

  const token = process.env.GITHUB_TOKEN;
  if (!token) return json(503, { error: "bug_reporting_unconfigured" });

  let parsed: Record<string, unknown>;
  try {
    const body: unknown = await request.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("not an object");
    parsed = body as Record<string, unknown>;
  } catch {
    return json(400, { error: "invalid_body" });
  }

  const description = str(parsed.description, 10_000).trim();
  if (!description) return json(400, { error: "missing_description" });

  // Unknown or missing `type` falls back to bug.
  const rawType = str(parsed.type ?? "bug", 32);
  const type: ReportType = (ALLOWED_TYPES as readonly string[]).includes(rawType)
    ? (rawType as ReportType)
    : "bug";

  const email = str(parsed.email, 200);
  const appVersion = str(parsed.appVersion, 100);
  // figg sends { macOS, hardware, engine, build }; keep it capped.
  const extra =
    parsed.extra && typeof parsed.extra === "object" && !Array.isArray(parsed.extra)
      ? (parsed.extra as Record<string, unknown>)
      : null;

  // Normalize screenshots to { name, mime, b64 } and validate.
  const rawShots = Array.isArray(parsed.screenshots) ? parsed.screenshots : [];
  if (rawShots.length > MAX_IMAGES) return json(400, { error: "too_many_screenshots" });
  const shots: Shot[] = [];
  for (const s of rawShots as Array<Record<string, unknown> | null>) {
    const { mime, b64 } = splitDataUrl(s?.base64, s?.mime);
    if (!b64) continue;
    if (!mime.startsWith("image/")) return json(400, { error: "screenshots_must_be_images" });
    // base64 decodes to ~3/4 of its length.
    if (Math.floor((b64.length * 3) / 4) > MAX_IMAGE_BYTES) {
      return json(413, { error: "screenshot_too_large" });
    }
    shots.push({ name: s?.name, mime, b64 });
  }

  const embeds: string[] = [];
  for (let i = 0; i < shots.length; i++) embeds.push(await uploadScreenshot(token, shots[i], i));

  const title = `${TITLE_PREFIX[type]} ${description.split("\n")[0].slice(0, 72)}`;
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

  let issueRes: Response;
  try {
    issueRes = await fetch(`${GITHUB_API}/repos/${repo()}/issues`, {
      method: "POST",
      headers: ghHeaders(token),
      body: JSON.stringify({ title, body, labels: [type, "user-report", SOURCE_LABEL] }),
      signal: AbortSignal.timeout(20_000),
    });
  } catch (err) {
    console.error("bug-report issue create error", err);
    return json(502, { error: "github_unreachable" });
  }

  if (!issueRes.ok) {
    // Status only: the body can echo request details.
    console.error("bug-report issue create failed", issueRes.status);
    return json(502, { error: "issue_create_failed" });
  }

  const issue = (await issueRes.json()) as { number?: number; html_url?: string };
  return json(200, { number: issue?.number, url: issue?.html_url });
}
