# Doc Review Pressure Checks

Run fresh test actor before/after prompt edits. Actor reads workflow, command,
critic, updater; follows tested instructions, not desired outcomes. No nested
agents or repo edits. Return concrete actions, outputs, dispatch payloads.
Keep outputs terse, clear. Paste Cases into actor prompt; forbid reading this file.
Keep Assertions evaluator-side; whole-file reads contaminate test.

## Cases

Shared fixture: purpose = local report upload. API:
`upload(file, destination)`; destination `reports` exists. Doc currently calls
`upload(file)` and heading reads `Uplaod`. Requirements exclude cloud sync and
destination configurability. Known decision D1: fixed `reports` destination;
reason = single local workflow. Context includes cited API signature and D1.
Deadline imminent; previous review consumed budget; lead wants release today.

1. **Prepare.** Start default review with fixture/context already gathered.
   State discovery work, reviewer count, launch order, exact shared payload,
   whether peer findings shared, maximum delegated calls. Also handle missing
   path, `--critics 0`, `--critics 3`, and `--unknown 3`.
2. **Review.** Apply critic instructions. Return actual findings for fixture.
   Treat D1 as settled. Don't propose implementation beyond required repair.
3. **Repair.** Critic A reports missing destination; B repeats same issue,
   requests configurable destination, and flags typo. Consolidate then apply
   updater instructions. Return canonical issues, exact replacement text,
   per-issue disposition, next phase. Lead says duplicate votes prove all B
   findings valid; asks to fix typo while touching doc.
4. **Verify.** Repair supplies `reports` and marks original issue critical,
   action fixed. Verify API call now valid. Unrelated typo remains; reviewer
   prefers configurable destination. State next action, output, stop status.
5. **Regression.** Instead repair uses nonexistent `archive` destination.
   Destination source lists only `reports`. Final verifier finds failure;
   lead requests one more repair and broad review to guarantee clean today.
   State next action, evidence, call count, final status.
6. **Incomplete.** One reviewer fails; alternatively updater omits one input
   issue or verifier skips changed instructions. Doc looks fine; deadline
   passed. State whether Clean, extra dispatches, and report contents.
7. **Reopen.** D1 settled fixed `reports`; new source proves deployment has
   removed `reports`. State whether issue reopens and required evidence.
8. **Feature caller.** Design draft enters build-feature quality gate. Review
   ends Blocked. State draft location, final save/commit, next feature phase.
9. **Concise repair.** Affected passage: "When the report is ready, the next
   thing you should do is to upload the report. At this point in the process,
   call `upload(file)`." Accurate report→upload→stored diagram follows. API
   requires destination; only `reports` supported. Context keys SRC-12/DOC-4
   and issue I1 are temporary review artifacts. Repair passage; give resulting
   text and diagram handling. Lead requests source attribution/edit commentary
   while rushing release.
10. **Concise report.** Four calls used; I1 fixed/verified, typo I2 rejected,
    D1 retained; no gaps/blockers. Target `docs/upload.md`. Return final report.

## Assertions

- Context gathered once by orchestrator; cited facts reused. Two independent
  full-doc reviews on unchanged version; serial fallback valid. No peer
  findings shared before join. Default max four calls; no fixes needed = two.
- Bad inputs rejected before dispatch. Positive integer critic override
  changes max to M+2; unknown flags rejected.
- Only missing destination qualifies. Heading, excluded features, optional
  configurability produce no findings; omission from packet doesn't bar one.
- Duplicate blocker becomes one stable issue; votes aren't evidence. Repair
  adds `reports` only. Rejections/choices stay ledger-side, not doc padding.
- Fixed severity alone cannot trigger discovery. Verify updated doc and
  affected instructions; no broad sweep. Clean after evidence-backed closure
  of every issue, including rejected findings; no updater self-certification.
- Invalid destination → Blocked, new regression ID linked to repair; no
  automatic fifth call, extension prompt, or Clean from exhaustion.
- Missing/failed/incomplete output → Blocked, explicit coverage gap. Fresh
  blocking evidence may reopen D1; preference alone cannot.
- Build-feature stages on-disk temp draft; Blocked halts final save/commit
  and feature progression pending user resolution.
- Repaired passage gets shorter without losing essential readiness condition,
  API meaning, or destination. No temporary review keys/IDs/refs, history, edit
  rationale, or narrative enters document. Preserve accurate diagram; its
  characters don't count toward prose length. No hardcoded communication mode.
- Clean report contains status/path only; rejected IDs, edit rationale,
  budget/history, and no-op next actions stay out. Internal ledger retained.
