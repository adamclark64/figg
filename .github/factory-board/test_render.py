"""Tests for render.py. Run: python3 -m unittest discover -s .github/factory-board

The golden test compares the board for fixtures/pulls.json with
fixtures/expected.md. After a deliberate change to the board, refresh it:
  python3 .github/factory-board/fixtures/make_pulls.py
  python3 .github/factory-board/render.py --repo example/app \
    .github/factory-board/fixtures/pulls.json > .github/factory-board/fixtures/expected.md
and read the diff before committing it.
"""
import json
import os
import unittest

import render

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "example/app"


def pr(n, ref, base="main", title="t", state="open", merged=False, labels=(), repo=REPO):
    return {
        "number": n,
        "title": title,
        "state": state,
        "merged_at": "2026-11-01T00:00:00Z" if merged else None,
        "updated_at": "2026-11-01T00:00:00Z",
        "head": {"ref": ref, "repo": {"full_name": repo}},
        "base": {"ref": base},
        "labels": [{"name": l} for l in labels],
    }


def stage_of(*pulls):
    specs = render.group(list(pulls), REPO)
    (spec,) = specs.values()
    return spec.stage()


class Golden(unittest.TestCase):
    def test_fixture_board(self):
        with open(os.path.join(HERE, "fixtures", "pulls.json"), encoding="utf-8") as f:
            pulls = json.load(f)
        with open(os.path.join(HERE, "fixtures", "expected.md"), encoding="utf-8") as f:
            expected = f.read()
        self.assertEqual(render.render(pulls, REPO), expected)

    def test_empty(self):
        out = render.render([], REPO)
        self.assertIn("Nothing in flight", out)
        self.assertTrue(out.startswith(render.TITLE_LINE))


class SafeText(unittest.TestCase):
    def test_breaks_mentions(self):
        self.assertNotIn("@someone", render.safe_text("hi @someone"))

    def test_breaks_cross_repo_refs(self):
        out = render.safe_text("see other/repo#5")
        self.assertNotIn("#5", out.replace("\\", ""))

    def test_no_html_or_links(self):
        out = render.safe_text('<script>x</script> [a](https://evil.example) ![i](u)')
        self.assertNotIn("<", out)
        self.assertNotIn("](", out)

    def test_no_table_break_or_newline(self):
        out = render.safe_text("a | b\nc\r\x00d")
        self.assertNotIn("\n", out)
        self.assertNotRegex(out, r"(?<!\\)\|")

    def test_length_cap(self):
        self.assertLessEqual(len(render.safe_text("x" * 500)), render.TITLE_MAX)

    def test_empty(self):
        self.assertEqual(render.safe_text("  "), "(untitled)")


class Classify(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(render.classify(pr(1, "factory/0001-slug"), REPO), ("0001", "spec", None))
        self.assertEqual(render.classify(pr(2, "factory/0001-p3", "factory/0001"), REPO), ("0001", "item", 3))
        self.assertEqual(render.classify(pr(3, "factory/0001"), REPO), ("0001", "final", None))

    def test_ignored(self):
        self.assertIsNone(render.classify(pr(1, "factory/0001-slug", repo="stranger/app"), REPO))
        self.assertIsNone(render.classify(pr(2, "feature/x"), REPO))
        self.assertIsNone(render.classify(pr(3, "factory/0001", base="factory/0001-x"), REPO))
        self.assertIsNone(render.classify(pr(4, "factory/1-slug"), REPO))


class Stage(unittest.TestCase):
    def test_spec(self):
        self.assertEqual(stage_of(pr(1, "factory/0001-s", labels=["factory:spec"])), render.SPEC)

    def test_planned_label(self):
        self.assertEqual(stage_of(pr(1, "factory/0001-s", labels=["factory:spec", "factory:planned"])), render.PLANNED)

    def test_merged_spec_without_items_is_building(self):
        self.assertEqual(stage_of(pr(1, "factory/0001-s", state="closed", merged=True)), render.BUILDING)

    def test_label_on_closed_pr_is_ignored(self):
        # A merged spec PR keeps factory:planned; the open item decides.
        self.assertEqual(
            stage_of(
                pr(1, "factory/0001-s", state="closed", merged=True, labels=["factory:planned"]),
                pr(2, "factory/0001-p1", "factory/0001", labels=["factory:building"]),
            ),
            render.BUILDING,
        )

    def test_open_final_without_label(self):
        self.assertEqual(
            stage_of(pr(1, "factory/0001-s", state="closed", merged=True), pr(2, "factory/0001")),
            render.FINAL,
        )

    def test_shipped(self):
        self.assertEqual(
            stage_of(pr(1, "factory/0001-s", state="closed", merged=True), pr(2, "factory/0001", state="closed", merged=True)),
            render.SHIPPED,
        )

    def test_dropped(self):
        self.assertEqual(stage_of(pr(1, "factory/0001-s", state="closed")), render.DROPPED)
        self.assertEqual(
            stage_of(pr(1, "factory/0001-s", state="closed", merged=True), pr(2, "factory/0001", state="closed")),
            render.DROPPED,
        )

    def test_reopened_spec_uses_open_pr(self):
        specs = render.group(
            [pr(1, "factory/0001-s", title="old", state="closed"), pr(5, "factory/0001-s", title="new")], REPO
        )
        self.assertEqual(specs["0001"].title(), "new")
        self.assertEqual(specs["0001"].stage(), render.SPEC)


if __name__ == "__main__":
    unittest.main()
