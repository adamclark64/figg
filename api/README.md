# figg API

figg's HTTP API, at `https://figg-api.vercel.app`. Each file under `api/v1/`
is one Vercel function (Node runtime, TypeScript, no runtime dependencies),
written against the Web `Request` and `Response`, so moving it to a framework
such as Hono later needs no change to the URLs.

| Route | File | Used by |
|---|---|---|
| `POST /v1/bug-report` | `api/v1/bug-report.ts` | Report a Bug in the app (`BugReportRelay.hostedEndpoint`) |

Installed copies of figg keep the URLs they were built with, so a route
never moves or changes shape. A breaking change is a new `/v2/` route beside
the old one. `vercel.json` maps `/v1/...` onto Vercel's `/api/v1/...`.

## Develop

```bash
cd api && npm install
```

```bash
npm test --prefix api
```

```bash
npm run typecheck --prefix api
```

The tests fake GitHub, so they need no token and make no network calls.

## Deploy

A Vercel project named `figg-api` with root directory `api`, connected to
this repository. It only builds when something under `api/` changed.

Environment variables (Production), never committed:

- `GITHUB_TOKEN`: a fine-grained token on this repository only, with
  Contents read/write (screenshots) and Issues read/write.
- `GITHUB_BUG_REPORT_REPO` (optional): `owner/repo`, default
  `adamclark64/figg`.
- `GITHUB_BUG_REPORT_BRANCH` (optional): where screenshots are committed,
  default `bug-report-assets`. Make it an orphan branch before the first
  report, so screenshots never sit in the code's history:

```bash
git switch --orphan bug-report-assets && git commit --allow-empty -m "chore: start bug report assets" && git push -u public bug-report-assets && git switch -
```

Check a deploy with an empty report, which is refused before GitHub is
touched:

```bash
curl -s -X POST https://figg-api.vercel.app/v1/bug-report -H 'content-type: application/json' -d '{}'
```

It should print `{"error":"missing_description"}`, or
`{"error":"bug_reporting_unconfigured"}` if `GITHUB_TOKEN` is not set.
