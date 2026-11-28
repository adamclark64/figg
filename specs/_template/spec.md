# <Title: what changes, in a few words>

Issue: <#N (closes), #N (part of), or none>

<!--
Copy this folder to specs/<id>-<slug>/ (see specs/README.md) and fill in
every section. This file is public: keep it to the product and the code.
Delete these comments when done.

The Issue line decides what the final PR does to the issue the work comes
from. "(closes)" when shipping this spec settles the whole issue: the
final PR says "Closes #N" and GitHub closes it on merge. "(part of)" when
the spec is one slice and the issue should stay open. "none" when there is
no issue.
-->

## Problem

<!-- What is wrong or missing today, and who notices. One or two short
paragraphs. Link the issue it comes from, if any. -->

## Intended outcome

<!-- What is true once this ships, from the user's side. Describe the
result, not the implementation. -->

## Constraints

<!-- Anything the design must respect. AGENTS.md hard rules always apply
(audio never leaves the Mac, no secrets on disk or in logs, no sampling
params, settings in FiggConfig, logic behind protocols). Add the ones
specific to this spec: platforms, performance, compatibility, files that
must not change. -->

- AGENTS.md hard rules apply.

## Acceptance criteria

<!-- A checklist. Each item is testable, and says how: a Swift Testing
test, a CI check, or a manual step in docs/manual-test-checklist.md.
The final PR copies this list and ticks each item. -->

- [ ] <criterion> (proved by: <test or check>)

## Out of scope

<!-- What this spec deliberately does not do, so the design and build
stages do not drift into it. -->

-
