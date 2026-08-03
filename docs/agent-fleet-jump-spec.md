# agent-fleet jump/traverse spec

Desired behavior of the traverse stack across `agent-fleet-jump.sh` (j),
`agent-fleet-traverse.sh` (`,` / `.`), and `agent-fleet-board.sh` (Enter, d,
j/k). Shared machinery lives in `agent-fleet-act.sh`. Tests:
`scripts/test-agent-fleet-{jump,traverse,board}.sh`.

## Notation

- Sessions (opencode chat sids): a, b, c, ...
- **Stack**: `[a*b]` — linear history, `*` marks current.
  Linear order = `back[] ++ [current] ++ reverse(forward[])`
  (forward is LIFO: next pops its last element).
- **Alerts**: `<ab>` — unacked alerts, b occurred after a (FIFO).
  Model: `timeline.pending` (ts ascending).
- Actions: `j` jump-to-top-alert, `,` prev, `.` next, board Enter / d / j/k.

`[a*b]<c> j-> [abc*]<>` reads: jump from current a lands on alert c; new
stack is `[abc*]`, no alerts remain.

## Invariants

I1. **No live session is ever dropped from the stack.** New navigation
    (select-nav) and reconcile-flip merge `reverse(forward)` into `back`
    instead of clearing forward:
    `new_back = back + [old_current] + reverse(forward)`, minus target.
    Linear history is preserved exactly; forward always empties on select-nav
    (entries move, never vanish).

I2. **No dupes created.** Target is removed from back+forward before the
    old-current push; current-removal invariant: new current appears in
    neither stack. Pre-existing dupes of unrelated sids are untouched.

I3. **Pruning is limited to dead sids** (absent from every live instance)
    and happens only in traverse walks. Known compromise: a sid that
    resurrects via agent restart (re-seeded as `unknown`, then landable)
    loses its stack position.

I4. **Ambiguous entries are never dropped.** Ambiguous = live but
    unlandable: duplicate-cwd instances (rows collapse to one warning row)
    or startup-seeded `unknown` sessions. Walks skip-retain them; next
    pending-fallback merges them into back; next at-end keeps them in
    forward. When the dupe resolves they become landable in place.

I5. **Reconcile on every model-touching press** (jump, traverse, board
    Enter noop/focus paths). Adopt (null current) never pushes; stale-P
    within 2s window ignored; flip follows I1 (merge, no drop).

I6. **Board j/k is pure local cursor movement** — no model run, no stack
    read/write, no reconcile, no mailbox. Only Enter (select-nav) and d
    (ack-only mailbox, stack untouched) mutate state.

## Action semantics

### j — jump (agent-fleet-jump.sh)

Target = `actionable[0]`, sorted `rank` desc then `ts` desc: highest-priority
alert first; **reverse-recency holds only within equal rank**. Landing
writes the `.select` mailbox; the sensor consumes it asynchronously
(≤~400ms poll) and the alert acks. Re-press before the ack re-targets the
same sid — idempotent (no dupes, traversal stalls, no corruption).

Select-nav mutation (I1/I2): `[a*b]<c> j-> [abc*]`. Alert on current sid is
a near-noop (ts refresh). Alert already in back dedupes: `[ab*]<a> j-> [ba*]`.

### `,` — prev

Walk `back` end→start (MRU): landable → land; ambiguous → skip-retain;
dead → prune. Exhausted → scan `timeline.viewed` (newest-first, landable
only) from current's position; else at-end (stack still written with
dead-prune applied).

### `.` — next

1. Stay-put guard: pressed from an agentless session (e.g. board/notes)
   with landable current → re-select current, no movement.
2. Walk `forward` end→start (LIFO), same classify rules as prev.
3. Forward dry → first `timeline.pending` sid ≠ current.sid (FIFO,
   oldest alert first), no classify filter (pending ⊆ rows-with-sid).
   Ambiguous forward survivors merge into back per I1.
4. No pending → at-end; ambiguous forward entries kept (I4), dead pruned.

### board Enter / d

Enter on a sid row = select-nav (same mutation as j). Enter currently skips
`stack_reconcile` on the select path (divergence from jump/traverse;
reconcile runs only on its noop/focus-only paths). d = ack-only mailbox
(`markOnly`), no stack touch.

### Reconcile flip time-travel

Stale-P window is 2s. If mailbox consume lags >2s after a landing (agent
hung), the next press flips current back to the old cursor and pushes the
just-landed sid to back — stack rewrites recent history. Rare; accepted.

## Acceptance scenarios

| # | start | actions | result | notes |
|---|-------|---------|--------|-------|
| 1 | `[a*b]<c>` | j | `[abc*]<>` | forward merges into back (I1) |
| 2 | `[a*]<dc>` | j j | `[ac*]<d>` → `[acd*]<>` | same-rank alerts; ack between presses |
| 3 | `[ab*]<a>` | j | `[ba*]` | dedupe, no dupes (I2) |
| 3b | `[ab*c]<a>` | j | `[bca*]` | c retained via merge (I1) |
| 4 | `[a*b]<cd>` | . . | `[ab*]<cd>` → `[abc*]<d>` | stack first, then alerts FIFO |
| 4b | `[ab*c]<cd>` | . . | `[abc*]<d>` → `[abcd*]<>` | c popped from forward; landing acks c |
| 5 | `[a*]<dc>` rank(d)>rank(c) | j | `[ad*]<c>` | priority beats recency |

## Test mapping

- I1 merge, flip-only: jump test 33 (passive departure).
- I1 merge, flip + select-nav order: jump test 30.
- I2 dedupe exact-sequence: jump test 34.
- I1 on warn/focus/fallback early-exits: jump tests 40b/40c/40d.
- Prev MRU / next LIFO / forward-pop: traverse scenario tests 1-2,
  `test_back_pops_mru_forward_pops_lifo`.
- I4 ambiguous skip-retain (prev): traverse `test_ambiguous_entries_skipped_but_retained`.
- I4 ambiguous merge / at-end keep (next): traverse next-direction
  ambiguous-forward test.
- I3 dead-prune: traverse `test_no_landable_target_at_end_no_mailbox`,
  `test_forward_all_dead_falls_to_pending`.
- Board Enter mutation parity: board case19; reconcile persistence:
  board cases 36/37/22.
