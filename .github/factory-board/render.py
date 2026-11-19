#!/usr/bin/env python3
"""Render the Factory board issue body from a list of pull requests.

Input is the JSON the REST API returns for GET /repos/{repo}/pulls (a list,
already flattened across pages). Output is Markdown on stdout. Standard
library only, so the workflow needs no install step and the tests run
anywhere with Python 3.9 or later.

The branch names follow the factory contract (issue 89):
  factory/NNNN-<slug>   spec PR, adds specs/NNNN-<slug>/
  factory/NNNN-pN       one plan item, PR into factory/NNNN
  factory/NNNN          integration branch, final PR into main

PR titles and branch names come from whoever opened the PR, so they are
treated as hostile text: escaped for Markdown and HTML, cut to a fixed
length, with mentions and cross-repository references broken. Everything
else on the board (numbers, links, labels) is built here.
"""

import argparse
import json
import re
import sys
from urllib.parse import quote

LABEL_SPEC = "factory:spec"
LABEL_PLANNED = "factory:planned"
LABEL_BUILDING = "factory:building"
LABEL_CI_FAILED = "factory:ci-failed"
LABEL_NEEDS_HUMAN = "factory:needs-human"
LABEL_FINAL = "factory:final"

# Stages in pipeline order. The board shows the furthest one a spec has
# reached, from its labels or from its branches, whichever is further.
SPEC, PLANNED, BUILDING, FINAL, SHIPPED = range(5)
DROPPED = -1
STAGE_NAMES = {
    SPEC: "Spec: design running",
    PLANNED: "Planned: approval 1",
    BUILDING: "Building",
    FINAL: "Final: approval 2",
    SHIPPED: "Shipped",
    DROPPED: "Dropped",
}
LABEL_STAGES = {
    LABEL_SPEC: SPEC,
    LABEL_PLANNED: PLANNED,
    LABEL_BUILDING: BUILDING,
    LABEL_FINAL: FINAL,
}

ITEM_RE = re.compile(r"^factory/(\d{4})-p(\d+)$")
INTEGRATION_RE = re.compile(r"^factory/(\d{4})$")
SPEC_RE = re.compile(r"^factory/(\d{4})-(.+)$")

TITLE_MAX = 80
DONE_SHOWN = 10
ZWSP = "​"

TITLE_LINE = "# Factory board"


def safe_text(text, limit=TITLE_MAX):
    """Make untrusted text inert in a Markdown table cell.

    Newlines and control characters become spaces, HTML is entity-escaped,
    Markdown punctuation is backslash-escaped (so no link, image, emphasis,
    code span or table cell break survives), and a zero-width space after
    every "@" and after the "#" of an owner/name#N reference stops pings
    and backlinks. Plain "#N" still links within this repository, which is
    harmless and the same as GitHub does in any title.
    """
    text = "".join(" " if (ord(c) < 32 or ord(c) == 127) else c for c in str(text))
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"([\\`*_\[\]{}()!|~#+\-.:])", r"\\\1", text)
    text = text.replace("@", "@" + ZWSP)
    # After escaping, "owner/name#12" reads "owner/name\#12"; GitHub still
    # links that, so break it after the "#".
    text = re.sub(r"(\\#)(?=\d)", "\\1" + ZWSP, text)
    return text or "(untitled)"


def labels_of(pr):
    return {l.get("name", "") for l in pr.get("labels") or []}


def is_open(pr):
    return pr.get("state") == "open"


def is_merged(pr):
    return bool(pr.get("merged_at"))


def classify(pr, repo):
    """Return (spec id, kind, item number) or None if not a factory PR.

    kind is "spec", "item" or "final". PRs from forks are ignored: only
    people with push access can create factory/ branches in the repository
    itself, so a fork cannot put rows on the board.
    """
    head = pr.get("head") or {}
    head_repo = (head.get("repo") or {}).get("full_name")
    if head_repo != repo:
        return None
    ref = head.get("ref") or ""
    base = (pr.get("base") or {}).get("ref") or ""
    m = ITEM_RE.match(ref)
    if m:
        return m.group(1), "item", int(m.group(2))
    m = INTEGRATION_RE.match(ref)
    if m:
        return (m.group(1), "final", None) if base == "main" else None
    m = SPEC_RE.match(ref)
    if m:
        return m.group(1), "spec", None
    return None


class Spec:
    def __init__(self, spec_id):
        self.id = spec_id
        self.spec_prs = []
        self.items = []
        self.finals = []

    def all_prs(self):
        return self.spec_prs + self.items + self.finals

    def spec_pr(self):
        """The spec PR the board describes: the open one, else the merged
        one, else the newest. A re-opened spec gets a new PR on the same
        id, so the open one wins."""
        for pick in (is_open, is_merged, lambda pr: True):
            found = [pr for pr in self.spec_prs if pick(pr)]
            if found:
                return max(found, key=lambda pr: pr.get("number", 0))
        return None

    def final_pr(self):
        for pick in (is_merged, is_open, lambda pr: True):
            found = [pr for pr in self.finals if pick(pr)]
            if found:
                return max(found, key=lambda pr: pr.get("number", 0))
        return None

    def stage(self):
        final = self.final_pr()
        if final and is_merged(final):
            return SHIPPED
        open_prs = [pr for pr in self.all_prs() if is_open(pr)]
        spec = self.spec_pr()
        if not open_prs:
            # Between approval 1 and the first item PR nothing is open, and
            # the spec is still alive. It is dropped when its spec PR or its
            # final PR was closed without merging and nothing reopened.
            if not (spec and is_merged(spec)) or (final and not is_open(final)):
                return DROPPED
        structural = SPEC
        if spec and is_open(spec) and LABEL_PLANNED in labels_of(spec):
            structural = PLANNED
        if self.items or (spec and is_merged(spec)):
            structural = BUILDING
        if final and is_open(final):
            structural = FINAL
        from_labels = [
            LABEL_STAGES[name]
            for pr in open_prs
            for name in labels_of(pr)
            if name in LABEL_STAGES
        ]
        return max([structural] + from_labels)

    def needs_human(self):
        return [pr for pr in self.all_prs() if is_open(pr) and LABEL_NEEDS_HUMAN in labels_of(pr)]

    def ci_failed(self):
        return [pr for pr in self.all_prs() if is_open(pr) and LABEL_CI_FAILED in labels_of(pr)]

    def title(self):
        pr = self.spec_pr() or self.final_pr() or (self.items[0] if self.items else None)
        return safe_text(pr.get("title", "")) if pr else "(untitled)"

    def slug(self):
        pr = self.spec_pr()
        if not pr:
            return None
        m = SPEC_RE.match(pr["head"]["ref"])
        return m.group(2) if m else None

    def last_change(self):
        stamps = [pr.get("updated_at") or "" for pr in self.all_prs()]
        return max(stamps) if stamps else ""


def group(pulls, repo):
    specs = {}
    for pr in pulls:
        found = classify(pr, repo)
        if not found:
            continue
        spec_id, kind, _ = found
        spec = specs.setdefault(spec_id, Spec(spec_id))
        {"spec": spec.spec_prs, "item": spec.items, "final": spec.finals}[kind].append(pr)
    return specs


def pr_refs(prs):
    return ", ".join("#%d" % pr["number"] for pr in sorted(prs, key=lambda pr: pr["number"]))


def day(stamp):
    return stamp[:10] if stamp else ""


def links(spec, repo):
    parts = []
    pr = spec.spec_pr()
    if pr:
        parts.append("spec #%d" % pr["number"])
    slug = spec.slug()
    if slug and pr and is_merged(pr):
        path = "specs/%s-%s/spec.md" % (spec.id, slug)
        parts.append("[spec.md](https://github.com/%s/blob/main/%s)" % (repo, quote(path)))
    if spec.items or (pr and is_merged(pr)):
        parts.append(
            "[branch](https://github.com/%s/tree/%s)" % (repo, quote("factory/" + spec.id))
        )
    final = spec.final_pr()
    if final:
        parts.append("final #%d" % final["number"])
    return " · ".join(parts)


def items_cell(spec):
    open_items = [pr for pr in spec.items if is_open(pr)]
    merged = sum(1 for pr in spec.items if is_merged(pr))
    if not spec.items:
        return "none"
    cell = pr_refs(open_items) if open_items else "none open"
    return "%s (%d merged)" % (cell, merged)


def active_table(specs, repo):
    rows = [
        "| Spec | Title | Stage | Open item PRs | CI failed | Needs human | Links | Last change |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for spec in specs:
        rows.append(
            "| %s | %s | %s | %s | %s | %s | %s | %s |"
            % (
                spec.id,
                spec.title(),
                STAGE_NAMES[spec.stage()],
                items_cell(spec),
                pr_refs(spec.ci_failed()) or "",
                pr_refs(spec.needs_human()) or "",
                links(spec, repo),
                day(spec.last_change()),
            )
        )
    return rows


def done_table(specs, repo):
    rows = ["| Spec | Title | Result | Links | Closed |", "|---|---|---|---|---|"]
    for spec in specs:
        rows.append(
            "| %s | %s | %s | %s | %s |"
            % (spec.id, spec.title(), STAGE_NAMES[spec.stage()], links(spec, repo), day(spec.last_change()))
        )
    return rows


def render(pulls, repo):
    specs = group(pulls, repo)
    ordered = sorted(specs.values(), key=lambda s: s.id)
    active = [s for s in ordered if s.stage() not in (SHIPPED, DROPPED)]
    done = sorted(
        (s for s in ordered if s.stage() in (SHIPPED, DROPPED)),
        key=lambda s: s.last_change(),
        reverse=True,
    )[:DONE_SHOWN]
    stuck = [s for s in active if s.needs_human()]
    failing = [s for s in active if s.ci_failed()]

    out = [TITLE_LINE, ""]
    out.append(
        "%d in flight · %d need a human · %d with failing CI · %d shipped or dropped"
        % (len(active), len(stuck), len(failing), len([s for s in ordered if s not in active]))
    )
    out.append("")

    if stuck:
        out += ["## Needs a human", ""]
        for s in stuck:
            out.append("- **%s** %s: %s" % (s.id, s.title(), pr_refs(s.needs_human())))
        out.append("")

    out += ["## In flight", ""]
    if active:
        out += active_table(active, repo)
    else:
        out.append("Nothing in flight. Open a spec PR on a `factory/NNNN-<slug>` branch to start one.")
    out.append("")

    if done:
        out += [
            "<details><summary>Shipped or dropped (latest %d)</summary>" % DONE_SHOWN,
            "",
        ]
        out += done_table(done, repo)
        out += ["", "</details>", ""]

    out += [
        "---",
        "",
        "<sub>Rewritten by the `factory-board` workflow on every factory PR event, "
        "after each CI run and daily. Edits to this body are overwritten. "
        "How it works: `.github/factory-board/README.md`.</sub>",
    ]
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("pulls", help="JSON file: list of pull requests from the REST API")
    args = parser.parse_args(argv)
    with open(args.pulls, encoding="utf-8") as f:
        pulls = json.load(f)
    if not isinstance(pulls, list):
        sys.exit("expected a JSON list of pull requests")
    sys.stdout.write(render(pulls, args.repo))


if __name__ == "__main__":
    main()
