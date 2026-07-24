---
name: run-doc-review
description: Use when orchestrating an iterative critique/update review
  loop — dispatching critique and update rounds against an on-disk
  document, checking the stop condition, handling the round-cap extend
  prompt, and issuing the final report. Not for acting as the critic or
  updater yourself.
---

# Run Doc Review

## Overview

An iterative quality loop for an on-disk document (design, plan, etc.). Each
round dispatches one or more read-only critique passes against the document,
then a single read-write update pass that triages and fixes what it judges
valid and worthwhile. The loop stops when a round comes back with no
outstanding critical findings, or when the user declines to extend past the
round cap.

**This skill does not evaluate or edit the document itself** — it dispatches
subagents that do, and makes the stop/continue decision based on their
structured output.

## Inputs

- **Document path.** Required. The file on disk to review.
- **Round cap (N).** Optional, default 3.
- **Critic count (M).** Optional, default 1. M > 1 dispatches M identical
  fresh-context critique passes per round for statistical sampling of a
  nondeterministic evaluator — not differentiated personas.

## The Loop

Repeat starting at round 1:

1. **Dispatch critique.** Dispatch M subagent instance(s) capable of
   read-only document critique against the document path. Each instance is
   independent and fresh-context — do not share state between them.
2. **Union findings.** Combine all findings from all M instances into one
   list, unmodified. Do not deduplicate, merge, or filter — pass every
   finding through as-is, even if multiple instances raised the same point
   in different words.
3. **Dispatch update.** Dispatch a single subagent instance capable of
   read-write document updates, given the document path and the full union
   of findings. It triages each finding for validity and criticality, fixes
   what it judges valid and worthwhile directly in the file, and returns a
   structured per-finding verdict (verdict, final criticality, action taken,
   rationale) — one entry per finding it received.
4. **Check stop condition.** Inspect the returned verdict list for any entry
   with final criticality = critical.
   - **None found:** Status is Clean. Stop the loop, go to Final Report.
   - **At least one found, and round < cap:** Start the next round (step 1).
   - **At least one found, and round == cap:** Go to Cap Checkpoint.

## Cap Checkpoint

When the round cap is reached with critical findings still outstanding, ask
the user: extend by 3 rounds and continue, or stop here.

- If the user chooses to extend: raise the cap by 3 and continue the loop
  from the next round.
- If the user declines: Status is User-stopped. Stop the loop, go to Final
  Report.

This checkpoint repeats every time a (possibly extended) cap is reached —
there is no limit on how many times the user may extend.

## Accumulating Minor Findings

Across every round, collect any verdict-list entries with final criticality
= minor. Do not deduplicate across rounds — accumulate the raw list for the
final report.

## Final Report

Report to the user:
- **Status:** Clean or User-stopped
- **Rounds completed:** the final round count reached
- **Minor findings:** the accumulated list from all rounds (may be empty)
- **Document:** the path, for the user's own final review

There is no certification banner and no gating on whether the document may
be saved further — the document has already been edited in place by
doc-updater across the rounds; this report is a summary for the human, not a
gate.

## What This Skill Does Not Do

- It does not deduplicate findings within a round or across rounds. The
  document's own accumulated notes (written by the update pass) are what
  prevent relitigating settled points — not orchestrator-side comparison.
- It does not detect cyclical/stuck loops via any comparison across rounds.
  The round cap (with its extend checkpoint) is the sole backstop for a
  loop that never reaches zero critical findings.
- It does not pause mid-round for human approval of individual fixes. The
  update pass operates autonomously; the only human checkpoint is the cap
  extend/stop decision.
