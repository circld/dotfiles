// external/opencode/plugins/agent-fleet-sensor.test.mjs
// Run: node external/opencode/plugins/agent-fleet-sensor.test.mjs
import assert from 'node:assert/strict';
// Helpers live in agent-fleet-sensor-core.mjs (not ./agent-fleet-sensor.js):
// opencode treats each named export of a plugin module as a separate plugin
// factory and invokes it; exposing these pure helpers from sensor.js would
// break plugin loading. See the core module's header for the full rationale.
import {
  buildSessionEntry,
  buildV2StateRecord,
  idleShouldWriteDone,
  isSuppressed,
  planSelect,
  planTransition,
  repoNameFromCwd,
  stateKeyForProcess,
  stateKeyFromCwd,
  escapeAppleScriptString,
  isRepoVisible,
} from './agent-fleet-sensor-core.mjs';

// Fixed "now" so ts-stamping assertions are deterministic. planTransition
// takes `now` as an argument (callers pass Date.now()); never use Date.now()
// inside the helpers themselves — see planTransition's comment.
const NOW = 1_700_000_000_000;

// idle must NOT clobber an unanswered needs-attention state (feedback #4)
assert.equal(idleShouldWriteDone({ state: 'needs-attention', reason: 'permission' }), false);
assert.equal(idleShouldWriteDone({ state: 'needs-attention', reason: 'error' }), false);
// idle IS allowed from working / done / fresh
assert.equal(idleShouldWriteDone({ state: 'working' }), true);
assert.equal(idleShouldWriteDone({ state: 'done' }), true);
assert.equal(idleShouldWriteDone(null), true);

// --- transition table (the core feature path, previously untested) ---
// permission.ask -> needs-attention, from a working agent: rising edge into
// red — write + notify + fresh ts (state changed: existing.ts not reused).
assert.deepEqual(
  planTransition({ state: 'working', ts: 100 }, 'needs-attention', 'permission', NOW),
  { write: true, notify: true, ts: NOW });
// session.error -> needs-attention, from working: rising edge into red
assert.deepEqual(
  planTransition({ state: 'working', ts: 100 }, 'needs-attention', 'error', NOW),
  { write: true, notify: true, ts: NOW });
// needs-attention -> needs-attention SAME reason (2nd prompt of the SAME kind
// while already red): write, NO re-notify, ts PRESERVED so a previously-viewed
// entry remains suppressed (no spurious re-arm to a fresh ts that would beat
// the user's stale viewedTs and surface a stale prompt as new).
assert.deepEqual(
  planTransition({ state: 'needs-attention', reason: 'permission', ts: 100 },
                 'needs-attention', 'permission', NOW),
  { write: true, notify: false, ts: 100 });
// needs-attention on a fresh agent (no existing record): write + notify + fresh ts
assert.deepEqual(
  planTransition(null, 'needs-attention', 'permission', NOW),
  { write: true, notify: true, ts: NOW });
// permission.replied -> working: state CHANGED, fresh ts
assert.deepEqual(
  planTransition({ state: 'needs-attention', reason: 'permission', ts: 100 },
                 'working', null, NOW),
  { write: true, notify: false, ts: NOW });
// chat.message -> working from done: state CHANGED, fresh ts
assert.deepEqual(
  planTransition({ state: 'done', ts: 100 }, 'working', null, NOW),
  { write: true, notify: false, ts: NOW });
// session.idle -> done from working: rising edge into green — write + notify + fresh ts
assert.deepEqual(
  planTransition({ state: 'working', ts: 100 }, 'done', null, NOW),
  { write: true, notify: true, ts: NOW });
// session.idle -> done while red (needs-attention): DROPPED — the per-session
// idle-does-not-clobber guard. write=false, notify=false, no ts key (the caller
// won't build a record when write=false, so no ts needs to be carried back).
// Verified against the historical bug: an unanswered permission prompt must
// not be overwritten by an idle tick arriving while the prompt is still on screen.
assert.deepEqual(
  planTransition({ state: 'needs-attention', reason: 'permission', ts: 100 },
                 'done', null, NOW),
  { write: false, notify: false });

// --- done-notify (green, "agent finished and ready for review") ---
// fresh agent (no existing record) going straight to done: write + notify + fresh ts
assert.deepEqual(
  planTransition(null, 'done', null, NOW),
  { write: true, notify: true, ts: NOW });
// done -> done (e.g. a second idle tick while already green) must not re-notify.
// ts is PRESERVED on this no-change repeat (state+reason both identical) so
// the existing row's age stands.
assert.deepEqual(
  planTransition({ state: 'done', reason: null, ts: 100 }, 'done', null, NOW),
  { write: true, notify: false, ts: 100 });

// question.asked -> needs-attention: same transition as permission.asked
// (board-red rule is "blocked on human", not "permission specifically").
assert.deepEqual(
  planTransition({ state: 'working', ts: 100 }, 'needs-attention', 'question', NOW),
  { write: true, notify: true, ts: NOW });
// 2nd question (same reason) while already red: write, NO re-notify, ts preserved.
assert.deepEqual(
  planTransition({ state: 'needs-attention', reason: 'question', ts: 100 },
                 'needs-attention', 'question', NOW),
  { write: true, notify: false, ts: 100 });
// question.replied / question.rejected -> working: state CHANGED, fresh ts
assert.deepEqual(
  planTransition({ state: 'needs-attention', reason: 'question', ts: 100 },
                 'working', null, NOW),
  { write: true, notify: false, ts: NOW });
// session.idle must not clobber a pending question either — same guard as permission
assert.equal(idleShouldWriteDone({ state: 'needs-attention', reason: 'question' }), false);

// --- reason-CHANGE re-arm (Task 2 new behavior) ---
// Same state ('needs-attention') but CHANGED reason (permission -> question).
// Must RE-ARM: fresh ts so the age advances past the user's stale viewedTs and
// isSuppressed no longer hides the new actionable event against the old entry.
// Without reason in the identity check, keying on state alone would keep the
// old (earlier) ts, the user's viewedTs (>= old ts) would still match, and
// isSuppressed would drop the new question.
assert.deepEqual(
  planTransition({ state: 'needs-attention', reason: 'permission', ts: 100 },
                 'needs-attention', 'question', NOW),
  { write: true, notify: false, ts: NOW });

// --- process identity key (per-PID, used by jump.sh to target a specific tmux pane) ---
// pid present => "<cwd-hash>-<pid>"
const procKey = stateKeyForProcess('/Users/x/dotfiles', 12345);
assert.equal(procKey, `${stateKeyFromCwd('/Users/x/dotfiles')}-12345`);
// pid absent => bare cwd-hash (NO trailing "-" dash). The fallback test is the
// critical one: a missing pid must NOT produce "hash-" because downstream
// scripts grep/match on the bare hash and would miss it.
assert.equal(stateKeyForProcess('/Users/x/dotfiles', null), stateKeyFromCwd('/Users/x/dotfiles'));
assert.equal(stateKeyForProcess('/Users/x/dotfiles', undefined), stateKeyFromCwd('/Users/x/dotfiles'));
// distinct pids on the same cwd produce distinct keys — that is the point of including the pid at all.
assert.notEqual(stateKeyForProcess('/x', 1), stateKeyForProcess('/x', 2));

// --- suppression (Task 2 new helper: isSuppressed state entryTs viewedTs) ---
// Suppression only applies to 'done' and 'needs-attention' (the terminal/blocked
// states). 'working' must NEVER be suppressed: a long-running agent's age
// advancing past the user's viewedTs is the normal case, not a suppression signal.
assert.equal(isSuppressed('working', 100, 200), false);
assert.equal(isSuppressed('working', 100, null), false);
// viewedTs >= entryTs on a done/needs-attention row: SUPPRESSED (user already saw it).
assert.equal(isSuppressed('done', 100, 100), true);
assert.equal(isSuppressed('done', 100, 500), true);
assert.equal(isSuppressed('needs-attention', 100, 500), true);
// viewedTs BEFORE entryTs (a newer event arrived since the user last viewed): NOT suppressed.
assert.equal(isSuppressed('done', 100, 50), false);
assert.equal(isSuppressed('needs-attention', 100, 50), false);
// never viewed (null viewedTs): NOT suppressed — the default for freshly-seen rows.
assert.equal(isSuppressed('done', 100, null), false);
assert.equal(isSuppressed('needs-attention', 100, null), false);

// --- buildSessionEntry: ts is INPUT (no Date.now inside the helper), and the v2
//     per-session slot is the actually-used shape downstream (Tasks 5/6). Locks
//     the `previousTask -> task` field rename + null-coalescing for reason/task/title. ---
assert.deepEqual(
  buildSessionEntry({ state: 'working', reason: null, previousTask: null, ts: NOW, title: null }),
  { state: 'working', reason: null, task: null, ts: NOW, title: null });
// missing ts => ts becomes undefined (must NOT silently fall back to Date.now()).
const noTs = buildSessionEntry({ state: 'done', reason: null, previousTask: null });
assert.equal(noTs.ts, undefined);
// previousTask passes through to the `task` field on the record (unchanged shape);
// null reason/title coalesces to null (rather than `undefined` leaking onto disk).
assert.deepEqual(
  buildSessionEntry({ state: 'working', reason: 'permission', previousTask: 'do the thing',
                      ts: NOW, title: undefined }),
  { state: 'working', reason: 'permission', task: 'do the thing', ts: NOW, title: null });

// --- buildV2StateRecord: envelope assembles file-level identity around a per-session map ---
assert.deepEqual(
  buildV2StateRecord({ repo: 'r', cwd: '/x', session: 's', pid: 7,
                       sessions: { ses_1: { state: 'done', reason: null, task: null,
                                           ts: NOW, title: 't' } } }),
  { repo: 'r', cwd: '/x', session: 's', pid: 7,
    sessions: { ses_1: { state: 'done', reason: null, task: null, ts: NOW, title: 't' } } });
// null session -> recorded as null (NOT omitted) so downstream readers see the field
// is intentionally empty rather than missing. Matches buildSessionEntry's coalescing.
assert.equal(
  buildV2StateRecord({ repo: 'r', cwd: '/x', session: null, pid: 7, sessions: {} }).session,
  null);

// identity key is a sha256 prefix of the absolute cwd, distinct + collision-proof
// (the old "/" -> "_" scheme collided: "/a_b" and "/a/b" both -> "a_b")
const main = stateKeyFromCwd('/Users/x/dotfiles');
const wt = stateKeyFromCwd('/Users/x/dotfiles/.worktrees/agent-fleet-awareness');
assert.notEqual(main, wt);
assert.ok(!main.includes('/'));
// the exact collision the char-substitution scheme produced must NOT recur
assert.notEqual(stateKeyFromCwd('/a_b'), stateKeyFromCwd('/a/b'));

// repo LABEL disambiguates same-named worktrees from different repos (the board wart)
assert.equal(repoNameFromCwd('/Users/x/octane'), 'octane');            // plain repo
assert.equal(repoNameFromCwd('/Users/x/octane/.worktrees/feat'), 'octane:feat');
assert.equal(repoNameFromCwd('/Users/x/dotfiles/.worktrees/feat'), 'dotfiles:feat');
// two same-named worktrees must render as DISTINCT labels
assert.notEqual(
  repoNameFromCwd('/Users/x/octane/.worktrees/feat'),
  repoNameFromCwd('/Users/x/dotfiles/.worktrees/feat'));
// edge: trailing slash still resolves the worktree label
assert.equal(repoNameFromCwd('/Users/x/octane/.worktrees/feat/'), 'octane:feat');

// AppleScript injection guard: a `"` in the repo name must not break out of the
// string literal (a `foo" & (do shell script "...") & "bar` name would run shell).
// Escape backslash first, then quote, so the value stays inert data.
assert.equal(escapeAppleScriptString('plain'), 'plain');
assert.equal(escapeAppleScriptString('a"b'), 'a\\"b');
assert.equal(escapeAppleScriptString('a\\b'), 'a\\\\b');
// the exploit payload must contain NO unescaped quote after escaping
assert.ok(!/(^|[^\\])"/.test(escapeAppleScriptString('foo" & (do shell script "x") & "bar')));

// visibility gate: skip notify when the repo's window is already frontmost.
// opencode writes window titles as "<repo> | OC | <chat title>" — prefix match on that.
assert.equal(isRepoVisible('dotfiles | OC | some chat title', 'dotfiles'), true);
assert.equal(isRepoVisible('octane | OC | some chat title', 'dotfiles'), false);
// fail OPEN to "not visible" (i.e. still notify) when aerospace gave nothing usable —
// a broken visibility check must never silently swallow a real attention-needed signal.
assert.equal(isRepoVisible(null, 'dotfiles'), false);
assert.equal(isRepoVisible('', 'dotfiles'), false);
// a title that merely CONTAINS the repo name (not as the prefix) must not match —
// avoids a chat-title substring accidentally suppressing a different repo's notify.
assert.equal(isRepoVisible('other-repo | OC | mentions dotfiles in passing', 'dotfiles'), false);

// --- mailbox decision (Task 4) ---
// select call succeeded on a well-formed mailbox: BOTH mark viewed AND delete mailbox.
// The "delete always" half is the wedge-prevention rule (a malformed mailbox must not stick
// around forever); the "mark viewed" half is what makes jump actually suppress the row on
// the next render (isSuppressed checks viewedTs >= entryTs on done/needs-attention).
assert.deepEqual(
  planSelect({ sessionID: 'ses_abc' }, true),
  { markViewed: true, deleteMailbox: true });
// select call failed (TUI post threw, or returned non-truthy .data): still DELETE the
// mailbox so we don't fail-then-retry forever, but do NOT claim the user has seen
// the row — a failed jump means nothing was actually viewed.
assert.deepEqual(
  planSelect({ sessionID: 'ses_abc' }, false),
  { markViewed: false, deleteMailbox: true });
// malformed mailbox (read returned null from missing/partial JSON): delete to clear
// whatever wedge was on disk, never crash, never mark viewed (no sessionID to act on).
// selectOk is irrelevant when mailbox is null — purity contract: short-circuit.
assert.deepEqual(
  planSelect(null, true),
  { markViewed: false, deleteMailbox: true });
assert.deepEqual(
  planSelect(null, false),
  { markViewed: false, deleteMailbox: true });
// Edge: mailbox parsed but sessionID is empty string. Defense-in-depth — sensor.js ALSO
// short-circuits this case before reaching planSelect (`sessionID ? mailbox : null`),
// but the helper must reject it on its own so a future caller cannot produce
// markViewed:true against a junk sessionID. selectOk is irrelevant — no sessionID,
// no action.
assert.deepEqual(
  planSelect({ sessionID: '' }, true),
  { markViewed: false, deleteMailbox: true });
assert.deepEqual(
  planSelect({ sessionID: '' }, false),
  { markViewed: false, deleteMailbox: true });
// Edge: selectOk is a non-boolean truthy value. The contract is strict `=== true` —
// the TUI call returns a boolean, and we deliberately don't accept truthy coercion
// (e.g. `1`, `'true'`) so a future change to selectSessionOnTUI's return type cannot
// silently upgrade a non-boolean truthy to "claimed a successful jump". markViewed
// must be exactly true iff selectOk is exactly the boolean true.
assert.deepEqual(
  planSelect({ sessionID: 'ses_abc' }, 1),
  { markViewed: false, deleteMailbox: true });
assert.deepEqual(
  planSelect({ sessionID: 'ses_abc' }, 'true'),
  { markViewed: false, deleteMailbox: true });

console.log('PASS: sensor pure-logic unit checks');
