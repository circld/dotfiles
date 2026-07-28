# jump-to-agent Exact Session Implementation Plan

**Goal:** `jump-to-agent` lands on the exact opencode pane and exact chat session, or refuses to act when exactness cannot be proven.

**Architecture:** Keep pane focus cwd-based, but make cwd uniqueness a hard invariant: one live opencode instance per cwd. Track state per process and per top-level chat session, use a pid-keyed mailbox for in-process `tui.selectSession`, and no-op on duplicate same-cwd opencode instances.

**Tech Stack:** Bash (`agent-fleet-jump.sh`, `agent-fleet-render.sh`, `jq`, `zellij`), opencode plugin JS, Node stdlib. Existing tests: `agent-fleet-sensor.test.mjs` (pure helpers, a top-level `node:assert` script run as `node external/opencode/plugins/agent-fleet-sensor.test.mjs` — NOT `node --test`; it contains no `node:test` `test()`/`describe()` blocks. Under `node --test` the file still executes during discovery and a top-level `assert` throw surfaces as a file-level failure with a non-zero exit — so a failure is NOT silently swallowed — but because there are no registered `test()` cases the summary reports `tests 0` and there is no per-check reporting, so the plain-`node` invocation is the intended one for readable assertion output) and `scripts/test-agent-fleet-sensor.sh` (loads the plugin under a real `opencode run` and asserts a state file is written; it invokes the `.mjs` via plain `node`, line 14). No jump/render tests exist yet — Tasks 5 and 6 create `scripts/test-agent-fleet-jump.sh` and the render test file.

---

## UX Contract

Supported:

- One opencode instance with many chat sessions in one cwd.
- Multiple opencode panes on different cwd values.
- Same repo in different worktree cwd values.
- Many shell/editor panes sharing cwd with one opencode pane.

Unsupported:

- Multiple live opencode instances with the same cwd.

Unsupported behavior is explicit:

```text
multiple opencode instances found for cwd=<cwd>; use one opencode instance with multiple chat sessions
```

When unsupported, jump must do nothing FOR THAT cwd: no pane focus, no `.select` write, no viewed mark for the duplicated cwd. A duplicate on some OTHER cwd does NOT block unrelated jumps. The distinction between "excluded from candidacy" and "warn-and-no-op" is resolved by WHERE the human's target points, and detection runs in a fixed order:

1. **Detect duplicate cwds first**, from the live pane table (Flow > Jump). A cwd with ≥2 live opencode panes is marked ambiguous. Its sessions never enter the ranked candidate pool — the ambiguous cwd contributes ZERO ranked candidates.
2. **Then resolve the target against that pool:**
   - **Explicit-cwd request naming an ambiguous cwd:** the human's target IS the duplicated cwd, so warn-and-no-op (Flow > Jump). This is caught by comparing the requested cwd against the ambiguous set directly — not by ranking (the ambiguous cwd has no ranked candidates to be "top" of).
   - **Global jump:** rank only the non-ambiguous candidates. Because ambiguous cwds contributed no candidates, the ranked pool cannot contain one — so a global jump NEVER "detects a top-ranked duplicate." The warn-and-no-op in the global path applies ONLY to an explicit request; a global jump simply picks the top NON-ambiguous candidate and proceeds. If EVERY actionable candidate belonged to ambiguous cwds (pool empty), global jump falls through to the fallback pane (step 10), it does not warn.

So the two mechanisms are not contradictory: exclusion-from-ranking is the global-jump behavior; warn-and-no-op is the EXPLICIT-cwd behavior. There is no "global jump whose top-ranked candidate is a duplicate" case, because duplicates are removed before ranking.

## Core Invariant

For exact pane+session targeting, each cwd must have at most one live opencode instance.

`jump.sh` can focus the correct pane by cwd only when cwd is unique among live opencode panes. `sensor.js` can select the correct chat session inside that one process via its own plugin `client`.

No pid-to-zellij-pane registry is required while duplicate same-cwd opencode instances are unsupported.

**Exception — headless `opencode run` sharing a live cwd (must be guarded):** the live pane table is authoritative for PANE liveness, but it is NOT authoritative for how many opencode PROCESSES hold a cwd. A headless `opencode run` (or any opencode process without a zellij pane) loads this plugin and writes a `<cwd-hash>-<pid>.json` with a live, `comm=opencode` pid. If it shares a cwd with one real zellij opencode pane, that headless file passes EVERY jump filter (pid alive, `comm` = opencode, cwd HAS a live pane) while the pane table shows only ONE pane — so pane-table duplicate detection does NOT flag it. Two usable v2 files then compete for the same cwd, and a `.select` could be written to the headless pid's mailbox (a process with no visible TUI) instead of the paned instance. Therefore jump AND render MUST treat **more than one USABLE v2 state file sharing a single cwd** as the same ambiguity as two live panes: the cwd is ambiguous (warn-and-no-op / warning row, no `.select`). Duplicate detection is thus the UNION of (a) ≥2 live opencode panes on a cwd (from the pane table) and (b) ≥2 usable v2 files on a cwd (from the surviving state files after stale-pid filtering). Either condition marks the cwd ambiguous.

## Data Model

Sensor writes one file set per opencode process:

```text
<cwd-hash>-<pid>.json
<cwd-hash>-<pid>.viewed.json
<cwd-hash>-<pid>.select
```

State record shape:

```json
{
  "repo": "dotfiles",
  "cwd": "/Users/paul.garaud/dotfiles",
  "session": "zellij-session-name-or-null",
  "pid": 12345,
  "sessions": {
    "ses_abc": {
      "state": "needs-attention",
      "reason": "permission",
      "ts": 1785100000000,
      "task": null,
      "title": "short session title"
    }
  }
}
```

Viewed file shape:

```json
{
  "ses_abc": 1785100000000
}
```

Migration (v1 → v2 shape):

- v1 (current, sensor-core.mjs:46-55) is flat: top-level `state`/`reason`/`ts`/`task` on a `<cwd-hash>.json` file (no pid, no `sessions`).
- v2 moves those fields into `record.sessions[<topLevelSessionID>]` and adds `pid` to the filename and file. `repo`/`cwd`/`session` stay file-level.
- **Consumers MUST first exclude the sidecar files by name before any version check.** `<cwd-hash>-<pid>.viewed.json` and `<cwd-hash>-<pid>.select` are NOT state files: the viewed file's shape is `{ "<sessionID>": <ts> }` (no `repo`/`cwd`/`sessions`), so a naive `*.json` glob would pick it up and, because it ALSO lacks `.sessions`, misclassify it as a v1 state file. State-file discovery must match `<cwd-hash>-<pid>.json` / `<cwd-hash>.json` ONLY — exclude any path ending in `.viewed.json` or `.select` (e.g. glob `*.json` then filter out `*.viewed.json`, or match the `-<pid>.json`/bare-`.json` shape explicitly). The `.sessions`-presence version check runs ONLY on files that survive this name filter. jump.sh's current `"$STATE_DIR"/*.json` loop (line 35) and render.sh's (line 115) both need this exclusion added.
- After that name filter, consumers detect version by presence of `.sessions`: a file WITH `.sessions` is v2 (flatten each entry into a candidate/row); a file WITHOUT it is v1 (jump.sh line "Keep v1 `.sessions`-absent files as pane candidates" — pane focus only, no `.select`; render treats it as a single legacy row using its top-level `state`). `red_cwds_newest_first` / render must keep reading top-level `.state`/`.ts` for v1 files during this window. **v1 asymmetry (INTENTIONAL, not a bug): a v1 actionable row (`needs-attention`/`done`) still RENDERS on the board (from its top-level `.state`, so a legacy agent is not silently dropped), but v1 files do NOT participate in jump's ranked `.select` pool — jump can only focus their pane, never `.select` a specific session, because a v1 file has no top-level session id to target. So a v1 needs-attention/done is visible but jump-to-session lands focus-only.** This deliberately deprioritizes legacy actionable rows for exact-session targeting; it is bounded because a v1 file is reaped on the agent's first restart under v2 (Task 3 step 8), after which its sessions become v2 candidates. This differs from the current `red_cwds_newest_first` behavior, where a red cwd IS a jump target; the trade is that exact-session `.select` requires the v2 per-session shape, and v1 cannot supply a session id.
- **v1 files do NOT get overwritten and never age out on their own.** v1 filename is `<cwd-hash>.json`; v2 filename is `<cwd-hash>-<pid>.json` — different keys, so a restarted agent under the v2 sensor writes a NEW file and the old `<cwd-hash>.json` persists forever. Cleanup is explicit, not passive:
  - Consumers (jump + render) MUST treat a v1 file (`.sessions`-absent) as valid ONLY when its cwd has a live opencode pane AND no USABLE v2 file already covers that cwd. "Usable v2" means a v2 `<cwd-hash>-<pid>.json` that SURVIVES the liveness + pid-reuse filters (pid alive AND its `comm` contains `opencode`) — i.e. a file that will actually produce a candidate/row. A DEAD or reused-pid v2 file does NOT supersede v1: it is dropped by the stale-pid filters, so if it were allowed to suppress the v1 file first, a valid v1 file would vanish and the cwd would produce NO candidate/row at all. Order of operations is therefore mandatory: apply the stale-pid drops (dead pid, non-`opencode` comm) to v2 files FIRST, THEN let only the surviving (usable) v2 files supersede the v1 file. Once a usable v2 file exists for the cwd, the v1 file is ignored (superseded).
  - Sensor init (Task 3) MUST unlink any legacy `<cwd-hash>.json` for its own cwd after its first successful v2 write, so the flat file is actively reaped on the first restart under v2. This is the only in-place v1 handling: delete, not rewrite.

Mailbox shape:

```json
{"sessionID":"ses_abc"}
```

Atomic-write + tolerant-read invariant (mailbox and viewed files):

- Every writer (jump.sh writing `.select`, sensor writing `.viewed.json`) MUST write to a temp path then `mv`/`rename` onto the target so a concurrent reader never sees a partial file. Reuse the existing pattern: `writeStateRecord` in `sensor.js` already does temp-`writeFileSync`+`renameSync`; `jump.sh` must `printf > "$tmp" && mv "$tmp" "$target"` (rename is atomic on the same filesystem). A plain in-place write is a partial-read bug given the sensor's ~400ms poll.
- Every reader MUST tolerate missing/malformed/partial JSON by treating it as absent (no-op), never crashing the poll loop. Reuse the existing pattern: `readExistingState` returns `null` on any `JSON.parse` failure. A malformed `.select` is deleted (same as a failed select) so a bad write can't wedge the mailbox; a malformed `.viewed.json` reads as "nothing viewed" for this frame.

## Flow

### Sensor

- Key state by `<stateKeyFromCwd(directory)>-<process.pid>`.
- Resolve every event `sessionID` to a top-level session id via `client.session.get` parent walk.
- Store one entry per top-level session in `record.sessions`.
- On `chat.message`, transition that top-level session to `working` (PRESERVE the current behavior — sensor.js:176-178 already does `transition('working', null)` on `chat.message`; the v2 rewrite must keep this per-session, or a session that resumed after being red/done never leaves that stale state on the board) AND mark that top-level session viewed. **If the `chat.message` session id is unresolvable (no payload session id, parent walk fails), the working transition has no per-session target: SKIP both the working transition and the viewed mark for that message — do NOT write a file-level/synthetic `working` and do NOT fall back to the current cwd-wide `transition('working', null)`.** Rationale: a v2 record has no top-level `state`, so there is no cwd-wide row to flip; writing a synthetic `__pane__` working entry would create a phantom actionable-looking row, and blindly clearing every session's red/done would drop real attention signals. The cost is a stale done/needs-attention row that survives until the NEXT resolvable event on that session — accepted, because guessing which session resumed is worse than a briefly-stale row. Phase 0 Task 1 records whether `chat.message` carries a usable session id; if it NEVER does, `chat.message` cannot drive the per-session working transition at all and the board relies on the lifecycle `event` handler (session.idle/error, permission/question) for state changes.
- Poll `<key>.select`; on successful `client.tui.selectSession({sessionID})`, mark that session viewed and delete mailbox.
- If select fails, delete mailbox but do not mark viewed.

### Jump

- Build live opencode pane table from zellij: `cwd<TAB>session<TAB>terminal_<id><TAB>tab_id`.
- Load state files.
- Drop invalid JSON.
- Drop per-pid files whose pid is not alive.
- Drop per-pid files whose pid is alive but no longer an opencode process (pid reuse guard). Liveness (`kill -0`) alone is insufficient: the OS can recycle a dead sensor's pid for an unrelated process, leaving a stale `<hash>-<oldpid>.json` that passes the liveness check and would make jump `.select` a mailbox no live sensor polls. Confirm the pid's command is `opencode` (e.g. `ps -o comm= -p <pid>` contains `opencode`) before treating the file as a live sensor. (The live-pane table carries no pid column — its shape is `cwd<TAB>session<TAB>terminal_<id><TAB>tab_id` — so the pid can only be verified against the OS process table via `ps`, not against the pane table.) A pid that is alive-but-not-opencode is dropped, same as a dead pid.
- Drop per-pid files whose cwd has no live opencode pane.
- Detect duplicate live opencode instances per cwd as the UNION of two conditions (see Core Invariant > Exception): (a) ≥2 live opencode panes sharing a cwd **from the live pane table** (the "Build live opencode pane table from zellij" step above) — this catches a just-started duplicate PANE even when zero or one has written a state file yet; and (b) ≥2 USABLE v2 state files sharing a cwd (files surviving the stale-pid filters above) — this catches a headless `opencode run` sharing a cwd with a real pane, which the pane table alone would miss (only one pane shows, so a pane-only check would let jump `.select` the headless pid's mailbox for an unsupported cwd). A cwd flagged by EITHER condition is ambiguous. The pane table remains the authoritative PANE-liveness source; the usable-file count is the authoritative PROCESS-count source.
- If requested explicit cwd is duplicated, warn and no-op.
- Explicit-cwd session selection: an explicit cwd resolves to at most one live opencode instance (the core invariant), but that instance may have MULTIPLE actionable non-suppressed sessions. Explicit cwd focuses the pane and, for `.select`, targets the single highest-ranked actionable session for that cwd using the SAME ranking as global jump (needs-attention over done; within a rank, newest `ts` first). If the cwd has no actionable non-suppressed session, explicit cwd is focus-only / no `.select` (the human asked for the pane, not a specific session). Explicit cwd never writes more than one `.select`.
- For global jump, rank only NON-ambiguous actionable non-suppressed sessions (ambiguous cwds contributed no candidates — they were dropped from the pool at duplicate detection, see UX Contract). The ranked pool therefore never contains a duplicate cwd, so global jump does NOT warn-and-no-op on duplicates; it picks the top non-ambiguous candidate. Warn-and-no-op on a duplicate is the EXPLICIT-cwd path only (step above). If the pool is empty (every actionable candidate was on an ambiguous cwd), fall through to the fallback pane (step 10).
- Otherwise focus pane by cwd and write `<key>.select` for real session candidates.
- If no actionable candidate exists, focus the fallback live pane only; no `.select`. **The fallback pool EXCLUDES panes on ambiguous (duplicated) cwds** — the Unsupported contract says a duplicated cwd gets no pane focus, so a duplicate cwd must never be a fallback target even when it holds the highest `terminal_<id>`. "Fallback" = highest zellij `terminal_<id>` among live opencode panes ON NON-AMBIGUOUS cwds, compared NUMERICALLY on the integer `<id>` (the `.id` from `list-panes`, which increases with pane creation order — the only ordering signal the live pane table carries; there is no wall-clock creation time). The pane column is the string `terminal_<id>` (e.g. `terminal_10`), so a plain lexicographic/string sort is WRONG — it ranks `terminal_9` above `terminal_10`. Parse the integer after `terminal_` and sort numerically (bash: `sort -t_ -k2,2n` on the id, or strip the prefix before comparing). This is a best-effort "most-recently-spawned pane" proxy, not a true timestamp. If EVERY live opencode pane is on an ambiguous cwd, there is no valid fallback — no pane focus (consistent with the Unsupported contract).

### Render

- Render one PROCESS row per live per-pid state file (the process/pane header).
- Under each process row, render nested SESSION rows — one per visible non-suppressed session in that file's `record.sessions` (see Task 6). A process with one visible session collapses to a single line (Task 6 step 5); multiple visible sessions nest under the one process row (Task 6 step 6).
- If a cwd has duplicate live opencode instances, render one warning row for that cwd instead of normal actionable rows.
- Keep synthetic “no sensor yet” row only for live cwd with no usable state file.

## Open Assumptions: Phase 0 Must Verify

Phase 0 verifies these; the ONLY one that hard-stops implementation is `tui.selectSession` missing (see Task 1 step 6). The other two "Hard" items below are hard in the sense that they are load-bearing for exact targeting, but each has a defined DEGRADE path (not a stop): a bad/unresolvable `chat.message` falls back to the `.select`-success-only viewed path; a non-`opencode` `comm` re-keys the guard string or falls back to liveness-only. "Hard" here means "must be verified and its degrade path recorded," NOT "abort if false." Only a missing `tui.selectSession` aborts.

Hard:

- Plugin `client.tui.selectSession({sessionID})` exists and selects session in the current opencode TUI.
- `chat.message` fires only for the session visible/current in that opencode instance. If false, do not use it as viewed signal.
- **`process.pid` inside the plugin equals the OS process whose `comm` (`ps -o comm= -p <pid>`) contains `opencode`.** The jump pid-reuse guard (Flow > Jump; Task 5 step 3) and render pid-reuse guard (Task 6 step 2) both drop any per-pid state file whose pid's command is not `opencode`. If the plugin actually runs under a `node`/`bun`/helper process name (so `process.pid`'s `comm` is `node`, not `opencode`), EVERY valid v2 file would be dropped and jump/render would show nothing. Phase 0 MUST run `ps -o comm= -p <process.pid>` from inside the plugin (log it once, Task 1) and confirm it contains `opencode`. If it does not, the guard cannot key on `comm=opencode`: record the actual process name here and change the guard's expected `comm` string to match (or, if the plugin process name is not stable/distinguishable, fall back to liveness-only + duplicate-pane detection and note the residual pid-reuse risk).

Soft:

- Lifecycle events carry `sessionID`.
- `client.session.get({id})` exposes `parentID` and title/name data.

If lifecycle events lack `sessionID`, route that event type through a synthetic `"__pane__"` session entry. Do not write cwd-only state except if `process.pid` is unavailable.

If a `chat.message` lacks a resolvable `sessionID` (so the viewed target can't be determined), do NOT mark any session viewed for that message AND do NOT run the `working` transition for that message — skip both writes rather than guess (see Flow > Sensor for the full rationale: a v2 record has no cwd-wide row to flip, and a synthetic `working` would fabricate a phantom row). Viewed marking is a suppression signal; a wrong guess would hide an actionable row. The `working` transition is skipped for the same reason — there is no correct per-session target. (Phase 0 Task 1 must record whether `chat.message` payloads carry a usable session id; if they never do, `chat.message` cannot serve as a per-session viewed signal OR a per-session working signal, and only the `.select`-success path marks viewed while the lifecycle `event` handler drives state changes.)

## Tasks

### Task 0 Findings (Phase 0 verification, done ahead of Task 1 — recorded here per Task 1 step 6)

Verified live against the installed opencode 1.18.3 binary + `@opencode-ai/plugin` (checked
1.4.0 through the latest 1.18.7 — same result at every version):

- **`client.tui.selectSession` is NOT missing as a capability — it is a permanent SDK-surface
  gap, not a stale-lockfile/version-skew issue.** `createOpencodeClient` (what plugins receive
  as `client`) instantiates the **v1** `OpencodeClient` (`@opencode-ai/sdk/dist/gen/sdk.gen.js`),
  whose `Tui` class has no `selectSession` method at ANY released version. `selectSession` only
  exists on the separate **v2** SDK class (`@opencode-ai/sdk/dist/v2/gen/sdk.gen.js`), which
  plugins never receive. Confirmed by upgrading a scratch install to `@opencode-ai/plugin@1.18.7`
  (latest on npm) and re-checking — `selectSession` is still absent from the v1 `Tui` class.
- **The server route DOES work.** `POST /tui/select-session` is implemented server-side in the
  running binary (verified via `strings` extraction of the route handler and a live call) and
  returns `{"data":true}` when given a real `ses_...` id.
- **Resolution: call the route via `client.tui._client.post({ url: '/tui/select-session', body: { sessionID } })`.**
  `_client` is the v1 `Tui` class's underlying `HeyApiClient` instance — undocumented/private,
  but functional (verified live: returned `{"data":true}` and the TUI's session dialog target
  changed). A plain `fetch(serverUrl + ...)` from inside the plugin sandbox does NOT work
  (connection refused by the plugin runtime's network policy), so `_client.post` is the only
  working path today. Task 4 step 5 (`Call client.tui.selectSession(...)`) MUST be implemented as
  this `_client.post` call instead, with a code comment documenting the v1/v2 split and that a
  future `@opencode-ai/plugin` release exposing `selectSession` on the v1 client should replace
  this call. This is NOT the plan's hard-stop condition — the capability exists, just via a
  private field instead of a public method — decided with the user 2026-07-27.
- **`chat.message` DOES carry a resolvable `sessionID` directly** in its `input` argument
  (verified live: `{"sessionID":"ses_..."}"`), not merely via a payload needing a parent walk for
  the common (non-child) case. The "unresolvable session id" degrade path in Flow > Sensor /
  Open Assumptions is retained as a defensive fallback but is not expected to trigger for
  top-level sessions.
- **`process.pid` inside the plugin has `comm=opencode`** (verified via `ps -o comm= -p
  ${process.pid}` from inside a live plugin instance) — matches the plan's assumption exactly;
  no guard string change needed.
- **`client.session.get(...)` works and returns `title`.** Signature note for implementers: the
  path parameter key is `id`, not `sessionID` — i.e. `client.session.get({ path: { id },
  query: { directory } })`. Using `{ path: { sessionID } }` silently produces a broken URL
  (`/session/%7Bid%7D`) that 500s with an opaque `UnknownError`, not a clean 404 — worth calling
  out since it's a non-obvious foot-gun.
- **`Session` type does declare `parentID?: string`** (confirmed in the SDK type definitions),
  supporting the plan's parent-walk approach for resolving child/subagent sessions to their
  top-level session — not independently re-verified against a live child session, but the type
  contract is explicit.

### Task 1: Verify opencode plugin primitives

**Files:**

- Modify: `external/opencode/plugins/agent-fleet-sensor.js`
- Modify after verification: this plan file, if assumptions are wrong

**Steps:**

1. Temporarily log hook payload shapes for `event` and `chat.message`.
2. Verify `client.session.get` and `client.tui.selectSession` method names/signatures.
3. Verify `chat.message` viewed semantics.
4. Log `ps -o comm= -p ${process.pid}` once from plugin init and confirm it contains `opencode` (see Open Assumptions > Hard — the pid-reuse guard's `comm=opencode` check depends on this; record the actual `comm` string here if it differs).
5. Remove temporary logs.
6. Hard-stop ONLY if `tui.selectSession` is missing (exact-session targeting is impossible without it — the plan's core promise fails). An unsafe/unresolvable `chat.message` is NOT a stop condition: degrade to the `.select`-success-only viewed path per Open Assumptions (line ~132, ~141) and continue. A `comm` that is not `opencode` is NOT a hard-stop either: adjust the guard's expected `comm` string (or fall back to liveness-only) per Open Assumptions > Hard. Record which paths apply in this plan file.

### Task 2: Add core helpers and tests

**Files:**

- Modify: `external/opencode/plugins/agent-fleet-sensor-core.mjs`
- Modify/Create: existing sensor core test file

**Helpers:**

- `stateKeyForProcess(cwd, pid)` returns `<cwd-hash>-<pid>` when pid exists, else `<cwd-hash>`.
- `isSuppressed(state, entryTs, viewedTs)` returns true only for `done`/`needs-attention` where `viewedTs >= entryTs`.
- `planTransition(existingEntry, nextState, nextReason, now)` preserves `ts` on exact same-state **and same-reason** repeats; a changed reason re-arms. NOTE: the current `planTransition` (core.mjs:85) takes `(existing, state)`, returns `{ write, notify }`, and does not carry a timestamp; `ts` is stamped fresh in `buildStateRecord` (core.mjs:54). This task changes the contract: `planTransition` takes `(existingEntry, nextState, nextReason, now)` and returns `{ write, notify, ts }`, where `ts` is `existingEntry.ts` ONLY when `nextState === existingEntry.state && nextReason === existingEntry.reason` (a true no-change repeat, so a viewed/suppressed row is not re-armed) and `now` otherwise. **`now` is passed IN by the caller (the action layer calls `planTransition(..., Date.now())`), so `planTransition` stays a pure calculation and remains deterministically unit-testable — the core.mjs "pure-logic helpers" invariant holds. Do NOT call `Date.now()` inside `planTransition`.** RATIONALE: reason must be part of the identity check — a new `needs-attention` with reason `question` arriving after a previously-viewed `needs-attention/permission` is a NEW actionable event; keying the repeat check on `state` alone would keep the old `ts`, let `isSuppressed` hide it against the stale `viewedTs`, and silently drop a real attention signal. `buildStateRecord` takes `ts` as an input instead of calling `Date.now()` itself. Update both together. **PRESERVE the existing `idleShouldWriteDone` guard (core.mjs:63-67, `planTransition` line 86): a `done` request MUST still be dropped (`{ write:false, notify:false }`, no `ts` change) when the existing per-session entry is `needs-attention`, so a `session.idle` can never clobber an unanswered needs-attention row. This guard is unchanged by the ts/reason rewrite and must survive the per-session refactor — apply it against the per-session `existingEntry.state`, not a file-level state. Dropping it re-introduces the exact "board goes green while a prompt is still pending" bug the current tests (agent-fleet-sensor.test.mjs:10-16, 42-44, 68-69) guard against.** NOTE ON `working` REPEATS (vs current behavior): the current `chat.message` handler (sensor.js:176-178 → `buildStateRecord`, core.mjs:54) stamps a FRESH `Date.now()` on every message, so a `working` row's `ts` advances with each message today. Under the new same-state+same-reason rule, repeated `chat.message` events (all `working`/`null`) preserve the first `working` `ts` — the age effectively FREEZES across a run of messages. This is intentional and safe: `isSuppressed` ignores `working` entirely (Task 2 — suppression only applies to `done`/`needs-attention`), so a frozen `working` `ts` can never hide a row. The only observable effect is render ordering among `working` rows, which is cosmetic. The "PRESERVE current behavior" note (line ~104) refers to keeping the per-session `working` TRANSITION on `chat.message` (so a resumed session leaves stale red/done state), NOT to preserving the fresh-`ts`-per-message stamping — the transition is what matters for board correctness, the `ts` refresh is not.

**Tests:**

- process key includes pid
- process key falls back without pid
- suppression ignores `working`
- suppression hides viewed terminal states
- same-state repeat does not re-arm suppressed rows
- same state but CHANGED reason DOES re-arm (fresh `ts`, no longer suppressed)
- `done` request is DROPPED when the existing entry is `needs-attention` (idle-does-not-clobber guard preserved — `{ write:false }`, ts unchanged)
- `done` request WRITES when existing entry is `working`/`done`/absent (guard allows the non-red cases)

### Task 3: Write per-process, per-session sensor state

**Files:**

- Modify: `external/opencode/plugins/agent-fleet-sensor.js`
- Modify: `external/opencode/plugins/agent-fleet-sensor-core.mjs`
- Modify: `scripts/test-agent-fleet-sensor.sh` (state-file path assertions — see below)

**Steps:**

1. Destructure `client` from plugin input.
2. Compute key once at plugin init.
3. Add per-key promise chain for read-modify-write serialization.
4. Resolve event session id to top-level session id.
5. Store state in `record.sessions[topLevelSessionID]`. Set `title` from `client.session.get({id})` title/name field; when absent/empty (see soft assumption line ~137), fall back to a truncated `topLevelSessionID` (e.g. first 8 chars) so render always has a non-empty label. Never block a state write on a missing title — it is display-only, not identity.
6. Preserve file-level `repo`, `cwd`, `session`, `pid`. Move `state`/`reason`/`ts`/`task` OFF the top level into per-session entries under `record.sessions[topLevelSessionID]` (v1 → v2 shape change; see Migration below).
7. Keep notification behavior on rising edge into `needs-attention` or `done`.
8. Unlink any legacy `<cwd-hash>.json` for this cwd after the first successful v2 write (see Migration — active v1 reaping).
9. **Update `scripts/test-agent-fleet-sensor.sh` in the same task.** The existing test (lines 40-41) builds `STATE_KEY="$(printf '%s' "$cwd" | shasum ...)"` and asserts a file at `${STATE_KEY}.json`; v2 writes `${STATE_KEY}-<pid>.json`, so the current assertion WILL fail after this task. The test does not know the sensor's pid a priori, so glob for the single per-pid file — but the glob MUST exclude the `.viewed.json` sidecar Task 4 also writes for the same `<key>-<pid>` stem (a bare `${STATE_KEY}-"*.json` matches BOTH `${STATE_KEY}-<pid>.json` and `${STATE_KEY}-<pid>.viewed.json`, and `chat.message` fires during a non-interactive `opencode run`, so the viewed sidecar CAN exist by the time the test globs). Match only the state file: e.g. glob `${STATE_KEY}-"*.json`, then drop any match ending in `.viewed.json` (or glob and assert exactly one non-`.viewed` match), giving `STATE_FILE`. Update the `.repo`/`.cwd` assertions to read from that path, and add an assertion that the written record has a `.sessions` object (v2 shape) rather than a top-level `.state`. This is REQUIRED for Task 7's `test-agent-fleet-sensor.sh` run to pass.

### Task 4: Add viewed and mailbox handling

**Files:**

- Modify: `external/opencode/plugins/agent-fleet-sensor.js`

**Steps:**

1. Add `<key>.viewed.json` read/merge/write helpers. Write atomically (temp+rename, like `writeStateRecord`); read tolerant (null on bad/partial JSON, like `readExistingState`). See Data Model > atomic-write invariant.
2. On safe `chat.message`: transition the current top-level session to `working` (preserve existing sensor.js:176-178 behavior, now per-session) AND mark it viewed at entry ts. Both in the same handler — the working transition is the board-state update, the viewed mark is the suppression signal; dropping either regresses the board. **"Safe" = the session id resolved. If it did NOT resolve, skip BOTH the working transition and the viewed mark (Flow > Sensor); never write a synthetic/file-level working state.**
3. Poll `<key>.select` every ~400ms.
4. Parse mailbox JSON object; on missing/malformed/partial JSON, delete the mailbox and skip (never crash the poll). Require jump.sh to write `.select` atomically (see Data Model).
5. Call `client.tui.selectSession({sessionID})`.
6. Mark viewed only on successful select.
7. Delete mailbox regardless of success.

**Test coverage for this task (REQUIRED — closes the gap between the "Successful select marks viewed" / "Failed select deletes mailbox but does not mark viewed" cases in Required Test Cases and the tasks that were otherwise silent on how they get tested):** the existing `scripts/test-agent-fleet-sensor.sh` runs a single non-interactive `opencode run` and CANNOT exercise `.select` polling or `client.tui.selectSession`. Two options — pick one and record it in this plan file:
   - (preferred, deterministic) Extract the mailbox-handling decision into a PURE helper in `agent-fleet-sensor-core.mjs` — e.g. `planSelect(mailbox, selectOk) -> { markViewed, deleteMailbox }` — and unit-test it in `agent-fleet-sensor.test.mjs`: success ⇒ `{ markViewed:true, deleteMailbox:true }`, failure ⇒ `{ markViewed:false, deleteMailbox:true }`, malformed mailbox ⇒ `{ markViewed:false, deleteMailbox:true }`. The action layer (`selectSession` call, viewed write, unlink) stays a thin wrapper. This keeps the select/viewed semantics tested without a live TUI.
   - (fallback) If the semantics can't be factored into a pure helper, document explicitly here that these two cases are NOT automatically covered and must be verified manually against a live opencode TUI, so the "all pass" in Task 7 is not read as covering them.

### Task 5: Rewrite jump selection as exact-or-no-op

**Files:**

- Modify: `scripts/agent-fleet-jump.sh`
- Create/Modify: `scripts/test-agent-fleet-jump.sh`

**Steps:**

1. Extract live-pane parsing and candidate selection into testable shell functions.
2. Add duplicate-cwd detection as the UNION of ≥2 live opencode panes on a cwd (pane table) AND ≥2 usable v2 state files on a cwd (surviving stale-pid filters) — see Core Invariant > Exception and Flow > Jump. Not pane-table-only: the file-count arm catches a headless `opencode run` sharing a cwd.
3. Filter stale pid files before ranking.
4. Flatten v2 `sessions` into actionable candidates. **Skip any synthetic session id (the `"__pane__"` entry from Open Assumptions line ~144) — it is not a real chat session, so it must NEVER become a `.select` target; `client.tui.selectSession("__pane__")` would fail exact targeting.** A synthetic entry can still keep the pane alive as a focus-only candidate (like a v1 file), but it is never ranked for `.select`. For each flattened REAL session, load the sibling `<key>.viewed.json` and DROP any session where `isSuppressed(state, entry.ts, viewedTs)` is true — jump must not rank an already-viewed terminal (`done`/`needs-attention`) session. This mirrors render's suppression (Task 6 step 7) so jump and board agree on what is actionable; `isSuppressed` is the same core helper (Task 2), reimplemented in bash here (compare `entry.ts` to the viewed map's per-session ts). Without this, jump can focus and `.select` a session the human already looked at.
5. Keep a v1 (`.sessions`-absent) file as a FOCUS-ONLY pane candidate (never a `.select` target) ONLY when its cwd has a live opencode pane AND no USABLE v2 `<cwd-hash>-<pid>.json` already covers that cwd (Migration supersession rule, line ~83). "Usable" = survives step 3's stale-pid filters; run step 3 BEFORE supersession so a dead/reused-pid v2 file cannot suppress a valid v1 file and leave the cwd with no candidate. Once a usable v2 file exists for the cwd, ignore the v1 file. This mirrors render Task 6 step 1 so jump and board agree.
6. For explicit cwd duplicate: warn and no-op.
7. Global jump does NOT warn on duplicates. Ambiguous cwds contributed zero candidates at step 2 (they were dropped from the ranked pool), so the ranked pool can never contain a duplicate cwd — there is no "global top candidate duplicate" case (see UX Contract lines ~35-37 / Flow > Jump line ~130 / Assumptions & Resolutions). Global jump picks the top NON-ambiguous ranked candidate. If the pool is empty (every actionable candidate was on an ambiguous cwd), fall through to step 10 (fallback pane) — do NOT warn. Warn-and-no-op on a duplicate is the explicit-cwd path (step 6) ONLY.
8. For valid v2 candidate: focus cwd, write JSON mailbox atomically (temp file + `mv`; see Data Model). The mailbox `sessionID` must be a REAL top-level chat session id — never the synthetic `"__pane__"` id (already excluded in step 4).
9. For valid v1/no-session candidate: focus cwd only.
10. For no actionable candidates: focus fallback live pane only, EXCLUDING panes on ambiguous cwds (a duplicated cwd never gets pane focus — see Flow > Jump / UX Contract). Highest `terminal_<id>` by NUMERIC integer compare, not string sort — `terminal_10` > `terminal_9`; see Flow > Jump. If every live opencode pane is on an ambiguous cwd, no fallback focus.

### Task 6: Render nested sessions and ambiguity warning

**Files:**

- Modify: `scripts/agent-fleet-render.sh`
- Create/Modify: `scripts/test-agent-fleet-render.sh` (render shell test file — the file Task 7 Verification runs)

**Steps:**

1. Read state files. A file WITH `.sessions` is a v2 per-pid record (flatten its entries into rows). A file WITHOUT `.sessions` is a v1 legacy file — apply the Migration supersession rule (see Migration line ~83): render a v1 file as a SINGLE legacy row (from its top-level `.state`/`.ts`) ONLY when its cwd has a live opencode pane AND no USABLE v2 `<cwd-hash>-<pid>.json` already covers that cwd. "Usable" = a v2 file that survives step 2's dead-pid + pid-reuse filters; run step 2 BEFORE supersession so a dead/reused-pid v2 file cannot suppress a valid v1 file and leave the cwd with no row. Once a usable v2 file exists for the cwd, IGNORE the v1 file (superseded) so it never produces a stale duplicate/ghost row.
2. Filter dead pid and no-live-pane records. Apply the SAME pid-reuse guard as jump (Flow > Jump; Task 5 step 3): drop any per-pid file whose pid is alive but whose `ps -o comm= -p <pid>` does not contain `opencode`. Liveness (`kill -0`) alone is insufficient — a recycled pid belonging to an unrelated live process, plus a live pane on the same cwd, would otherwise render a stale v2 row. Without this guard render and jump disagree on which files are live.
3. Detect duplicate live opencode instances per cwd as the UNION of ≥2 live opencode panes (pane table) AND ≥2 usable v2 files (surviving step 2 filters) on a cwd — same rule as jump (Core Invariant > Exception; Task 5 step 2), so board and jump agree on which cwds are ambiguous.
4. Render duplicate cwd as warning, not actionable rows.
5. Render one visible session as current single-line format where possible. Session label = entry `title`; if empty/missing, use the truncated session id fallback (Task 3 step 5) — render never emits a blank label.
6. Render multiple visible sessions nested under one process row.
7. Suppress viewed terminal session rows. For each flattened v2 session, load the sibling `<key>.viewed.json` (tolerant read: missing/malformed/partial JSON reads as "nothing viewed" for this frame — never crash render, mirror `readExistingState`) and DROP any session where `isSuppressed(state, entry.ts, viewedTs)` is true (`done`/`needs-attention` with `viewedTs >= entry.ts`). This is the SAME suppression jump applies (Task 5 step 4) and the same core helper (Task 2), reimplemented in bash so board and jump agree on what is actionable. `working` is NEVER suppressed (see Required Test Cases). Without reading `.viewed.json` here, render suppresses nothing.
8. Keep synthetic row only when cwd has live opencode pane and no usable state.

### Task 7: Verification

**Commands:**

`test-agent-fleet-jump.sh` and `test-agent-fleet-render.sh` do not exist today; Tasks 5 and 6 create them before this step runs. `test-agent-fleet-sensor.sh` is required here (not just the pure-helper `node` unit run — `node external/opencode/plugins/agent-fleet-sensor.test.mjs`, NOT `node --test`; see line 7): the sensor rewrite in Tasks 3–4 changes plugin loading and file I/O, and only the bash test exercises a real `opencode run` + state-file write. The pure-helper assertions pass even if the plugin fails to load.

```bash
bash scripts/test-agent-fleet-jump.sh
bash scripts/test-agent-fleet-render.sh
bash scripts/test-agent-fleet-sensor.sh   # runs the pure-helper `node ...test.mjs` internally (line 14), then the live `opencode run`
bash scripts/test-transform-commands.sh
```

The pure-helper unit run (`node external/opencode/plugins/agent-fleet-sensor.test.mjs`, NOT `node --test`; see line 7) is NOT listed separately here because `test-agent-fleet-sensor.sh` already invokes it as its first step (line 14). Run it standalone only when iterating on core.mjs helpers without the slower live `opencode run`.

Expected: all pass. "All pass" covers the AUTOMATED cases only. If Task 4 recorded the fallback (non-`planSelect`) path, the two select/viewed cases in Required Test Cases are manual-against-a-live-TUI and are NOT included in "all pass" — verify them by hand and note the result.

## Required Test Cases

- One opencode cwd, two chat sessions: jump writes correct `<key>.select`.
- Two opencode panes, different cwd: jump focuses matching cwd and writes correct mailbox.
- Two worktrees from same repo: treated as different cwd, both supported.
- Duplicate opencode instances same cwd: jump warns/no-op/no `.select`.
- Explicit duplicate cwd: jump warns/no-op/no `.select`.
- Dead pid file sharing live cwd: skipped.
- Headless pid with no live pane: skipped.
- **Headless pid SHARING a live cwd (two usable v2 files, one cwd): treated as ambiguous — jump warns/no-op/no `.select`, render shows the duplicate-cwd warning row.** Covers the Core Invariant > Exception union rule (≥2 usable v2 files = duplicate) that pane-table-only detection would miss.
- **Alive-but-reused pid (pid alive, `ps -o comm= -p <pid>` NOT containing `opencode`) sharing a live cwd: state file DROPPED, same as a dead pid.** The dead-pid test does NOT exercise this — a recycled pid passes `kill -0` — and the guard is load-bearing for jump (Task 5 step 3), render (Task 6 step 2), and the Open Assumptions > Hard `comm` check.
- **Fallback numeric sort: `terminal_10` ranks above `terminal_9`.** Assert the fallback pane selection parses the integer after `terminal_` and sorts numerically, not lexicographically (Flow > Jump; Task 5 step 10). A string sort silently picks the wrong pane.
- **v1/v2 supersession order (Migration line ~84):** (a) a USABLE v2 file suppresses the v1 file for the same cwd (v1 produces no candidate/row); (b) a DEAD or reused-pid v2 file does NOT suppress the v1 file — the v1 file must still produce a candidate/row. Assert the stale-pid drops run BEFORE supersession, or a valid v1 file vanishes and the cwd goes blank.
- Explicit cwd with a single opencode instance holding MULTIPLE actionable non-suppressed sessions: jump focuses the pane and writes exactly ONE `.select` for the single highest-ranked actionable session (needs-attention over done; within a rank, newest `ts` first) — never more than one `.select` (covers the explicit-cwd selection contract, Flow > Jump line ~118).
- Explicit cwd whose instance has NO actionable non-suppressed session: focus-only, no `.select`.
- Successful select marks viewed. *(Automated only if Task 4's preferred `planSelect` pure-helper path is taken; if the fallback path is recorded in Task 4, this is a MANUAL check against a live TUI, not covered by Task 7's "all pass".)*
- Jump skips a viewed/suppressed terminal session and ranks the next actionable one (jump-side `isSuppressed`).
- Failed select deletes mailbox but does not mark viewed. *(Same as "Successful select marks viewed": automated via `planSelect` if Task 4's preferred path is taken; manual otherwise.)*
- Render duplicate cwd warning.
- Render suppresses viewed `done`/`needs-attention`, never suppresses `working`.

## Assumptions & Resolutions

Review-round resolutions where more than one fix was defensible; a human can override.

- **Duplicate-detection sequencing (UX Contract / Flow):** resolved the "exclude from ranking" vs "warn on top-ranked duplicate" contradiction by fixing an ORDER — detect ambiguous cwds first (they contribute zero candidates), then route: explicit-cwd request naming an ambiguous cwd warns-and-no-ops; global jump only ever sees non-ambiguous candidates and never warns on duplicates. Alternative rejected: keep duplicates in the pool and warn at rank time — reintroduces the sequencing ambiguity and lets a duplicate block an unrelated global jump.
- **Headless `opencode run` sharing a live cwd (Core Invariant):** resolved by making duplicate detection the UNION of pane-table duplicates AND ≥2 usable v2 state files on one cwd, rather than adding a pid→pane registry (explicitly Out of Scope). The file-count arm marks the cwd ambiguous so jump no-ops instead of `.select`-ing a headless mailbox.
- **Fallback pane on an ambiguous cwd (Flow / Task 5 step 10):** resolved by excluding ambiguous-cwd panes from the fallback pool, upholding the Unsupported contract ("no pane focus" for a duplicated cwd). If every live pane is on an ambiguous cwd, no fallback focus at all.
- **Task 5 step 7 "global top candidate duplicate" (review round):** Task 5 step 7 previously said "For global top candidate duplicate: warn and no-op," contradicting the resolved sequencing (ambiguous cwds are removed BEFORE ranking, so global jump never sees a duplicate top candidate). Rewrote step 7 to state that global jump does NOT warn on duplicates and falls through to the fallback on an empty pool; warn-and-no-op is the explicit-cwd path (step 6) only. Chose alignment with the already-resolved UX Contract sequencing over re-opening it.
- **Unresolvable `chat.message` session id — working transition (review round):** the plan specified only "do NOT mark viewed" and was silent on the `working` transition when the session id can't be resolved. Resolved: SKIP both the working transition and the viewed mark; do NOT write a synthetic `__pane__` or file-level `working`. Rationale in Flow > Sensor. Alternative rejected: fall back to the current cwd-wide `transition('working', null)` — a v2 record has no cwd-wide row, and a synthetic working entry fabricates a phantom actionable row. Accepted cost: a stale done/needs-attention row survives until the next resolvable event on that session.
- **v1 actionable-row participation (review round):** clarified in Migration that v1 actionable rows RENDER (not silently dropped) but are jump-focus-only, never a `.select` target, because v1 has no per-session id. This is an intentional deprioritization for exact-session targeting, bounded by first-restart v2 reaping (Task 3 step 8). Documented rather than changed — supplying `.select` for v1 would require inventing a session id the file does not carry.

## Out of Scope

- Supporting multiple live opencode instances in the same cwd.
- zellij pane-id to opencode pid registry.
- Backfilling sessions that never emitted events.
- Tracking subagent/task-tool child sessions as separate rows.
- External HTTP calls from `jump.sh` into opencode.
