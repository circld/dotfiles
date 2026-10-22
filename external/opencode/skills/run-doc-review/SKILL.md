---
name: run-doc-review
description: Use when coordinating on-disk document review for blocking
  correctness gaps. Not standalone critique, editing, or prose polish.
---

# Run Doc Review

Use for design/plan correctness review. Requires readable document/sources,
writable target, delegated critique/repair. Not general copyediting.
Orchestrator gathers context, joins results, reports; delegates judgment/edits.

## Contract

- Inputs: on-disk path; critic count M, positive integer, default 2.
- Budget: M discovery reviews + at most one repair + one verification.
  Default maximum 4 delegated calls. No retry, restart, extension prompt, or
  second repair. Further work requires new user request.
- Blocker = evidenced defect preventing stated task or causing materially
  wrong implementation/result. Require location, concrete failure, cited
  evidence, smallest correction. No style, optional features, speculative risks.
- Failed/incomplete stage, material evidence gap, unexpected document change,
  or unresolved requirement conflict → Blocked. Never infer Clean from silence.

## Shared Context

Gather once, in orchestrator; reuse existing research. No discovery agent.
Packet: purpose/non-goals, cited facts/source map, unknowns, settled decisions
with reasons. No proposed findings or approval verdict. Record reviewed version.
Keep packet and issue ledger in review context; don't pad document with review
history. Pass both forward; reopen settled point only with new blocking evidence.

Reviewers reuse facts, independently read full document, inspect sources for
uncertainty/contradictions and blocker evidence. No repeated broad exploration;
packet omissions cannot restrict findings. Missing facts remain unknown.

## Document Text

Use concise plain language. Maximize clarity; minimize characters while
preserving required technical meaning. Keep essential technical facts only.
In repaired passages omit filler, repetition, history, narrative, edit rationale,
and review-generated IDs/lookup keys/temporary refs. Preserve real technical
identifiers and required citations. Diagrams don't count toward text length.
No unrelated copyediting or cryptic shorthand.

## Phases

1. **Review.** Dispatch M fresh read-only reviewers, mode `discovery`, identical
   target/version, packet, prior ledger, blocker gate. Parallel preferred;
   serial allowed. Share no current peer findings. No edits before all finish.
2. **Join.** Require M complete results. Deduplicate same failure/root cause;
   preserve distinct blockers. Assign stable IDs I1, I2…; retain evidence and
   prior IDs. Duplicate votes aren't proof. No findings + no material coverage
   gaps → Clean; skip repair/verification.
3. **Repair.** Dispatch one writer with target, packet, canonical ledger.
   Independently adjudicate every ID; minimally fix valid blockers only.
   Reject invalid/nonblocking findings with evidence/reason, no document edit.
   Unjustified choice/conflict → unresolved. Return per-ID status
   `fixed|rejected|unresolved`, essential evidence/decision reason, delta,
   affected instructions. No narrative or repeated edit rationale.
   Require every input ID accounted for; incomplete output → Blocked.
4. **Verify.** Dispatch fresh read-only reviewer, mode `verify`, latest document,
   original version/change delta, packet, full ledger, repair summary. Even
   all-rejected/no-edit repairs need verification. Check every disposition
   against evidence, including rejections; inspect changed text and affected
   instructions for introduced/exposed blockers. No unrelated discovery sweep.
   Return per-ID `closed|rejected|unresolved` with evidence; new regressions get
   stable IDs linked to causing repair. Require complete issue/change coverage.
   Any unresolved/new blocker or material gap → Blocked; otherwise Clean. Stop.

## Report

Return `Clean|Blocked` + path. Blocked: remaining failure/coverage gap, essential
source evidence, smallest next action. Omit history, edit rationale, rejected
findings, review-generated IDs/refs, budget narration. Keep ledger internal for
follow-up. Clean covers checked scope; never claim exhaustive certification.
