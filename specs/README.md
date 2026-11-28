# Specs

Work for the factory (issue 89) starts here as a written spec. The spec is
the source of truth: the design, the plan and the code are derived from it,
and re-running the pipeline against an edited spec is cheap.

## Everything here is public

This repository is public, and so is every branch the moment it is pushed,
before any review. Specs, designs, plans, PR text and comments must stay
about the product and the code:

- No employer, client or workplace names, and no internal policies,
  vendors, hosts, account IDs or profile names as reasons for a choice.
  Give the product reason instead ("audio never leaves the Mac").
- No secrets, tokens or personal data, even as examples.
- No meeting content: audio, transcripts, notes, titles or calendar data.

## Layout

One folder per spec, numbered in order:

```
specs/
  _template/spec.md     copy this to start a spec
  0001-export-markdown/
    spec.md             written by a person (or the spec stage), reviewed by you
    design.md           written by the design stage
    plan.md             written by the design stage
```

- **Id:** four digits, the next unused number (`0001`, `0002`, ...). Never
  reuse a number, even for a dropped spec.
- **Slug:** a few lowercase words joined by hyphens, naming the change.
- **Branch:** `factory/<id>-<slug>` for the spec PR, `factory/<id>` for the
  integration branch the build stage creates.

## Writing a spec

Copy `_template/spec.md` and fill in the `Issue:` line and each section:
problem, intended outcome, constraints, acceptance criteria, out of scope.
Keep it short. The `Issue:` line is how the work closes its issue:
`#N (closes)` makes the final PR say `Closes #N`, so merging it closes the
issue; `#N (part of)` links the issue and leaves it open. The Spec PR only
says `Refs #N`, since merging it builds nothing.
Each acceptance criterion must be testable and name what proves it,
because figg only builds on macOS and agents rely on CI to check their work.

## design.md

How the change will work: the types and files involved, the alternatives
considered and why they lost, failure modes, and how each AGENTS.md hard
rule is respected. The design stage revises it after an adversarial review.

## plan.md

The design split into atomic items, each small enough for one PR. Every
item has:

```markdown
### P1. <what it does>

- Files: app/Sources/FiggExport/MarkdownExport.swift, app/Tests/...
- Depends on: none (or P2, P3)
- Proved by: <the Swift Testing test or check that shows it works>
```

Items with no dependency between them can be built in parallel.
