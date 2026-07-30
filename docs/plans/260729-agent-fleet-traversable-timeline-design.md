# agent-fleet: traversable timeline + interactive board — design

Status: validated design (brainstorm output, 2026-07-29). Not yet implemented.
Critique round 3 folded in (2026-07-29): four open checks remain — see Open
checks at the bottom.

## Features

1. **Traversable alert timeline** — one hotkey moves back through where you've been,
   another moves forward through unviewed alerts, each landing jumping to the
   corresponding opencode chat session.
2. **Interactive board** — keyboard navigation of the agent-fleet board,
   jump-to-session on keypress, and dismissal of "done" sessions that are no
   longer relevant.

Build order: **Phase 1 = refactor + traverse, Phase 2 = board.** Traverse first
validates the shared act seam both features depend on.

## User mental model

```
... viewed sessions (recency, oldest→newest) | current | oldest unviewed alert → ... → newest unviewed alert
```

Back = where you've been (MRU). Forward = redo of back-presses (LIFO) first;
once redo runs dry, pending alerts oldest-first (FIFO). Alt-y (existing
jump-to-most-urgent) remains the panic button; landing via any path makes that
session "current" while retaining remaining unviewed alerts.

## Architecture & data flow

```
sensor plugin (phase 1: 2 small adds)  model.mjs (extended)         consumers
───────────────────────────────        ──────────────────────       ─────────────────
<key>.json      + selectedSid(+ts) ─▶  rows[]       (unchanged) ─▶  render.sh (board)
<key>.viewed.json (sid→ts)        ─▶  actionable[] (unchanged) ─▶  jump.sh (Alt-y)
                                       timeline: viewed[] desc      traverse.sh (Alt-[/])
                                                pending[] FIFO asc
                                       instances[]: {key, cwd, selectedSid,
                                                selectedTs, sessions:[sid...]}
                                                — live v2 state files, ambiguous
                                                cwds INCLUDED (dead-entry source)
<key>.select (mailbox) ◀── written by scripts (jump/traverse/board); consumed by sensor poll
traverse-stack.json {v:1, current:{sid,ts}, back[], forward[]} ◀── written by act_land callers only
```

Invariants:

- Sensor is sole writer of `<key>.json` / `<key>.viewed.json` (unchanged).
- `traverse-stack.json` writers = the act_land callers (jump, traverse, board
  Enter); atomic tmp+rename, last-writer-wins (accepted: single human typist,
  worst case one lost breadcrumb — see Error handling).
- Sensor transitions are event-driven; two pollers exist and STAY: the
  sensor's 400ms `.select` mailbox poll (existing, sensor.js:397-400) and the
  board's fixed-interval render tick (existing; Phase 2's `read -t` doubles as
  it). No NEW pollers are added.
- Writer discipline is per file class, not one-writer-per-file: state/viewed →
  sensor only; stack → act_land callers; `.select` → any script produces,
  sensor alone consumes (single-slot mailbox — concurrent producers race, last
  rename wins; see Error handling); `.board-cache.json` → board.sh only (it
  runs the model); `.board-linemap.tsv` → render.sh only WRITES it; board.sh's
  EXIT trap DELETES it (with the cache) for stale-frame prevention —
  delete-on-exit is the sole carve-out, no content race. Every write is
  atomic tmp+rename; mailboxes are always deleted on consume.
- `$STATE_DIR` file coupling: model.mjs's `stateFiles()` glob (model.mjs:72)
  matches every `*.json` except `*.viewed.json`, so `traverse-stack.json` and
  `.board-cache.json` ARE re-read every tick and skipped only by the
  missing-`cwd` guard (model.mjs:97). Do not add a `cwd` key to either file.
  (The leading dot on `.board-cache.json` is cosmetic, not the exclusion
  mechanism — the missing-`cwd` guard is what excludes both files.)
  (`.select` mailboxes and the `.tsv` line-map don't match the glob.)

## Timeline semantics

**pending[]** = existing `actionable[]` (needs-attention rank 1 + done rank 0,
unsuppressed) **filtered to `sid != null`**, re-sorted `ts` ascending (FIFO;
rank ignored for traversal). Sid-less actionable rows (v1 legacy files) stay
Alt-y `focus-only` targets — a traverse landing needs a sid to select, so they
can never be pending[] entries.

**viewed[]** = dedup'd fallback history: sids with viewedTs, sorted viewedTs
descending. Fallback only — primary history is the stack file. WARNING:
viewedTs is ENTRY-PINNED (see Manual navigation tracking), so this order is
EVENT recency, not VISIT recency — landing on an old chat does NOT move it
toward the head. It is an approximate fallback for the lost-stack case only,
not a true MRU walk (the stack file is that). Source = model
`instances[]` joined against each instance's `<key>.viewed.json` (sid→ts) —
NOT `rows[]`: ambiguous-cwd sids have no row (their cwd collapses to one
`duplicate` row with sid:null, model.mjs:151-155, so no per-row viewedTs
exists for them) yet must stay in viewed[] — which is exactly why
`instances[]` includes ambiguous cwds. COLD AFTER RESTART: viewed.json is
per-KEY (`<cwd-hash>-<pid>.viewed.json`, sensor.js:246-248), so an opencode
restart orphans the old pid's file (the janitor upgrade path's orphan
class) and the new instance starts an empty one — the fallback holds
nothing exactly when the restart hole makes it most needed. Whether the
model merges pid-sibling viewed files per cwd (max ts) is decided with the
restart-hole open check.

**Dedup rules (lists only):**

1. *Pending-wins* — a sid with an unsuppressed alert is excluded from viewed[];
   it appears exactly once, in pending[].
2. *Live-prune* — viewed[] includes only sids present in a live instance's
   `sessions` list (`instances[]` flattens the v2 file's sessions map to a sid
   array, applying the same `__pane__` sentinel skip as the row builder,
   model.mjs:161; pane alive + pid alive + sid known). Read-side only; no
   writes, no caps, no compaction. This is NOT a no-op against `rows[]` —
   viewed[] is instances-derived (above), so an instance that dies or a sid
   that vanishes from its sessions map drops out here. Post-restart COLD
   state files make this prune wrong the same way — see RESTART HOLE in
   Traverse stack semantics.

**Guard:** forward-to-pending skips entries whose sid == current.sid. This
covers the async window before the sensor marks a just-landed alert viewed —
and the permanent case: a landing whose TUI select failed marks nothing (see
Uniform act layer), so the alert stays pending until a successful landing or a
`d` dismissal. The same ≠-current guard applies to the viewed[] back-fallback
(below), whose head is normally current itself.

## Traverse stack semantics

`$STATE_DIR/traverse-stack.json` = `{v:1, current:{sid,ts}, back:[sid...], forward:[sid...]}`.
`current.ts` = wall-clock time current was last set (landing or reconcile-
adopt), in epoch MILLISECONDS — the same unit as the sensor's `Date.now()`
`selectedTs` it is numerically compared against. Bash writers stamp
`$(($(date +%s) * 1000))` (the render.sh:39 convention); a seconds stamp
would silently invert the stale-P guard. Second-granularity multiplication
also TRUNCATES up to 999ms off a fresh stamp, so the effective stale-P
window is ~1–2s rather than a full 2s — still comfortably over the ~400ms
poll + round-trip it covers; accepted (precision loss, not unit loss; go
sub-second only if a slower persist path appears, per the Assumptions
override note). It exists for the stale-P reconcile
guard below. Entries are bare
sids: `key` is `<cwd-hash>-<pid>` and goes stale across opencode restarts, so
key/session/pane/tab are RE-RESOLVED from the model by sid at landing time
(row lookup in `rows[]`). A sid absent from every live instance's `sessions`
list (model `instances[]`, see diagram) is a dead entry — with one exception:
a sid present in an instance whose cwd is in the model's `ambiguous[]` is
UNLANDABLE but NOT dead (that cwd's rows collapse to one `duplicate` row,
model.mjs:151-155, so row lookup can't reach it). It stays in stacks/timeline,
pops skip it without pruning, until the duplicate instance closes.
RESTART HOLE (open — see Open checks; must close before implementation): an
opencode restart re-keys the instance to `<cwd-hash>-<NEWpid>.json`, where
`existing` is null, so the new file's `sessions` map seeds ONLY from
post-restart events (`sessions: { ...(existing?.sessions ?? {}), ... }`,
sensor.js:426-432). Untouched-but-alive chats are then absent from EVERY
live instance's `sessions` list → the dead-entry rule reads them as FALSE
dead entries, one Alt-[ prunes the whole back stack, and the at-end persist
(below) makes the loss durable. Bare sids survive a restart for
RE-RESOLUTION (above) but not for LIVENESS; the empty-`live[]` guard does
NOT cover this (every instance is alive — their sessions maps are merely
cold). Same root chills viewed[] (Dedup #2 live-prune) and the fallback's
landing row lookup. Leading close: the sensor seeds `sessions` on plugin
start from `client.session.list` (the client it already holds), making
liveness event-independent; alternative: prune only against warm instances.
Disposable:
corrupt/missing/`v != 1` → tolerant-read to empty (an unrecognized version is
treated exactly like corruption — never partially parsed); reconcile
re-establishes current
only (back/forward history is gone — viewed[] is the fallback).

**Stacks are breadcrumbs for navigation; lists are dedup'd destination sets.**
History is recency-unique everywhere (Alt-Tab/MRU model, not browser model —
the fleet is a small finite working set, so path-fidelity dupes are stutter,
not information). "Everywhere" = the STACKS; the viewed[] fallback is
event-ordered, not MRU (see above).

Rules:

- **Reconcile on every press** — runs FIRST, before the press's outcome is
  classified (so it applies even to presses that turn out
  noop/focus-only/warn). Scope: presses that consult the MODEL — Alt-y/jump,
  Alt-[/Alt-] traverse, board Enter. Board-internal keys (j/k/ESC/d/q) act on
  the cached frame only and NEVER reconcile — they run no model and cannot
  observe a passive departure. P = the most recent `selectedSid` across all
  live instances (max selection ts, from model `instances[]`). Instances whose
  state file predates the new envelope fields (no `selectedSid`/`selectedTs`)
  are EXCLUDED from the max — P is determinable only from instances carrying
  both; if none do, P is undeterminable and no flip occurs. If P
  determinable and ≠ current: record passive departure (`stacks.remove(P);
  back.push_mru(current); current = P`). current == null (fresh/corrupt
  stack) → adopt P as current with NO push (nothing to record). current ==
  null AND P undeterminable (first run after deploy: no stack file yet AND
  every state file predates the envelope fields) → current STAYS null and
  presses run with no current: neither direction pushes it (no null entry
  ever lands on a stack), the ≠-current guards pass vacuously, Alt-['s
  viewed[] scan starts at the head (the "current absent" rule), and the
  first select landing adopts current with NO push. **Stale-P
  guard (required):** when
  P's selection ts < `current.ts`, flip only if `current.ts` is OLDER than the
  persist window (~2s ≈ 400ms poll + TUI round-trip, generous). A fresh
  `current.ts` with an older P means the persist of a successful landing is
  still in flight — a stale read, not a manual switch — so the flip is
  blocked inside the window. Outside the window an older P is a real state
  (the failed-select case, see Uniform act layer: the TUI genuinely still
  shows P) and the flip MUST proceed — a strict `P.ts > current.ts` rule
  without the window would pin current to a failed landing forever. See
  Assumptions & Resolutions.
  This captures manual in-TUI chat switches at keypress time
  with zero polling. NOTE: pane focus CANNOT be the reconcile signal — the
  press runs in a freshly-focused transient zellij pane, so no focused
  opencode pane exists in model data at press time (and `is_focused` from
  `list-panes --all` is per-tab/per-session, not unique). `selectedSid` is the
  signal; see Manual navigation tracking.
- **back stack: MRU** — push removes any existing occurrence of that sid,
  appends at top. Dead sids are pruned only when popped past (read-side), so
  back[] can accumulate dead entries in a long-lived session that churns many
  chats without back-presses — accepted; a cap is a named upgrade path below.
- **forward stack: plain LIFO** — mirror of back-presses; carries round-trip
  fidelity; cleared on any new navigation (browser "click link clears redo").
  A reconcile-adopted current flip (manual in-TUI chat switch) IS new
  navigation for this purpose — it clears forward too: the manual switch is
  the in-TUI analog of clicking a link, and stale redo landing somewhere the
  user no longer means is worse than losing redo. See Assumptions &
  Resolutions.
- **Current-removal invariant** — `current.sid` never appears in back or
  forward. Enforcement is per-path (not one universal rule): reconcile /
  new navigation (Alt-y, pending[0]) do `stacks.remove(new)` then
  `back.push_mru(old)`; a back-press pops new off back (removal is inherent
  to the pop) and does `forward.push(old)`; a forward-press pops new off
  forward and does `back.push_mru(old)`. Sid occupies at most one of
  current/back/forward; no GC needed.
- **Alt-[ (back):** `forward.push(current); current = back.pop()`. Dead entry
  (sid in no live instance) → skip, pop next. Stack dry (= no LANDABLE entry
  remains — dead entries were pruned on pop, unlandable-ambiguous ones
  skipped but RETAINED, so a "dry" back[] can still hold entries) → fall back into
  viewed[] with a POSITION-based scan: locate current.sid in viewed[] and take
  the next LANDABLE entry toward the tail (older); current absent from
  viewed[] → start at the head. A head-first "first entry ≠ current.sid" scan
  is REJECTED: viewed[] order is event-pinned, so landing never re-orders it,
  and head-first ping-pongs between the two newest entries forever — deeper
  entries would be unreachable. The fallback applies the same landability
  filter as pops: dead
  entries can't appear (viewed[] is live-pruned, Dedup #2) but
  unlandable-ambiguous ones can — skip them without pruning, try the next
  entry.   `forward.push(current)` happens only once a landable target is found
  (under `set -euo pipefail` a failed jq row lookup must never abort
  post-mutation). current.sid itself dead/unlandable at press time is pushed
  onto forward[] anyway — forward-pops apply the same dead/unlandable skip
  filter, so the entry self-heals (pruned or skipped) without a special case.
  No landable entry → `traverse: at end`, and the stack file
  IS still written — with the popped-past dead entries pruned but no landing
  mutation (no `forward.push`, current unchanged). That persist is what makes
  read-side pruning real (otherwise dead entries linger forever and every
  press re-scans them) — and it is exactly the whole-stack-prune path the
  empty-`live[]` guard exists to preempt (see Error handling).
  The fallback removes the target sid from forward[] if present, and is NOT
  new navigation (forward is preserved — round-trip fidelity back to where
  you came from).
- **Alt-] (forward):** forward non-empty → pop (`back.push_mru(current)`).
  Dead/unlandable entry → skip (same filter as back-pops), pop next; a
  forward stack that exhausts this way counts as EMPTY. Empty → pending[0]
  (sid ≠ current), i.e. new navigation — never the viewed[] fallback (that
  would send a forward press backwards in time).
- **Alt-y / any jump:** a `select` landing is new navigation — push current,
  land top-ranked, clear forward. Alt-y's non-select outcomes (`focus-only`,
  `fallback-pane`, `warn-explicit-duplicate`, `noop`) have no sid: no
  NAVIGATION mutation (no push, no clear) — but reconcile still runs (every
  press, first), so a passive departure detected at this press still flips
  current and pushes the old current per the reconcile rule. "Unchanged"
  scopes to the navigation mutation only.

Acceptance traces (validated):

```
Scenario 1: nav Z · alt-] · alt-[ · alt-]
  start:   current=C  back=[..]      fwd=[]
  alt-]:   reconcile push C → next pending[0]=A, push Z
           current=A  back=[..,C,Z]  fwd=[]
  alt-[:   fwd.push(A), pop Z
           current=Z  back=[..,C]    fwd=[A]     → land Z ✓
  alt-]:   fwd pop A, push Z
           current=A  back=[..,C,Z]  fwd=[]      → land A ✓

Scenario 2: nav Z · alt-y · alt-[ · alt-] · alt-]
  alt-y:   reconcile push C → land top A0, push Z
           current=A0 back=[..,C,Z]  fwd=[]      → land A0 ✓
  alt-[:   fwd.push(A0), pop Z
           current=Z  back=[..,C]    fwd=[A0]    → land Z ✓
  alt-]:   fwd pop A0, push Z
           current=A0 back=[..,C,Z]  fwd=[]      → land A0 ✓
  alt-]:   fwd empty → pending[0] (A0 viewed; ≠ current) = A
           current=A  back=[..,C,Z,A0] fwd=[]    → land A ✓
```

Stale-revisit handling: X in back-stack revisited via alert → landing's
current-removal kills the ghost entry; via manual select → reconcile flushes it
one press later; fresh alert on X while X is mid-stack → entry stays (real past
visit), back-landing on X consumes the alert via the uniform act layer.

## Manual navigation tracking

viewedTs/cursor update only via: hotkey landings (`.select` mailbox → sensor
marks viewed) and **`tui.session.select`** events.

- `tui.session.select` — UNVERIFIED beyond presence: a strings hit on the
  installed opencode 1.18.4 binary proves the identifier exists, NOT that it
  reaches a plugin's `event` handler with `properties.sessionID`. Must be
  verified live before implementation (see Open checks). Sensor branch: resolve
  the event sid to its TOP-LEVEL session first (same `resolveTopLevelSession`
  contract as every other handler — a fork's raw sid keys no state entry, so
  merging viewed under it would never suppress anything), then
  `mergeViewed(viewedPath, topLevelSid, planViewedTsForSession(statePath,
  topLevelSid))` (entry-pinned ts, same as the mailbox path — a wall-clock
  `now` would mask a fresh event landing between the select and the write) +
  persist `selectedSid` + selection ts in the state file. Selection ts =
  wall-clock `Date.now()` at persist time — NOT entry-pinned like the viewed
  ts in the same call: reconcile takes the MAX selectedTs across instances,
  which only orders correctly as wall-clock. Two non-obvious
  requirements: (a) `buildV2StateRecord` (core.mjs:81-89) whitelists
  `{repo,cwd,session,pid,sessions}` — it gains `selectedSid`/`selectedTs` as
  top-level envelope fields (NOT inside the sessions map, so no interaction
  with the `__pane__` sentinel model.mjs:161 skips), the deepEqual shape
  lock in agent-fleet-sensor.test.mjs:181-191 is extended to match, AND —
  because the helper is a whitelist rebuild — every transition call site
  (`transitionForTopLevelSession`, sensor.js:426-432) threads
  `existing?.selectedSid`/`existing?.selectedTs` through the   rebuild, or the
  next `working`/`done`/`needs-attention` write erases them and reconcile
  reads no P at all; (b) every
  state-file write runs inside the per-key `enqueue()` chain
  (sensor.js:78-86, 397-400) — the new persists chain on exactly like
  transitionForTopLevelSession, or they race concurrent transition writes.
  ~5 lines on existing write paths, plus the envelope change. Covers
  manual chat-switching exactly, event-driven.
- UNVERIFIED: whether the sensor's OWN `/tui/select-session` post (mailbox
  consume) echoes   back as a `tui.session.select` event. If it does not,
  hotkey landings never update `selectedSid` via the event path and reconcile
  would read a stale P after every landing — recording bogus passive
  departures. Mitigation either way: the mailbox-consume action path (around
  `planSelect`, whose pure calc stays unchanged) also persists `selectedSid` +
  ts on a successful select — inside `enqueue()`, using the same new envelope
  fields. Belt and suspenders for event delivery; the async window it leaves
  (400ms poll + round-trip) is covered by the stale-P reconcile guard, not by
  this write. SAME whitelist-rebuild caveat as (a): `pollSelectMailbox`
  (sensor.js:268) today receives only `{selectPath, viewedPath, statePath}`
  — the factory-scope identity (`repo`, `directory`, `session`,
  `process.pid`) must be threaded into it and the record rebuilt via
  `buildV2StateRecord` with `existing.sessions` preserved. A naive short
  write would emit an envelope with `cwd: undefined`, fail the model's
  `!obj?.cwd` guard (model.mjs:97), and drop the whole instance from the
  board. ~10 lines with the threading, not 3.
- zellij pane focus IS queryable (`is_focused` in `list-panes --json`,
  verified live) but is unusable as the reconcile signal: it is
  per-tab/per-session (not unique across the fleet), and at press time the
  focused pane is the transient hotkey pane itself. Not polled either — pane
  focus ≠ user attention (background windows, multi-client).

**Accepted gap:** switching opencode PANES (or zellij tabs) without an in-TUI
chat switch emits no `tui.session.select`. Reconcile CANNOT observe it — P
derives from selection events, not location — so current stays stale until
the next genuine select/landing; "reconcile at the next press" does NOT fix
this case. Worse sub-case: if ANOTHER pane carries a fresher `selectedTs`,
a press inside this window flips current AWAY from the chat being viewed
and pushes it onto back[] — same self-healing shape as the failed-select
case (one Alt-[ back, corrected on the next select event), but the gap is
wider than benign staleness. Read-only scrolling never
marks viewed (pre-existing board suppression gap, same root). Named upgrade if
felt: a continuous zellij-focus poller is the deferred heavyweight fix.

## Uniform act layer

Every select landing — Alt-y, Alt-[, Alt-], stack- or pending-sourced — runs
one path: [caller: reconcile + compute the stack mutation + write the stack
file via act.sh helpers] → act_land: atomic-write `<key>.select {sessionID}`
→ aerospace workspace 1 → zellij tab/pane focus. act_land itself is
mailbox + focus only: the stack file is written by the CALLER
(jump/traverse/board Enter — see diagram + invariants), because the mutation
differs per caller (back-pop vs new-navigation vs none) and
`act_land key sid session pane tab` carries no stack state. Placement vs the
test seams is pinned: reconcile + mutation COMPUTATION is pure model-side
and happens before either seam; the stack file WRITE happens in the CALLER
immediately after computation — BEFORE act_land is invoked and, on the
`noop`/`warn-explicit-duplicate` paths, BEFORE their plain `exit 0`. This is
what makes the reconcile-on-every-press invariant real: a reconcile flip
detected on a press that turns out noop/warn/focus-only is persisted by that
same caller-side write — placing the write inside act_land's side-effect
window would silently drop it on every path that never reaches act_land.
The write goes through act.sh's `stack_write` helper, which checks
`AGENT_FLEET_DECIDE_ONLY` ITSELF and no-ops under it — jump.sh's existing
DECIDE_ONLY check lives INSIDE `goto_act` (jump.sh:21), so a caller-side
write cannot ride on it; the helper-internal guard keeps `DECIDE_ONLY`
side-effect-free (no mailbox, no stack write) without duplicating the check
at every call site. `DECIDE_ACT` does NOT suppress the write, so the act
test seam still exercises it. Sid-less outcomes that ALREADY focus today
(`focus-only`, `fallback-pane`) enter the SAME act_land with an empty sid:
no mailbox write, focus only — the reconcile flip, if any, was already
persisted by the caller's `stack_write` before act_land ran; only the
NAVIGATION mutation is absent. jump.sh's non-select focus
paths (jump.sh:73-84, 96-104, 114-122) call it exactly this way, so "no
special cases" means one entry point with a sid-presence branch, not zero
branches. `warn-explicit-duplicate` and `noop` do NOT enter act_land: today
they `exit 0` without any focus call (jump.sh:53-57, 60-63, 125), and
act_land unconditionally runs `aerospace workspace 1` — routing them through
would newly yank focus on a duplicate warning and on a total no-op. They
keep their plain exit — AFTER the caller-side `stack_write` has persisted
any reconcile flip. Viewed
marking is conditional by design: `planSelect` marks viewed only when the TUI
select succeeds (`markViewed: selectOk === true`). A failed select deletes the
mailbox, marks nothing, and the alert stays pending — truthful, since the user
never saw it (focus and the stack write still happen; the landing is recorded
either way). Failed-select + reconcile interaction (accepted): the failed
select persists no `selectedSid`, so once the persist window lapses the next
press's reconcile reads P = the chat the TUI actually still shows and flips
current back to it (the stale-P guard passes: `current.ts` is old), pushing
the failed target onto back[]. Truthful (the user never saw the target) and
self-healing (it sits one Alt-[ away for retry); a press INSIDE the window is
blocked by the guard and defers the flip by one press — accepted. The guard's
window is what stops the same flip from corrupting SUCCESSFUL landings inside
the persist window.

## Phase 1: refactor + traverse

- **`scripts/agent-fleet-act.sh`** (new; extracted from jump.sh):
  `act_land key sid session pane tab`; stack helpers (read/write
  traverse-stack.json atomic, push_mru, pop_live); the `.select` writer
  (moved from jump.sh's `_atomic_write_select`, jump.sh:13-18) with an
  optional `markOnly` field (board.sh sources it for `d`). jump.sh sources
  it — AND gains the reconcile step + stack-file mutation on select landings
  (Scenario 2's `alt-y: reconcile push C → land top A0` requires it): it
  reads `instances[]`/`selectedSid` from the same model call it already
  makes, records any passive departure, then lands. Non-select outcomes
  add no navigation mutation beyond that reconcile (no push, no clear).
  Existing hermetic tests must pass unchanged — but note they exercise only
  the decision + `.select` path (`AGENT_FLEET_DECIDE_ONLY`/`_DECIDE_SELECT`
  return before the aerospace/zellij tail). The extracted focus tail has no
  hermetic coverage; verification there is a manual smoke test (see Open
  checks), not the test suite.
- **`scripts/agent-fleet-traverse.sh`** (new, ~80 lines): `prev|next` arg
  (prev = Alt-[/back, next = Alt-]/forward);
  model → reconcile → branch (back-pop / forward-pop / pending[0]) → act_land.
  Gains `mkdir -p "$STATE_DIR"` (board.sh:9's pattern — jump.sh gets away
  without it only because the sensor creates the dir on first write;
  traverse's stack write must not depend on that under `set -euo pipefail`).
  Two test seams matching jump.sh's: `AGENT_FLEET_DECIDE_ONLY=1` emits
  `DECISION:kind=` and stops before ANY side effect (no mailbox, no stack
  write);   `AGENT_FLEET_DECIDE_ACT=1` performs mailbox + stack writes but skips
  the aerospace/zellij tail. Seam pinning: the extracted `act_land` tail
  checks BOTH names — `AGENT_FLEET_DECIDE_SELECT` (jump.sh:29's existing
  name; its harness depends on it) and `AGENT_FLEET_DECIDE_ACT`
  (traverse/board) — either suppresses the focus tail, so act-seam tests
  stay hermetic without renaming jump.sh's knob. Model spawn
  failure: `set -euo pipefail` aborts non-zero BEFORE any stack mutation (same
  shape as jump.sh) — PLUS an explicit empty-`live[]` guard: the model exits 0
  with valid-but-empty JSON when zellij fails (model.mjs:35-39), so traverse
  aborts non-zero when `live` is empty, before even reading the stack. Empty
  `live[]` also means "zero opencode panes running" (indistinguishable from
  zellij-down at the model layer), so the abort prints `traverse: no live
  agents (zellij down or none running)` and lingers ~1s BEFORE exiting
  non-zero — the transient pane's close_on_exit would otherwise swallow the
  message, violating fail-visible. No target → print
  `traverse: at end`, linger ~1s, exit 0 (the transient pane closes on exit;
  the linger keeps the dead-end message visible).
- **`scripts/agent-fleet-model.mjs`**: add timeline.viewed/pending (pure
  calc, no new env/side channel — viewed[] joins `instances[]` against the
  `<key>.viewed.json` files, already read per NON-ambiguous row via
  `viewedFor` (model.mjs:119); ambiguous-cwd keys never reach `baseRow`
  (model.mjs:152-154 `continue`s first), so the join ADDS one tolerant
  viewed.json read per ambiguous key — small, but not zero new reads;
  per-row
  `viewedTs` is NOT surfaced — `baseRow`'s local copy stays internal and the
  board's dismiss-confirm reads the existing per-row `suppressed` flag
  instead), and `instances[]` = live v2
  state files as `{key, cwd, selectedSid, selectedTs, sessions:[sid...]}`
  (ambiguous-cwd instances included — traverse's dead-entry check reads it).
  No new env overrides: timeline/instances derive from the state files tests
  already sandbox via `$AGENT_FLEET_STATE_DIR`. (No `is_focused`
  plumbing — reconcile uses `selectedSid`, not pane focus; see Traverse stack.)
- **`modules/packages/zellij.nix`**: `Alt [` / `Alt ]` binds beside Alt-y,
  same Run-transient-pane shape. CONFLICT: both keys are already bound in
  `locked clear-defaults=true` (`Alt ]` → `NextSwapLayout`, `Alt [` →
  `PreviousSwapLayout`, zellij.nix:279-284) — a duplicate attr is a Nix eval
  error. Resolution: traverse takes the keys; swap-layout moves to the shifted
  variants `Alt {` / `Alt }` (same mnemonic). See Assumptions & Resolutions.
- **sensor**: `tui.session.select` branch (above); `selectedSid` + ts also
  persisted in the mailbox-consume action path (above). `planSelect` (pure
  calc) unchanged this phase.

## Phase 2: interactive board

- **model.mjs**: rows already carry IDs (key/sid/cwd/session/pane/tabId);
  reused as action payload.
- **render.sh** → paint-only: reads cached row JSON (jq, as today — "no model
  call", not "no jq"), emits the display frame on stdout and the line-map
  (line# ↔ row ID) as a separate atomic-written file `.board-linemap.tsv`
  beside the cache (render.sh its sole writer; a second stdout stream would
  corrupt the painted frame). Only ROW lines get line-map entries — session
  headers and blank separators (render.sh:91-92) are unmapped; the navigable
  set j/k iterates is exactly the mapped lines, and
  `AGENT_FLEET_HIGHLIGHT_LINE` naming an unmapped line is a no-op. Two required plumbing changes, not just a
  re-point: (a) render.sh gains the standard
  `STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"`
  line (jump.sh:5 pattern — today render.sh defines only SCRIPT_DIR/MODEL,
  render.sh:4-5; the cache/line-map paths and the sandboxed test both
  depend on it); (b) the row pipeline (render.sh:65-82) today reads `sid`
  only to compute the label and never forwards `key`/`sid`/`cwd` to the
  emit stage — the line-map needs (line# ↔ key+sid/cwd), so those IDs are
  threaded through row assembly as payload. Cache = one file under `$STATE_DIR`
  (`.board-cache.json`, the model's row JSON, atomic tmp+rename) — written by
  **board.sh** each tick after it runs the model (sole writer), read by
  render.sh for nav/WINCH repaints; no cache present (standalone render
  before board's first tick) → render emits an empty frame, exit 0. Highlight via
  `AGENT_FLEET_HIGHLIGHT_LINE` env (prefix consistent with every other knob) →
  reverse-video at paint.
- **board.sh** → stateful loop (sole writer of `.board-cache.json`). Plumbing:
  gains `MODEL="${AGENT_FLEET_MODEL:-$SCRIPT_DIR/agent-fleet-model.mjs}"`
  (jump.sh:6 pattern — the model call moves INTO board.sh; today board.sh
  defines only SCRIPT_DIR/STATE_DIR/RENDER/INTERVAL, board.sh:4-7) and the
  bash-4 guard (Error handling); stty/trap changes in the setup block below.
  ```
  state: cached rows, highlight = row ID + its last-seen line index.
         Row ID = `key+sid` for sid rows; sid-less rows (duplicate/synthetic/
         idle/v1) are one-per-cwd, so their ID is `cwd` — `key+sid` alone is
          NOT unique (model.mjs:153 and :175 both emit key:null,sid:null rows;
          two such cwds would collide). ID is primary — re-sort safe; the
          retained index is refreshed every paint and used ONLY when the ID
          vanishes. Ordering: HIGHLIGHT_LINE always names the PREVIOUS
          frame's index for the ID — the line-map is produced BY the render
          that consumes the highlight, so no same-frame map exists; a re-sort
          misplaces the highlight for exactly one frame and the refresh
          corrects it — accepted.
  setup: saved_tty="$(stty -g 2>/dev/null || true)"; stty -icanon -echo 2>/dev/null || true.
         NOT needed for `read -n1` itself — bash puts the tty into
         non-canonical mode for the duration of a -n/-N read on its own. The
         stty exists to suppress echo and line-buffering of keys typed
         BETWEEN reads (during the model run + paint), which would otherwise
         smear into the frame or arrive as a burst on the next read. The
         `stty -g` capture is what "restore" means: EXTEND the existing EXIT
         trap (board.sh:22) with `stty "$saved_tty" 2>/dev/null || true` —
         a second `trap ... EXIT` would REPLACE it and drop tput cnorm/rmcup.
         The `|| true` is REQUIRED: board.sh runs under `set -euo pipefail` and
         stty fails on a non-tty stdin — exactly what the piped keyloop test
         feeds it (a pipe needs no stty, so skipping it there is correct;
         contrast the existing `tput ... || true` guards, board.sh:20-21).
         The same EXIT trap also deletes `.board-cache.json` and
         `.board-linemap.tsv` — a post-exit standalone render must take the
         cache-absent empty-frame path, never paint a silently stale frame.
  loop:
    key=""; IFS= read -rsn1 -t $INTERVAL key && rc=0 || rc=$?
                # IFS= is REQUIRED: `read` word-splits, so with default IFS a
                # SPACE or TAB press assigns empty-with-rc-0 — indistinguishable
                # from Enter (space would fire a landing). -r is REQUIRED too:
                # without it a lone `\` keystroke is eaten as a line-
                # continuation escape and swallows the following byte.
                # rc>128 = timeout / SIGWINCH-interrupt ⇒ tick.
                # rc==0 + empty key = Enter (with IFS=, the ONLY empty-with-rc-0
                # keypress — the delimiter itself is never assigned).
                # rc==1 = EOF (closed/exhausted stdin — the piped keyloop
                # test hits this after its last keystroke). REQUIRED branch:
                # without it EOF falls through with empty key and the loop
                # busy-spins at 100% CPU.
                # Discriminate on rc, not on key-emptiness.
    EOF (rc==1) → exit 0 (stdin gone = nothing left to interact with; also
                  what makes the piped keyloop test terminate)
    tick (rc>128) → re-run model (guarded — failure keeps cached frame, see
                    Error handling) → rewrite cache → render → repaint.
                    `read -t` is an IDLE timeout — sustained key input would
                    starve the tick and freeze ages/pane inventory — so the
                    tick is DEADLINE-based: elapsed-since-last-tick is checked
                    every iteration (key or not) and a due tick runs BEFORE
                    the pressed key is processed.
    j/k         → move highlight → repaint cached frame (NO model re-run)
    ESC         → `IFS= read -rsn2 -t 0.05 seq || true` (same IFS=/-r and rc guards as the main
                  read, REQUIRED under `set -euo pipefail` — timeout is the
                  EXPECTED outcome for a bare ESC): `[A`/`[B` = ↑/↓ move
                  highlight; anything else/timeout = bare ESC, ignored
                  (arrow keys are 3-byte CSI sequences; a -n1 read sees ESC
                  alone)
    Enter (rc==0, empty) → re-run the MODEL first (reconcile + stack mutation
                   need a fresh P — `.board-cache.json` is up to $INTERVAL
                   stale, and a stale-old P outside the ~2s window forces a
                   flip the stale-P guard cannot block, manufacturing the
                   bogus passive departure the guard exists to prevent);
                   then sid row: act_land(...); sid-less row (v1/idle/
                   synthetic, all sid:null): focus-only landing
                  (pane focus, no mailbox, no stack write) — jump.sh's
                  focus-only shape. EXCEPTION: a `duplicate` row is a no-op —
                  jump.sh's warn-explicit-duplicate contract deliberately
                   refuses to pick one of an ambiguous cwd's panes
                   (jump.sh:53-57), and a focus-only landing would yank to an
                   arbitrary instance, the same reason warn never enters
                   act_land. Row VANISHED between cache and fresh model
                   (chat closed, pane died, cwd gone ambiguous) → no-op +
                   repaint; NEVER land whatever row now sits at the old line
                   — a dead keypress is fail-safe, an unintended landing is
                   not.
    d           → dismiss(highlighted row) — done/needs-attention rows only
    q           → exit alt-screen, quit
  Test seam: AGENT_FLEET_DECIDE_ONLY=1 — key actions emit DECISION:kind=
             lines (same shape as jump/traverse) instead of acting; after
             each processed key the board ALSO emits
             `DECISION:hidden=<sid,...>` — the optimistic-hide set is
             in-memory only, so this line is the keyloop test's sole
             observable for it.
  ```
  Nav repaints the cached frame locally — model recompute (50–300ms) never
  sits on the NAV keypress path (j/k/arrows; Enter re-runs it deliberately —
  see above). Highlight-by-ID survives re-sorts. Highlight row
  vanishes → highlight the row now at the vanished row's position (else the
  last row); empty board → keyloop stays live. WINCH: the existing trap only
  clears (`printf "\e[2J"`); the interrupt makes `read` return >128, so the
  rc guard (required under `set -euo pipefail`) turns it into a tick that
  repaints from cache.
- **Dismiss** = extended `.select` mailbox: board atomic-writes
  `<key>.select {sessionID, markOnly:true}`. Restricted to `done` /
  `needs-attention` rows WITH a non-null sid. Two sub-rules: (a)
  `isSuppressed` returns false for every other state, so a `d` on e.g. a
  `working` row could never be confirmed (its `suppressed` flag never flips)
  and the row would flap back on the next tick — non-terminal row + `d` =
  no-op; (b) v1 legacy rows carry `sid: null` (model.mjs:172), so their
  viewedTs is null (baseRow, model.mjs:119) and `isSuppressed` can never flip
  for them (core.mjs:127) — a sid-less v1 row can be `done` but is NEVER
  suppressible; and the mailbox needs a sessionID anyway:
  `planSelect` collapses a falsy one to delete-no-mark (core.mjs:264), so a
  `d` there would silently no-op and flap, the exact failure this
  restriction exists to prevent — sid-less row + `d` = no-op. Board hides
  the row optimistically (local suppressed-set) until the next fetch
  confirms it via the per-row `suppressed` flag (model-computed from
  viewedTs; viewedTs itself is not surfaced — see Phase 1 model.mjs). An
  unconfirmed hide expires after ~5 ticks and the row re-surfaces
  (fail-visible — see Error handling). Asymmetry worth naming: dismissing a
  `needs-attention` row is stickier than dismissing `done` — a blocked agent
  emits no new event, so no fresh entryTs ever un-suppresses it, and the row
  re-surfaces only when a NEW alert lands on that sid (or the viewed mark is
  cleared). Deliberate (user-initiated dismissal), but the permanence is why
  this state shares the confirm path. (Terminology: `needs-attention` is blocked-on-human,
  not terminal — "dismissible" = `isSuppressed`-eligible, done/needs-attention
  only. The `idle` summary row, model.mjs:166, is NOT dismissible: nothing to
  suppress; it vanishes on its own when a chat goes working.)
- **sensor `planSelect` markOnly branch** (core.mjs, pure calc): `{markViewed:
  true, deleteMailbox:true}` (no `skipSelect` field — nothing consumes it:
  the TUI post is skipped in the ACTION layer, where `pollSelectMailbox`
  checks `mailbox.markOnly` before calling `selectSessionOnTUI` — the post
  currently happens BEFORE `planSelect`, sensor.js:275-278, so the pure calc
  cannot skip I/O itself). Branch ordering pinned: the existing malformed
  guard (`mailbox == null || !mailbox.sessionID`, core.mjs:264) stays FIRST —
  a markOnly mailbox without a sessionID is malformed (delete, no mark);
  marking viewed against a junk sid would un-suppress nothing and violate
  "fail toward alert stays visible". This deliberately BYPASSES the
  strict-`===` lock
  (core.mjs:248-253) for this verb only — the lock stays intact for the
  select verb; markOnly never consults `selectOk` at all (no select is
  attempted, so there is nothing to check — hence nothing to invert).
  Truthfulness comes from the `d` press itself,
  not a TUI round-trip. ~10 lines action layer.
  Single-writer invariant on viewed.json preserved. Truthful by construction:
  pressing `d` = user saw the row.

Dismiss alternatives rejected: separate `.dismiss` mailbox (duplicates proven
machinery for identical semantics); board writing viewed.json directly
(lost-update race vs sensor's read-modify-write + corruption blast radius of
`{}` fallback un-suppressing every row fleet-wide).

## Error handling

All failures fail toward "alert stays visible" — never silently hide.

| failure | behavior |
|---|---|
| stack_write fails (ENOSPC, read-only FS) | warn on stderr, press CONTINUES to act_land — the stack file is disposable (Maintainability), so a lost breadcrumb must not eat the user's landing; the reconcile flip re-detects on the next press (reconcile runs every press). The guard lives INSIDE `stack_write` (warn-and-return-0) so `set -euo pipefail` never aborts the press on it — see Assumptions & Resolutions |
| malformed traverse-stack.json | tolerant-read → empty; reconcile re-establishes current only — back/forward history is permanently lost (viewed[] remains as fallback history — restart-cold caveat: per-pid viewed files orphan on restart, see Timeline semantics — MINUS any sid with a live unsuppressed alert, which pending-wins excludes from viewed[]; those surface via pending[]/Alt-] instead) |
| stack entry dead at pop | skip, pop next; back-pops exhaust → viewed[] fallback, forward-pops exhaust → pending[0] (the empty-forward branch — a forward press never falls BACK to viewed[]) |
| ambiguous cwd at traverse time | its sids are unlandable-but-NOT-dead (see Traverse stack): pops skip without pruning, timeline keeps them, resolves when the duplicate instance closes |
| half-written `.select` mailbox | existing planSelect malformed path: delete, no mark |
| sensor down at landing | mailbox persists, consumed on restart; row lingers = correct |
| sensor down at dismiss | mailbox persists, consumed on restart; the optimistic hide is in-memory only — board restart drops it and the row re-surfaces (fail-visible), and an unconfirmed hide also expires after ~5 ticks without a `suppressed`-flag confirm, same direction |
| `tui.session.select` unknown/deleted sid | top-level resolution fails → skip the write entirely (same degrade as other handlers); selectedSid stale → next event fixes |
| markOnly + jump same tick | single-slot mailbox: the later tmp+rename CLOBBERS the earlier before the sensor poll reads it — nothing serializes producers, one request lost. Accepted (same-tick collision on one key means two actors racing one pane). Lost markOnly self-heals: row stays visible, press `d` again. Lost select: pane focus happens without the chat switch — press again. |
| model failure (zellij blip) | board keeps cached frame. Phase 2 moves the model call INTO board.sh, so the guard moves with it: the tick's model run is rc-guarded (same role as today's `|| true` on `"$RENDER"`, board.sh:26 — that guard is on the paint-only render after Phase 2 and no longer covers model failures) and a failure skips cache-rewrite + repaint. Traverse: real spawn failure trips `set -euo pipefail`; but the model also exits 0 with valid-but-EMPTY JSON when zellij fails (model.mjs:35-39), so traverse.sh additionally guards `live[]` empty ⇒ abort non-zero BEFORE any stack mutation — without it every stack entry resolves dead and one Alt-[ prunes the whole back stack |
| fast key-mashing (two traverse procs) | last rename wins; worst case one lost breadcrumb — no locking. DISTINCT target keys → both land (separate mailboxes). SAME key inside one poll → the markOnly-row clobber applies: the later rename's select wins, the earlier press's pane-focus still fires but its chat switch is lost (press again). Stale-P flips from presses inside the async persist window are blocked by the reconcile ts guard (see Traverse stack), not by this row |
| bash < 4 | existing version-guard pattern — jump.sh/render.sh have it; board.sh currently has NONE and gains it in Phase 2 (the loop's suppressed-set and highlight-by-ID map are associative arrays — bash 4 feature; `read -s/-n` and integer `-t` would run on 3.2, but the ESC branch's fractional `-t 0.05` is bash-4-only too) |

## Testing

Hermetic bash harnesses + env injection, matching repo conventions (no
frameworks).

- **core.mjs**: `planSelect` markOnly (ok /
  malformed) — extend `agent-fleet-sensor.test.mjs`. (A markOnly mailbox
  naming an unknown/deleted sid is NOT a planSelect case — planSelect never
  resolves sids; the sensor's top-level-resolution-failure path skips the
  write, see Error handling.) The `tui.session.select` branch is ACTION-layer
  (sensor.js: resolve + mergeViewed + envelope persist — no new pure calc is
  introduced for it) and is NOT covered by `test-agent-fleet-sensor.sh`: that
  harness drives `opencode run` headless (test-agent-fleet-sensor.sh:47-48),
  no TUI exists, so the event can never fire there. Its coverage is the
  Open-checks live verification plus, once delivery is confirmed, a
  synthetic-event test driving the plugin's `event` handler in-process with
  a fabricated `tui.session.select` payload. UNVERIFIED until then — see
  Open checks.
- **`test-agent-fleet-traverse.sh`** (new): sandbox state dir + live-panes/ps
  overrides + synthetic stack file (same harness shape as
  test-agent-fleet-jump.sh — the REAL model with sandboxed inputs, so no
  `AGENT_FLEET_MODEL` injection needed); assert `DECISION:kind=` lines under
  `DECIDE_ONLY`, and stack file + `.select` contents under `DECIDE_ACT` (the
  decide-only seam short-circuits before side effects, so stack assertions
  must run in the act seam). Cases: acceptance scenarios 1 & 2, stack-dry
  fallback, dead-entry prune, MRU dedup, current-removal invariant.
- **jump.sh refactor**: `test-agent-fleet-jump.sh` passes unchanged — proof
  for the decision + mailbox path only; the extracted focus tail (aerospace/
  zellij) is outside hermetic coverage and gets a manual smoke check instead.
- **board**: `test-agent-fleet-render.sh` is REWRITTEN (not "passes
  unchanged" — contrast jump.sh): the `AGENT_FLEET_MODEL` injection seam
  (render.sh:5) disappears with the model call; cases become paint-from-cache
  + line-map, driven by a fake `.board-cache.json` in sandbox
  `$AGENT_FLEET_STATE_DIR`. Keyloop test pipes a keystroke stream and asserts
  DECISION lines (via board.sh's `AGENT_FLEET_DECIDE_ONLY` seam, above) +
  optimistic-hide state.
- **model** (`scripts/test-agent-fleet-model.sh`, extended): timeline (pending-wins, live-prune, FIFO, sid≠current guard) +
  instances[]/selectedSid + viewed[]'s viewed.json join — all driven by sandbox
  `$AGENT_FLEET_STATE_DIR` state/viewed files (no new env override needed;
  `AGENT_FLEET_LIVE_PANES_OVERRIDE`/`AGENT_FLEET_PS_OVERRIDE` unchanged). NO
  focus fields — reconcile reads `selectedSid` by design, so there is no
  `is_focused` plumbing to test.
- **zellij keybinds**: extend `scripts/test-zellij-config.sh` (today it greps
  only the Alt-y bind) to assert the new Alt-[/Alt-] traverse binds and the
  Alt-{/Alt-} swap-layout relocation.

## Maintainability / extensibility

- **model.mjs = single source of truth** — new consumer (tmux port, picker,
  statusline) = read model + call act layer; no sensor changes.
- **act layer = one landing primitive** — any future "go to chat X" feature
  reuses focus/select/viewed-marking; never re-implemented.
- **Mailbox generalizes** — `.select` carries 2 verbs (select, markOnly);
  future verbs (close/pin) = new plan branches; producers stay dumb.
- **Stack file disposable**, `v:1` schema field from day one.

Named upgrade paths (recorded, not built): zellij-focus poller (passive gap);
dead-pid state-file janitor (disk grows ~1–2KB per file per instance ever
launched — state and viewed files; the stack file is a single global file,
not per-instance; read-side pruned — harmless
until it isn't); event-driven board refresh if zellij gains pane lifecycle
hooks; back-stack cap (back[] accumulates dead sids until popped past — add a
cap only if a long-lived no-back-press session ever makes that visible).

Explicitly NOT built (YAGNI): caps/compaction, NEW pollers (the existing
mailbox poll + board tick stay), cross-machine sync, per-repo stacks, TUI
libraries, locking.

## Assumptions & Resolutions (design-review rounds 2–3)

Decisions made during critique triage; override freely.

- **Alt-, / Alt-. chosen for traverse (not Alt-[/Alt-])** — verified unmapped
  in upstream locked defaults and in this config's locked block; ESC-`,` /
  ESC-`.` carry no CSI-parse hazard; Shift gives `<` / `>`, preserving the
  back / forward visual mnemonic beside Alt-y. Swap-layout keeps `Alt [` /
  `Alt ]` unchanged — no relocation. Override if either ESC-`,` or ESC-`.`
  ever surfaces a CSI-parse hazard in a new terminal — then swap Alt-, /
  Alt-. with another unmapped pair, do not take Alt-[ / Alt-].
- **Reconcile signal = `selectedSid` (max ts across instances), not pane
  focus** — pane focus is unobservable at press time (the transient hotkey
  pane is the focused one) and `is_focused` is not unique. This makes the
  design depend on `tui.session.select` reaching plugins, which is UNVERIFIED
  (open check below). If it fails live, the fallback is reconcile-from-stack-
  only (manual nav invisible; the accepted gap widens) — do not substitute a
  focus poller without revisiting the "pane focus ≠ attention" argument.
- **Stack entries are bare sids; key/session/pane/tab re-resolved from the
  model at landing** — fixes stale-key landings after opencode restarts and
  leaves the element shape unambiguous. Cost: the model lookup already on the
  press path.
- **`selectedSid` persisted on mailbox consume regardless of event
  verification** — ~10 lines with the factory-scope threading (see Manual
  navigation tracking); removes the
  otherwise load-bearing question of whether the sensor's own TUI post echoes
  back as `tui.session.select`.
- **Stale-P guard is a time WINDOW, not a strict ts inequality** — a strict
  `P.ts > current.ts` rule contradicts the failed-select self-heal (a failed
  landing leaves P permanently older than current, so the flip would be
  blocked forever). The window — flip blocked only while `current.ts` is
  fresh (~2s) — is the minimal rule satisfying both: bogus flips only ever
  originate inside the persist window; outside it an older P can only be a
  real TUI state. Override if a slower (>2s) persist path ever appears —
  widen the window, don't drop it.
- **viewed[] derives from `instances[]` + viewed.json, not `rows[]`** — a
  rows-derived viewed[] provably cannot contain ambiguous-cwd sids (their
  rows collapse to one sid:null duplicate), contradicting "timeline keeps
  them"; an instances-derived one can, and makes the live-prune dedup rule
  meaningful. Cost: viewed[] includes unlandable-ambiguous sids, so the
  stack-dry fallback must skip them (specified in the Alt-[ rule).
- **The stack file is written by act_land CALLERS, not act_land** — the
  mutation differs per caller and `act_land key sid session pane tab` carries
  no stack state. act.sh exports the helpers; callers compute + write, then
  invoke act_land for mailbox + focus. The earlier "act layer writes the
  stack" phrasing was ambiguous; the diagram/invariants ("written by act_land
  callers") win. Placement vs the test seams: computation pre-seam (pure);
  the write runs in the caller right after computation — BEFORE act_land and
  before the noop/warn plain exits — through act.sh's `stack_write`, which
  self-guards on `DECIDE_ONLY` (jump.sh's own check lives inside `goto_act`
  and cannot cover caller-side writes). jump.sh's `DECIDE_ONLY` contract (no
  side effects) and "test-agent-fleet-jump.sh passes unchanged" both depend
  on the helper-internal guard.
- **Reconcile ordering = FIRST, on every press, including non-select
  outcomes** — the whole point is capturing manual chat switches at keypress
  time; deferring reconcile to select-landings-only would leave switches
  made before a noop/warn press unrecorded. "Non-select outcomes leave the
  stack unchanged" therefore scopes to the navigation mutation (no push, no
  clear), not to reconcile's own flip. Alternative (reconcile only on
  landings) rejected: it silently drops exactly the passive departures
  reconcile exists to catch.
- **Reconcile-adopted flips CLEAR the forward stack** — a manual in-TUI chat
  switch is the analog of clicking a link: stale redo surviving it would
  land Alt-] somewhere the user no longer means. Alternative (reconcile
  preserves forward) rejected: round-trip fidelity matters only within
  deliberate traverse presses, not across a manual context switch.
- **At-end presses PERSIST the dead-entry prune** — an Alt-[/Alt-] that finds
  no landable target still writes the stack file with popped-past dead
  entries removed (no forward push, current unchanged). Otherwise pruning
  would be in-memory only, dead entries would linger forever, and the
  empty-`live[]` guard's stated justification (one press prunes the whole
  back stack) would be void. Alternative (at-end leaves the file untouched)
  rejected for exactly that reason.
- **viewed[] fallback scan is POSITION-based, not head-first** — viewed[] is
  event-ordered (entry-pinned viewedTs), so a head-first "first ≠ current"
  scan oscillates between the two newest entries and deeper entries are
  unreachable; scanning from current's position toward the tail walks older
  entries. Alternative (wall-clock viewedTs so landing re-orders viewed[])
  rejected: entry-pinning is load-bearing for suppression — a wall-clock
  `now` would mask a fresh event landing between select and write. Accepted
  cost: the fallback walks event recency, an approximation of visit history
  that only matters after stack loss (the stack file is the real MRU).
- **Board Enter re-runs the model; board-internal keys never reconcile** —
  reconcile needs a fresh P; the cache is up to $INTERVAL stale and a
  stale-old P outside the ~2s window forces a flip the stale-P guard cannot
  block. Alternative (reconcile off cache + widen the window) rejected: the
  window exists for the 400ms persist path, not for tick staleness — widening
  it would delay legitimate flips.
- **Board reads use `IFS= read -r` everywhere** — without `IFS=`, SPACE/TAB
  presses word-split to empty-with-rc-0, indistinguishable from Enter (space
  would fire a landing); without `-r`, a lone `\` is eaten as an escape.
  Alternative (discriminate on key value instead of rc) rejected: the rc
  discrimination is what separates timeout/EOF/Enter cleanly.

- **stack_write failure = warn-and-continue, not abort** — the stack file is
  disposable history; aborting the press would eat the user's landing (the
  write is ordered BEFORE act_land, so an abort would eat EVERY landing) for
  the sake of a breadcrumb. The lost reconcile flip re-detects on the next
  press. Alternative (fail-closed abort under `set -e`) rejected: fail-visible
  applies to alerts, not to navigation history.

## Open checks (pre- and mid-implementation)

- **Close the restart-cold dead-entry hole BEFORE Phase 1 traverse ships**
  (see Traverse stack semantics > RESTART HOLE): leading close is a sensor
  startup seed of `sessions` from `client.session.list` (also re-warms the
  Dedup #2 live-prune and the landing row lookup); fallback is a narrowed
  prune rule against warm instances only. Decide at the same time whether
  the model merges pid-sibling viewed files per cwd (max ts) — same root:
  per-pid re-keying. Until closed, treat every opencode restart as capable
  of wiping back/forward history on the next Alt-[.
- **Live-verify `tui.session.select`**: fires on in-TUI chat switch AND
  reaches a plugin `event` handler with `properties.sessionID` (binary
  presence is proven; delivery is not). Also check whether the sensor's own
  `/tui/select-session` post emits it (mitigation in place either way).
- **Manual smoke of the extracted focus tail** during the Phase 1 refactor —
  hermetic tests cannot cover the aerospace/zellij focus calls.
- **Verify zellij's KDL keybind parser accepts `Alt {` / `Alt }`** as key
  names (the swap-layout relocation target). If rejected, pick different
  swap-layout keys before touching zellij.nix — do not silently drop
  swap-layout nav. Also live-verify `Alt [` / `Alt ]` are DELIVERABLE to
  zellij at all: terminals emit Alt as an ESC prefix, so Alt+[ is
  `ESC [` — the CSI introducer — which some terminals/parsers swallow or
  misparse. Prior art exists: both keys are bound to swap-layout in
  `locked` mode TODAY (zellij.nix:279-284), so deliverability is already
  demonstrated if swap-layout nav currently works — the live check reduces
  to confirming that. If undeliverable, pick different traverse keys before
  touching zellij.nix.
