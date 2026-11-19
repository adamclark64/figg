"""Writes pulls.json: a REST-shaped list of PRs that covers every stage.

Kept as a script so the fixture stays readable; run it after changing a
case, then refresh expected.md (see README.md).
"""
import json
import os

REPO = "example/app"


def pr(n, ref, base, title, state="open", merged=False, labels=(), updated="2026-11-18T10:00:00Z", repo=REPO):
    return {
        "number": n,
        "title": title,
        "state": state,
        "merged_at": updated if merged else None,
        "closed_at": updated if state == "closed" else None,
        "updated_at": updated,
        "html_url": "https://github.com/%s/pull/%d" % (REPO, n),
        "head": {"ref": ref, "repo": {"full_name": repo}},
        "base": {"ref": base},
        "labels": [{"name": l} for l in labels],
    }


pulls = [
    # 0001 shipped: spec, two items, final merged.
    pr(10, "factory/0001-export-markdown", "main", "feat(export): export a meeting to Markdown", "closed", True, ["factory:planned"], "2026-11-01T09:00:00Z"),
    pr(11, "factory/0001-p1", "factory/0001", "feat(export): add the formatter", "closed", True, ["factory:building"], "2026-11-02T09:00:00Z"),
    pr(12, "factory/0001-p2", "factory/0001", "feat(export): add the menu item", "closed", True, ["factory:building"], "2026-11-03T09:00:00Z"),
    pr(13, "factory/0001", "main", "feat(export): export a meeting to Markdown", "closed", True, ["factory:final"], "2026-11-04T09:00:00Z"),
    # 0002 building: one item merged, one open with failed CI, one open fine.
    pr(20, "factory/0002-tag-filter", "main", "feat(notes): filter notes by tag", "closed", True, ["factory:planned"], "2026-11-10T09:00:00Z"),
    pr(21, "factory/0002-p1", "factory/0002", "feat(notes): tag index", "closed", True, ["factory:building"], "2026-11-11T09:00:00Z"),
    pr(22, "factory/0002-p2", "factory/0002", "feat(notes): tag filter view", "open", False, ["factory:building", "factory:ci-failed"], "2026-11-18T12:00:00Z"),
    pr(23, "factory/0002-p3", "factory/0002", "test(notes): tag filter tests", "open", False, ["factory:building"], "2026-11-17T12:00:00Z"),
    # 0003 planned: waiting for approval 1.
    pr(30, "factory/0003-dark-icons", "main", "feat(ui): dark mode icons", "open", False, ["factory:spec", "factory:planned"], "2026-11-16T08:00:00Z"),
    # 0004 spec with a hostile title: mention, markup, pipe, cross-repo ref.
    pr(40, "factory/0004-odd-title", "main", "@someone <img src=x onerror=alert(1)> [click](https://bad.example) | other/repo#5 `code` **bold**\nsecond line", "open", False, ["factory:spec"], "2026-11-15T08:00:00Z"),
    # 0005 needs a human after three failed fixes on its only item.
    pr(50, "factory/0005-retry-upload", "main", "fix(export): retry uploads", "closed", True, ["factory:planned"], "2026-11-05T08:00:00Z"),
    pr(51, "factory/0005-p1", "factory/0005", "fix(export): backoff", "open", False, ["factory:building", "factory:ci-failed", "factory:needs-human"], "2026-11-14T08:00:00Z"),
    # 0006 dropped: spec PR closed without merging.
    pr(60, "factory/0006-abandoned", "main", "feat: something we did not want", "closed", False, ["factory:spec"], "2026-11-06T08:00:00Z"),
    # 0007 approved, build has not opened an item yet: still alive.
    pr(70, "factory/0007-short-titles", "main", "feat(notes): shorter default titles", "closed", True, ["factory:planned"], "2026-11-18T15:00:00Z"),
    # 0008 final PR open, labels missing: structure says Final.
    pr(80, "factory/0008-sort-order", "main", "feat(ui): remember sort order", "closed", True, [], "2026-11-12T08:00:00Z"),
    pr(81, "factory/0008-p1", "factory/0008", "feat(ui): store sort order", "closed", True, [], "2026-11-13T08:00:00Z"),
    pr(82, "factory/0008", "main", "feat(ui): remember sort order", "open", False, [], "2026-11-18T09:00:00Z"),
    # Ignored: a fork PR on a factory-looking branch, and an ordinary PR.
    pr(90, "factory/0009-from-fork", "main", "feat: fork tries to get on the board", repo="stranger/app"),
    pr(91, "fix/typo", "main", "docs: fix a typo"),
]

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "pulls.json"), "w", encoding="utf-8") as f:
    json.dump(pulls, f, indent=2)
    f.write("\n")
