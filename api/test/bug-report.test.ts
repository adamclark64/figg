// Tests for POST /v1/bug-report with GitHub faked out: no network, no token.
// Run with `npm test` in api/.
import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { POST, resetRateLimit } from "../api/v1/bug-report.ts";

interface Call {
  url: string;
  method: string;
  body: Record<string, unknown>;
}

let calls: Call[] = [];
let respond: (call: Call) => Response;
const realFetch = globalThis.fetch;

beforeEach(() => {
  calls = [];
  respond = (call) =>
    call.url.includes("/contents/")
      ? Response.json({ content: { html_url: "https://github.com/o/r/blob/x/shot.jpg" } }, { status: 201 })
      : Response.json({ number: 42, html_url: "https://github.com/o/r/issues/42" }, { status: 201 });
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const call = {
      url: String(input),
      method: init?.method ?? "GET",
      body: JSON.parse(String(init?.body ?? "{}")),
    };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
  process.env.GITHUB_TOKEN = "test-token";
  process.env.GITHUB_BUG_REPORT_REPO = "o/r";
  resetRateLimit();
});

afterEach(() => {
  globalThis.fetch = realFetch;
  delete process.env.GITHUB_TOKEN;
  delete process.env.GITHUB_BUG_REPORT_REPO;
});

function report(body: unknown, ip = "1.2.3.4"): Request {
  return new Request("https://figg-api.vercel.app/v1/bug-report", {
    method: "POST",
    headers: { "content-type": "application/json", "x-forwarded-for": ip },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const sample = {
  type: "bug",
  description: "The sidebar is empty\nafter restart",
  email: "me@example.com",
  appVersion: "0.9.0",
  extra: { macOS: "macOS 26.1", engine: "parakeet" },
};

test("files an issue with labels and context", async () => {
  const res = await POST(report(sample));
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { number: 42, url: "https://github.com/o/r/issues/42" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.github.com/repos/o/r/issues");
  assert.equal(calls[0].body.title, "[Figg bug] The sidebar is empty");
  assert.deepEqual(calls[0].body.labels, ["bug", "user-report", "macos"]);
  const body = String(calls[0].body.body);
  assert.match(body, /- \*\*App version:\*\* 0\.9\.0/);
  assert.match(body, /- \*\*engine:\*\* parakeet/);
  assert.match(body, /- \*\*Reporter:\*\* me@example\.com/);
});

test("uploads screenshots to the assets branch and links them", async () => {
  const res = await POST(
    report({ ...sample, screenshots: [{ name: "a b.jpg", base64: "data:image/jpeg;base64,AAAA" }] }),
  );
  assert.equal(res.status, 200);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].method, "PUT");
  assert.match(calls[0].url, /\/repos\/o\/r\/contents\/bug-reports\/.*-1-a_b\.jpg$/);
  assert.equal(calls[0].body.branch, "bug-report-assets");
  assert.equal(calls[0].body.content, "AAAA");
  assert.match(String(calls[1].body.body), /\[screenshot 1: `a_b\.jpg`\]\(https:\/\/github\.com\/o\/r\/blob\/x\/shot\.jpg\)/);
});

test("a failed screenshot upload still files the issue", async () => {
  respond = (call) =>
    call.url.includes("/contents/")
      ? new Response("no", { status: 404 })
      : Response.json({ number: 7, html_url: "https://github.com/o/r/issues/7" }, { status: 201 });
  const res = await POST(report({ ...sample, screenshots: [{ base64: "data:image/png;base64,AAAA" }] }));
  assert.equal(res.status, 200);
  assert.match(String(calls[1].body.body), /could not be uploaded \(404\)/);
});

test("unknown types become bugs, and enhancements are titled as requests", async () => {
  await POST(report({ ...sample, type: "nonsense" }));
  assert.deepEqual(calls[0].body.labels, ["bug", "user-report", "macos"]);
  await POST(report({ ...sample, type: "enhancement", description: "Dark mode" }));
  assert.equal(calls[1].body.title, "[Feature request] Dark mode");
});

// The app maps each code to a message (BugReportErrorMessage), and decides
// from the status whether to offer the browser instead.
const rejections: Array<[string, unknown, number, string]> = [
  ["no description", { ...sample, description: "  " }, 400, "missing_description"],
  ["not JSON", "{oops", 400, "invalid_body"],
  ["an array", [1, 2], 400, "invalid_body"],
  ["four screenshots", { ...sample, screenshots: [1, 2, 3, 4].map(() => ({ base64: "data:image/png;base64,AA" })) }, 400, "too_many_screenshots"],
  ["a non-image", { ...sample, screenshots: [{ base64: "data:text/plain;base64,AAAA" }] }, 400, "screenshots_must_be_images"],
  ["a huge screenshot", { ...sample, screenshots: [{ base64: "data:image/png;base64," + "A".repeat(4_200_000) }] }, 413, "screenshot_too_large"],
];
for (const [name, body, status, code] of rejections) {
  test(`rejects ${name} without calling GitHub`, async () => {
    const res = await POST(report(body));
    assert.equal(res.status, status);
    assert.deepEqual(await res.json(), { error: code });
    assert.equal(calls.length, 0);
  });
}

test("says so when no token is set", async () => {
  delete process.env.GITHUB_TOKEN;
  const res = await POST(report(sample));
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { error: "bug_reporting_unconfigured" });
});

test("a GitHub failure is a 502", async () => {
  respond = () => new Response("boom", { status: 500 });
  const res = await POST(report(sample));
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: "issue_create_failed" });
});

test("GitHub out of reach is a 502", async () => {
  globalThis.fetch = (async () => {
    throw new TypeError("fetch failed");
  }) as typeof fetch;
  const res = await POST(report(sample));
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: "github_unreachable" });
});

test("the eleventh report from one address in ten minutes is rate limited", async () => {
  for (let i = 0; i < 10; i++) assert.equal((await POST(report(sample, "9.9.9.9"))).status, 200);
  const res = await POST(report(sample, "9.9.9.9"));
  assert.equal(res.status, 429);
  assert.deepEqual(await res.json(), { error: "rate_limited" });
  assert.equal((await POST(report(sample, "8.8.8.8"))).status, 200);
});
