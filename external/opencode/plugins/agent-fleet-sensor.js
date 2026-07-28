// external/opencode/plugins/agent-fleet-sensor.js
//
// Global opencode plugin. Writes one state file per agent to
// ~/.local/state/agent-fleet/<cwd-hash>-<pid>.json on every relevant lifecycle
// event. The on-disk record is a v2 envelope (file-level identity wraps a
// per-session map) — see agent-fleet-sensor-core.mjs:buildV2StateRecord.
//
// Fires an osascript notification on transitions INTO needs-attention (red,
// blocked on human) OR done (green, agent finished and ready for review) — not
// on every event, to avoid notification noise — and only when the repo isn't
// already the frontmost window (see isRepoVisible in agent-fleet-sensor-core.mjs).
//
// Board-red rule: needs-attention means "opencode is blocked on the human" — anything
// that halts the agent's turn pending a human response goes red, not just permission
// prompts. Currently: permission.asked, question.asked (interactive question tool),
// session.error. Adding a new blocking condition later is a 2-line change: one
// `needs-attention` transition on the blocking event, one `working`/`done` transition
// on its resolution — see the permission.asked/replied and question.asked/replied
// pairs below as the template.
//
// Identity note: cwd is the key. session/repo/tab names all diverge in practice,
// so they are recorded for display but never used as the join key. PID is appended
// to the filename so two opencode panes sharing one cwd (e.g. two worktrees in
// the same tmux session) write distinct files — jump.sh uses the PID suffix to
// target a specific pane.
//
// IMPORTANT: this module's ONLY module-level named/default export is the plugin
// factory itself. Pure-logic helpers (stateKeyFromCwd, planTransition, etc.)
// live in ./agent-fleet-sensor-core.mjs and are imported here. opencode treats
// every named export of a plugin module as a separate plugin factory it MUST
// successfully invoke, so re-exporting the helpers here would break loading
// (verified: opencode awaited escapeAppleScriptString({directory,$}) which
// then crashed on `s.replace(...)`). See agent-fleet-sensor-core.mjs header.

import { mkdirSync, writeFileSync, readFileSync, renameSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

import {
  stateKeyFromCwd,
  stateKeyForProcess,
  repoNameFromCwd,
  buildSessionEntry,
  buildV2StateRecord,
  planSelect,
  planTransition,
  isRepoVisible,
  notificationMessage,
  notificationScript,
  notificationSoundForState,
} from './agent-fleet-sensor-core.mjs';

const STATE_DIR = path.join(os.homedir(), '.local', 'state', 'agent-fleet');

// -- per-key promise chain (read-modify-write serialization) --
// Module-level Map: each per-process state file gets its own chain. transition()
// chains onto the previous tail so a 2nd event arriving mid-read never races
// on the same file. Without this, two events fired back-to-back (verified
// repro: rapid `permission.asked` then immediate `permission.replied`) each
// read the same `existing`, plan independently, and the later write loses the
// earlier's state — the board flickers between an old and new state. With the
// chain, the second step waits for the first to fully read-modify-write before
// reading itself.
// Both resolved and rejected prev promises advance to the next fn (`.then(fn, fn)`):
// we want execution to keep flowing after a failed step, NOT to deadlock the
// chain on a single error. Errors still propagate to the await'er — the
// .catch is intentionally absent in the chain tail so callers see the original
// throw (was: `tail.catch(()=>{})` which swallowed them silently).
//
// Self-clean: after a tail settles, delete the entry IF it is still the
// current tail (a later enqueue may have replaced it; we must not unlink
// someone else's chain). Without this the Map grows unbounded for the
// process lifetime — bounded by # of cwd/pid pairs in one opencode run but
// still wrong pattern. `.finally` runs on both resolve and reject, so the
// entry is cleaned up regardless of outcome.
const chains = new Map();   // key -> Promise<void>

function enqueue(key, fn) {
  const prev = chains.get(key) ?? Promise.resolve();
  const tail = prev.then(fn, fn);
  chains.set(key, tail);
  tail.finally(() => {
    if (chains.get(key) === tail) chains.delete(key);
  });
  return tail;
}

// -- action: read existing state file (I/O, returns null on any failure) --
function readExistingState(statePath) {
  return readTolerantJSON(statePath);
}

// -- action: tolerant-read JSON by path (returns null on any failure) --
// The single primitive backing every JSON read in this module. "Tolerant" is the
// invariant documented in the plan's Data Model section: a missing/partial/malformed
// JSON file MUST read as absent (no-op), never crashing the caller. Wraps JSON.parse
// in a try/catch that collapses every parse + I/O error to null — including ENOENT,
// corruption, truncation mid-rename, and non-string-non-array roots.
function readTolerantJSON(filePath) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

// -- action: write a JSON file ATOMICALLY (I/O) -- Single primitive backing every
// JSON write in this module. Write to a temp file then rename onto the target.
// rename(2) is atomic on the same filesystem, so any polled reader (board render,
// .select poll, viewed.json merge) can never observe a half-written file. A plain
// writeFileSync truncates-then-writes, leaving a window where a concurrent reader
// gets partial JSON — verified to crash the board's `jq` under `set -e`. The temp
// name includes pid so concurrent agents (multiple opencode panes in the same
// STATE_DIR) don't collide on the temp file.
function writeAtomicJSON(filePath, record) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(record, null, 2));
  renameSync(tmp, filePath);
}

// -- action: write state file (I/O) -- delegates to the atomic-primitive; kept as a
// named wrapper because the .json state file carries the v2 envelope schema (file-
// level identity wrapping a per-session map) — the named entry makes that intent
// visible at the call site, and the helper names co-locate with what the file
// actually holds.
function writeStateRecord(statePath, record) {
  return writeAtomicJSON(statePath, record);
}

// -- action: write viewed-map file (Task 4) -- delegates to the atomic-primitive;
// distinct named wrapper because viewed.json's on-disk SCHEME is a flat {sessionID:
// ts} map, NOT the v2 envelope above. Same atomic-write guarantee, different shape.
function writeViewedRecord(viewedPath, record) {
  return writeAtomicJSON(viewedPath, record);
}

// -- action: tolerant-read the viewed map (Task 4) -- Reuses readTolerantJSON's
// "null on any failure" semantic: a partially-written, corrupt, or missing
// viewed.json reads as EMPTY — `?? {}` at the merge site lets the merge proceed
// without an extra branch, and a fresh write replaces the bad file cleanly.
function readViewed(viewedPath) {
  return readTolerantJSON(viewedPath);
}

// -- action: merge one sessionID/ts into viewed.json (Task 4) -- Read-modify-write
// of the flat map. Null-tolerant read + atomic write (above). Last-writer-wins on a
// given sessionID, which is intentional: the only thing that ever bumps a session's
// viewedTs is THIS pane (there is no other writer), and the editor here is the one
// deciding WHICH ts to pin (entry ts at write time). No chain needed: this writer
// runs from inside `enqueue(...)` callers, which already serialize file IO.
function mergeViewed(viewedPath, sessionID, ts) {
  const existing = readViewed(viewedPath);
  writeViewedRecord(viewedPath, { ...(existing ?? {}), [sessionID]: ts });
}

// -- action: tolerant-read the .select mailbox (Task 4) -- Same null-on-failure
// rule as above: missing/partial/malformed JSON returns null. The poll loop calls
// planSelect(mailbox, ...) which short-circuits to {markViewed:false,
// deleteMailbox:true} on null — i.e. a bad `.select` doesn't crash, doesn't claim
// viewed, but DOES get cleaned up so it can't wedge future polls.
function readSelectMailbox(selectPath) {
  return readTolerantJSON(selectPath);
}

// -- action: delete the .select mailbox (Task 4) -- Always safe to call; the
// common crash was trying to delete a non-existent file (e.g. the poll raced
// against a previous successful deletion). ENOENT is swallowed so the poll
// loop never throws.
function deleteSelectMailbox(selectPath) {
  try {
    unlinkSync(selectPath);
  } catch {
    // ENOENT and friends: nothing to do, the post-condition (no file) already holds.
  }
}

// -- action: reap a legacy v1 state file for this cwd (idempotent, best-effort) --
// v1 wrote `${cwd-hash}.json` with no PID suffix and no per-session map. v2
// writes `${cwd-hash}-<pid>.json`. After the first successful v2 write we
// delete the legacy file so the board doesn't render BOTH and confuse the user
// about which one is canonical. Idempotent: called on every write, but
// existsSync-then-unlink is cheap and ENOENT is normal. We do not surface
// failures: a reap miss (e.g. permission) is not worth failing the write
// over — the v2 write is the source of truth from this point on.
function reapLegacyV1(directory) {
  const legacy = path.join(STATE_DIR, `${stateKeyFromCwd(directory)}.json`);
  try {
    unlinkSync(legacy);
  } catch {
    // ENOENT (already gone) or EPERM (rare); either way: no-op.
  }
}

// -- action: read the frontmost window's title via aerospace (I/O) --
// Fails to null on ANY error — aerospace not installed, not running, no focused window,
// unparseable output. isRepoVisible (core.mjs) treats null as "not visible", which fails
// OPEN toward still notifying — see that function's comment. Bounded by the same
// `timeout N` pattern as osascript below; this call is only ever awaited from INSIDE
// notify()'s fire-and-forget body (see notify's own comment for why that placement
// matters), never from transition() directly.
async function getFocusedWindowTitle($) {
  try {
    const out = await $`timeout 2 aerospace list-windows --focused --json`.quiet().text();
    return JSON.parse(out)[0]?.['window-title'] ?? null;
  } catch {
    return null;
  }
}

// -- action: fire macOS notification, gated on visibility (I/O; must never block or break
// the hook) --
// CRITICAL: this runs inside the `permission.ask` hook, whose returned promise opencode
// AWAITS before proceeding with the permission prompt. A try/catch only swallows a
// non-zero EXIT — it does NOT protect against a HANG. If osascript (or now aerospace)
// blocks (no GUI session, a stuck WindowServer, a pending TCC prompt), `await`ing it here
// would stall opencode's entire permission flow indefinitely. So BOTH the visibility check
// and the notification itself are FIRE-AND-FORGET as a single unit (never awaited by the
// hook) AND each wrapped in its own hard timeout as a second guard:
//   - `timeout 2 aerospace ...` / `timeout 5 osascript ...` bound any hang (coreutils
//     `timeout` is on PATH via nix-profile; verified). If it's ever absent the outer
//     `.catch` still swallows the error.
//   - the caller does NOT await notify() — a returned promise is intentionally dropped,
//     so aerospace/osascript latency or failure can never enter the hook's critical path.
//
// See escapeAppleScriptString in agent-fleet-sensor-core.mjs for the injection guard.
// Returns immediately; the async work runs detached. Never throws (async body is wrapped
// so a rejection inside it can't become an unhandled promise rejection at the top level).
function notify($, repo, message, soundName) {
  (async () => {
    const focusedTitle = await getFocusedWindowTitle($);
    if (isRepoVisible(focusedTitle, repo)) return;   // human's already looking — skip
    const script = notificationScript(message, soundName);
    await $`timeout 5 osascript -e ${script}`.quiet();
  })().catch(() => {});
}

function statePathFor(key) {
  return path.join(STATE_DIR, `${key}.json`);
}
// Sibling paths for the sidecar files (Task 4): viewed map and select mailbox.
// Same directory, same <key> base, only the suffix differs — keeps the per-process
// key the single source of identity across all three files. jump.sh and render.sh
// (Tasks 5/6) own the .select producer and the .viewed.json consumer respectively;
// this plugin owns the .viewed.json WRITER and the .select READER.
function viewedPathFor(key) {
  return path.join(STATE_DIR, `${key}.viewed.json`);
}
function selectPathFor(key) {
  return path.join(STATE_DIR, `${key}.select`);
}

// -- action: one poll of the <key>.select mailbox (Task 4) -- Reads the mailbox
// (tolerant: null on missing/parse-failure), posts to the live TUI to switch to the
// requested session, runs the pure decision (planSelect) to get the write plan,
// then applies it: merge viewed if the jump succeeded, ALWAYS delete the mailbox so
// a partial write or failed select can't wedge the poll loop. The selectOk input
// is null-tolerant at the mailbox layer: if `mailbox.sessionID` is missing (parse
// succeeded but the JSON shape is wrong), the action layer short-circuits the TUI
// call (mimicking the malformed case's null mailbox contract), so planSelect gets
// a coherent mailbox presence signal. fire-and-forget at the call site (interval),
// never throws (each branch swallows).
function planViewedTsForSession(statePath, sessionID) {
  const existing = readExistingState(statePath);
  return existing?.sessions?.[sessionID]?.ts ?? Date.now();
}

async function pollSelectMailbox(client, { selectPath, viewedPath, statePath }) {
  const mailbox = readSelectMailbox(selectPath);
  const sessionID = mailbox?.sessionID;
  // Treat a parse-succeeded-but-shape-missing `mailbox` like a malformed one: there
  // is no sessionID to act on, so skip the TUI call (save a network round-trip) and
  // let planSelect collapse to {markViewed:false, deleteMailbox:true}.
  const effectiveMailbox = sessionID ? mailbox : null;
  const selectOk = sessionID
    ? await selectSessionOnTUI(client, sessionID)
    : false;
  const plan = planSelect(effectiveMailbox, selectOk);
  if (plan.markViewed && sessionID) {
    mergeViewed(viewedPath, sessionID, planViewedTsForSession(statePath, sessionID));
  }
  if (plan.deleteMailbox) {
    deleteSelectMailbox(selectPath);
  }
}

// -- magic-number defensives for parent walk + display fallbacks --
// MAX_PARENT_WALK_DEPTH: bounds the parentID walk loop. 1-2 in practice
// (immediate fork, fork-of-fork); 8 is cheap insurance against the server
// ever returning a cyclic parentID, which would otherwise infinite-loop on
// the network I/O. Cap value is named so reviewers can perturb it without
// reading the loop body.
// TITLE_FALLBACK_LEN: soft-truncate a session id when client.session.get
// returned no title. Spec says "first 8 chars" — short enough to read in a
// board row, long enough to disambiguate. Display only; the FULL id is the key.
const MAX_PARENT_WALK_DEPTH = 8;
const TITLE_FALLBACK_LEN = 8;

// -- action: walk parentID chain to find the top-level session id + its title --
// opencode sessions form a tree (Task 0 Findings: a forked session has the
// parent's id as `parentID`). For per-session state storage we key by the
// TOP-LEVEL id so a fork doesn't fragment a single conversation across two
// board rows. Both pieces of metadata come from a single chain of
// client.session.get calls — at each step we read the current session, and if
// it has a parentID we step to the parent; the LAST session we land on (no
// parentID) is the top-level, and we read its title from the same response.
// Defensive guards:
//   - try/catch around every get: client.session.get throws on 4xx (verified
//     against the SDK), e.g. unknown id (session deleted between event and
//     handler). Returning null here lets the event handler SKIP the
//     transition cleanly — per Task 0 Findings "unresolvable" handling is
//     Task 4's degrade path. We do NOT write a record without a resolved id,
//     because the v2 shape has no file-level row to flip and a synthetic
//     session key would be meaningless.
//   - depth cap (MAX_PARENT_WALK_DEPTH above): see its declaration comment.
//   - empty `data` (server returned 200 with no body): treat as unresolvable.
async function resolveTopLevelSession(client, sessionID, directory) {
  if (!sessionID) return null;          // callers must check before enqueueing
  try {
    let id = sessionID;
    for (let depth = 0; depth < MAX_PARENT_WALK_DEPTH; depth++) {
      const resp = await client.session.get({ path: { id }, query: { directory } });
      const data = resp?.data;
      if (!data) return null;            // missing body — treat as unresolvable
      if (!data.parentID) return { id, title: data.title || null };
      id = data.parentID;
    }
    // Cap hit: assume current id is already top-level (defensive best-effort).
    return { id, title: null };
  } catch {
    return null;
  }
}

// -- action: drive the live TUI to a specific session (Task 4: select-on-mailbox) --
// CRITICAL Implementation Detail (Task 0 Findings, decided with user 2026-07-27):
// The working public call to switch the live TUI to another session is `client.
// tui.selectSession({sessionID})` — but that method is ONLY on the v2 SDK client.
// opencode 1.18.3..1.18.7 (and the plugin loader that ships with them) hands plugins
// the v1 client, whose `Tui` class has no `selectSession` method. Verified live:
// v1 client.tui is a `Tui` instance exposing only `appendPrompt`/`executeCommand` and
// holds the SDK's underlying HeyApiClient at the PRIVATE `_client` field. The
// working call exposed by that private client is the HeyApi shorthand:
//     client.tui._client.post({ url: '/tui/select-session', body: { sessionID } })
// Verified live against the running TUI (target session switched, response shape
// `{"data":true}` with the SDK envelope). Failure modes (rejection, no truthy
// `.data`) collapse to `false` here; the action layer treats a truthy `.data` as
// success. When a future `@opencode-ai/plugin` release ships a public
// `selectSession` on the v1 Tui, this call should be replaced — it is **not** a
// workaround to silently ship around: the privacy is why this comment exists.
// Defensive: ANY thrown exception is a failure too. A thrown network error MUST
// not crash the poll loop — it's fire-and-forget inside an interval callback.
async function selectSessionOnTUI(client, sessionID) {
  if (!sessionID) return false;
  try {
    const resp = await client.tui._client.post({
      url: '/tui/select-session',
      body: { sessionID },
    });
    return resp?.data === true;
  } catch {
    return false;
  }
}

export const AgentFleetSensorPlugin = async ({ directory, $, client }) => {
  const repo = repoNameFromCwd(directory);         // display label only
  const key = stateKeyForProcess(directory, process.pid);   // per-process identity key
  const statePath = statePathFor(key);
  const viewedPath = viewedPathFor(key);
  const selectPath = selectPathFor(key);
  // session is recorded best-effort from the zellij env of the opencode process.
  // It is NOT assumed equal to repo — the board/jump join on cwd, not session name.
  const session = process.env.ZELLIJ_SESSION_NAME ?? null;

  // -- action: select-mailbox poll loop (Task 4) --
  // Polls `<key>.select` for jump.sh (Task 5) to deposit a `{sessionID}` request that
  // drives the live TUI to another session. ~400ms is the floor the docs/git history
  // normalized on (see Data Model > atomic-write invariant note: "~400ms poll").
  // Uses setInterval at the PROCESS lifetime — opencode plugins live as long as the
  // opencode server, so the interval keeps ticking for the rest of that server's
  // run and there is no teardown signal to hook here. The plugin factory does not
  // block on the interval: the async work is contained inside pollSelectMailbox,
  // which itself never throws (every leaf action swallows). We also `.catch(()=>{})`
  // the interval callback so an unexpected throw still surfaces nothing — leaving a
  // dangling unhandled rejection in the long-running server would be visible noise.
  //
  // CRITICAL: the poll tick is pushed through the same per-key enqueue() chain as
  // transitionForTopLevelSession / chatMessageMarkWorkingAndViewed. The TUI call
  // (_client.post via selectSessionOnTUI) is async and can outlive several hundred
  // ms — without the chain, a poll that successfully wrote viewed.json via
  // mergeViewed could clobber a concurrent transition's state.json write (or vice
  // versa) in a read-modify-write race on the same process. Wrapping in enqueue()
  // guarantees FIFO ordering against all other writers for the same (cwd,pid).
  // Stale ticks naturally coalesce: once one poll deletes the mailbox, the next
  // enqueued tick reads null and short-circuits — the chain self-throttles.
  const POLL_INTERVAL_MS = 400;
  setInterval(() => {
    enqueue(key, () => pollSelectMailbox(client, { selectPath, viewedPath, statePath })).catch(() => {});
  }, POLL_INTERVAL_MS);

  // -- action: read-modify-write the v2 record for one top-level session --
  // Serialized via enqueue() — the per-key promise chain guarantees two
  // simultaneous transition() calls for the same (cwd,pid) observe each
  // other's writes. Resolves the event's sessionID to the top-level session
  // id (one network round-trip per parent-walk step). On resolution failure
  // (deleted session, no sessionID, server error) it skips the write
  // entirely — a v2 record has no file-level row, and a synthetic key would
  // have no meaning downstream.
  // Returns the ts that was stamped onto the entry (or null when the plan was
  // dropped, e.g. an idle tick blocked by idleShouldWriteDone). The chat.message
  // wrapper reads .ts to pin the viewed mark to the just-written entry — a
  // same-state repeat reuses the existing ts, which is intentional (no re-arm).
  async function transitionForTopLevelSession(topLevel, { state, reason }) {
    const existing = readExistingState(statePath);
    const prevEntry = existing?.sessions?.[topLevel.id];
    const plan = planTransition(prevEntry, state, reason, Date.now());
    if (!plan.write) return null;
    const entry = buildSessionEntry({
      state,
      reason,
      previousTask: prevEntry?.task ?? null,
      ts: plan.ts,
      title: topLevel.title ?? topLevel.id.slice(0, TITLE_FALLBACK_LEN),
    });
    const nextRecord = buildV2StateRecord({
      repo,
      cwd: directory,
      session,
      pid: process.pid,
      sessions: { ...(existing?.sessions ?? {}), [topLevel.id]: entry },
    });
    writeStateRecord(statePath, nextRecord);
    reapLegacyV1(directory);          // idempotent — see reapLegacyV1's header
    if (plan.notify) {
      const message = notificationMessage({
        repo,
        zellijSession: session,
        chatTitle: entry.title,
        state,
        reason,
      });
      // fire-and-forget: NOT awaited, so a hung/slow aerospace or osascript can never
      // stall the permission.ask hook (which opencode awaits). See notify().
      notify($, repo, message, notificationSoundForState(state, process.env));
    }
    return { ts: plan.ts };
  }

  // Single entry-point used by event handlers: resolves the event's ID,
  // chains the read-modify-write on the per-key promise chain, and swallows
  // resolution failures silently (skips the transition).
  async function transitionFromEventId(eventSessionID, fields) {
    if (!eventSessionID) return;       // events without sessionID are a no-op
    const resolved = await resolveTopLevelSession(client, eventSessionID, directory);
    if (!resolved) return;             // unresolvable: degraded handling is Task 4
    if (fields.state === 'done' && eventSessionID !== resolved.id) return;
    await enqueue(key, () => transitionForTopLevelSession(resolved, fields));
  }

  // chat.message is the ONLY transition path that ALSO marks viewed, and the
  // mark must land inside the SAME enqueue() body as the state write — splitting
  // them would let a 2nd transition land between the working write and the
  // viewed mark, racing per-event ts vs viewedTs and silently dropping a fresh
  // surface event underneath a stale viewedTs. "Safe" here means the same
  // resolveTopLevelSession contract as transitionFromEventId: no ID, no
  // resolution, no synthetic top-level id — in either failure mode BOTH the
  // working transition AND the viewed mark are skipped. We never write a
  // synthetic / file-level working state.
  async function chatMessageMarkWorkingAndViewed(eventSessionID) {
    if (!eventSessionID) return;
    const resolved = await resolveTopLevelSession(client, eventSessionID, directory);
    if (!resolved) return;
    await enqueue(key, () => {
      const stamped = transitionForTopLevelSession(resolved, { state: 'working', reason: null });
      if (stamped) mergeViewed(viewedPath, resolved.id, stamped.ts);
    });
  }

  return {
    event: async ({ event } = {}) => {
      if (!event) return;
      const sessionID = event?.properties?.sessionID;
      if (event.type === 'session.error') {
        if (!sessionID) return;        // session.error may have no sessionID — skip rather than fabricate
        await transitionFromEventId(sessionID, { state: 'needs-attention', reason: 'error' });
      }
      if (event.type === 'session.idle') {
        await transitionFromEventId(sessionID, { state: 'done', reason: null });
      }
      if (event.type === 'permission.replied') {
        await transitionFromEventId(sessionID, { state: 'working', reason: null });
      }
      // NOT the 'permission.ask' hook key (see below): opencode 1.18 declares it in
      // @opencode-ai/plugin's Hooks type but never invokes it — verified live against a
      // real Desktop-access prompt: the dedicated hook never fired while the prompt sat
      // on screen, and only the generic `event` dispatcher saw the permission lifecycle,
      // as `permission.asked` / `permission.replied` EVENT TYPES (not hook keys). Board
      // stayed yellow/"working" through an entire live permission prompt as a result —
      // the exact bug this fixes.
      if (event.type === 'permission.asked') {
        await transitionFromEventId(sessionID, { state: 'needs-attention', reason: 'permission' });
      }
      // The `question` tool (interactive multi-choice prompt) blocks the agent exactly
      // like a permission prompt: opencode awaits the human's answer before the turn
      // can continue. Same event-dispatcher pattern as permission.asked/replied above —
      // verified present as event types (`strings` on the binary shows
      // question.asked/replied/rejected; no dedicated plugin hook exists for it, same
      // as permission). Board must go red for ANY blocking-on-human condition, not
      // just permission — this is that broader rule's second instance.
      if (event.type === 'question.asked') {
        await transitionFromEventId(sessionID, { state: 'needs-attention', reason: 'question' });
      }
      // .rejected (user dismissed without answering) still resolves the block — the
      // agent is no longer waiting, so it must clear needs-attention same as .replied.
      if (event.type === 'question.replied' || event.type === 'question.rejected') {
        await transitionFromEventId(sessionID, { state: 'working', reason: null });
      }
    },

    // `chat.message` carries sessionID on its `input` argument (verified against
    // @opencode-ai/plugin 1.18 types: input.sessionID: string). Per Task 0
    // Findings, this is the "resolvable" case — direct sessionID, no
    // parent-walk needed but resolveTopLevelSession still handles the fork
    // case uniformly. The transition preserves the v1 behavior verified
    // before Task 3 (sensor v1 line ~177): a chat.message marks the agent
    // `working`. Task 4 extends that single transition with a viewed mark —
    // see chatMessageMarkWorkingAndViewed's header for the race-avoidance
    // rationale (both writes in one enqueue()).
    'chat.message': async ({ sessionID } = {}) => {
      await chatMessageMarkWorkingAndViewed(sessionID);
    },
  };
};

export default AgentFleetSensorPlugin;
