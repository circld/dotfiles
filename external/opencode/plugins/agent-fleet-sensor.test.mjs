// external/opencode/plugins/agent-fleet-sensor.test.mjs
// Run: node external/opencode/plugins/agent-fleet-sensor.test.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
// Helpers live in agent-fleet-sensor-core.mjs (not ./agent-fleet-sensor.js):
// opencode treats each named export of a plugin module as a separate plugin
// factory and invokes it; exposing these pure helpers from sensor.js would
// break plugin loading. See the core module's header for the full rationale.
import {
  buildSessionEntry,
  buildV2StateRecord,
  idleShouldWriteDone,
  isSuppressed,
  stateRank,
  planSelect,
  planTransition,
  repoNameFromCwd,
  stateKeyForProcess,
  stateKeyFromCwd,
  escapeAppleScriptString,
  isRepoVisible,
  notificationMessage,
  notificationScript,
  notificationSoundForState,
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

// ranking used by model/jump: needs-attention outranks done; other states are not actionable.
assert.equal(stateRank('needs-attention'), 1);
assert.equal(stateRank('done'), 0);
assert.equal(stateRank('working'), null);

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
// Task 1: envelope carries the selection cursor at file level so a process restart
// preserves "which session is currently focused" without depending on a session event.
assert.deepEqual(
  buildV2StateRecord({ repo: 'r', cwd: '/x', session: 's', pid: 7,
                       selectedSid: 'ses_1', selectedTs: NOW,
                       sessions: { ses_1: { state: 'done', reason: null, task: null,
                                           ts: NOW, title: 't' } } }),
  { repo: 'r', cwd: '/x', session: 's', pid: 7,
    selectedSid: 'ses_1', selectedTs: NOW,
    sessions: { ses_1: { state: 'done', reason: null, task: null, ts: NOW, title: 't' } } });
// null session -> recorded as null (NOT omitted) so downstream readers see the field
// is intentionally empty rather than missing. Matches buildSessionEntry's coalescing.
assert.equal(
  buildV2StateRecord({ repo: 'r', cwd: '/x', session: null, pid: 7, sessions: {} }).session,
  null);
// Task 1: a later transition rebuilds the envelope with existing selectedSid/selectedTs
// threaded through — the helper does NOT zero them out, so a transition can never erase
// the cursor with a fresh null.
const existingCursor = { selectedSid: 'ses_1', selectedTs: NOW - 5 };
const rebuilt = buildV2StateRecord({
  repo: 'r', cwd: '/x', session: 's', pid: 7,
  selectedSid: existingCursor.selectedSid,
  selectedTs: existingCursor.selectedTs,
  sessions: { ses_1: { state: 'working', reason: null, task: null, ts: NOW, title: 't' } },
});
assert.equal(rebuilt.selectedSid, 'ses_1');
assert.equal(rebuilt.selectedTs, NOW - 5);

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

// notification target uses useful granularity: zellij session -> chat session.
assert.equal(
  notificationMessage({ repo: 'dotfiles', zellijSession: 'agents', chatTitle: 'write plan', state: 'needs-attention', reason: 'question' }),
  'agents / write plan needs attention (question)');
assert.equal(
  notificationMessage({ repo: 'dotfiles', zellijSession: 'agents', chatTitle: 'write plan', state: 'done', reason: null }),
  'agents / write plan is done and ready');
// fallback: no zellij session or chat title still gives a stable, non-empty target.
assert.equal(
  notificationMessage({ repo: 'dotfiles', zellijSession: null, chatTitle: null, state: 'done', reason: null }),
  'dotfiles is done and ready');

// sound config: explicit env vars only; empty string means no sound.
assert.equal(notificationSoundForState('needs-attention', { AGENT_FLEET_SOUND_BLOCKING: 'Glass' }), 'Glass');
assert.equal(notificationSoundForState('done', { AGENT_FLEET_SOUND_DONE: 'Ping' }), 'Ping');
assert.equal(notificationSoundForState('done', { AGENT_FLEET_SOUND_DONE: '' }), null);
assert.equal(notificationSoundForState('working', { AGENT_FLEET_SOUND_DONE: 'Ping' }), null);
assert.equal(
  notificationScript('agents / write plan is done and ready', 'Glass'),
  'display notification "agents / write plan is done and ready" with title "opencode" sound name "Glass"');
assert.equal(
  notificationScript('agents / write plan is done and ready', null),
  'display notification "agents / write plan is done and ready" with title "opencode"');

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

// --- markOnly mailbox verb (Task 6) ---
// markOnly=true with a sessionID: skip the TUI call entirely. The mark-only
// mailbox verb is for board dismiss (Task 10 client): the user has already
// SEEN the row on the board, the request says "mark it viewed and stop
// re-surfacing it" — no live TUI switch, no selectedSid/selectedTs
// persistence, NO cursor write. selectOk is irrelevant here (the markOnly
// branch short-circuits before the strict-===true check).
assert.deepEqual(
  planSelect({ sessionID: 'ses_abc', markOnly: true }, false),
  { markViewed: true, deleteMailbox: true });
// markOnly=true WITHOUT a sessionID: the malformed guard (no sessionID)
// still fires FIRST, so the result is the same null-mailbox contract:
// delete the mailbox, never claim viewed. Keeps the no-sessionID edge as
// the wedge-prevention guarantee even on this new verb.
assert.deepEqual(
  planSelect({ markOnly: true }, false),
  { markViewed: false, deleteMailbox: true });

// Task 6 (mark-only mailbox verb): a mark-only mailbox with a sessionID
// marks the session viewed (entry-pinned ts from the state file) and
// deletes the mailbox WITHOUT posting to the live TUI and WITHOUT
// persisting a selection cursor. Board dismiss path — the user already saw
// the row on the board, so no jump is needed.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-markonly-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-markonly-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      const viewedPath = path.join(stateDir, key + '.viewed.json');
      const selectPath = path.join(stateDir, key + '.select');
      // pre-existing state: ses_hidden needs-attention at entryTs=123,
      // cursor null. Poll + markOnly must NOT change the cursor.
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-markonly-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: null, selectedTs: null,
        sessions: { ses_hidden: { state: 'needs-attention', reason: 'question',
                                  task: null, ts: 123, title: 'hidden' } },
      }));
      writeFileSync(selectPath, JSON.stringify({ sessionID: 'ses_hidden', markOnly: true }));
      const calls = [];
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async ({ body }) => { calls.push(body.sessionID); return { data: true }; } } },
          session: {
            list: async () => ({ data: [] }),
            get: async ({ path: { id } }) => ({ data: { id, parentID: null, title: id } }),
          },
        },
      });
      await new Promise((resolve) => setTimeout(resolve, 900));
      // markOnly path must NEVER call the live TUI — no jump, no switch.
      if (calls.length !== 0) throw new Error('tui post called on markOnly: ' + JSON.stringify(calls));
      // viewed.json got the entry-pinned ts for ses_hidden (= 123).
      if (!existsSync(viewedPath)) throw new Error('viewed.json not written on markOnly');
      const viewed = JSON.parse(readFileSync(viewedPath, 'utf8'));
      if (viewed.ses_hidden !== 123) throw new Error('viewed mark wrong on markOnly: ' + JSON.stringify(viewed));
      // mailbox is gone — no wedge.
      if (existsSync(selectPath)) throw new Error('.select not deleted on markOnly');
      // cursor UNCHANGED — markOnly is not a "switched to this session" event.
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      if (record.selectedSid !== null) throw new Error('selectedSid changed on markOnly: ' + record.selectedSid);
      if (record.selectedTs !== null) throw new Error('selectedTs changed on markOnly: ' + record.selectedTs);
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Regression: plugin poll must consume the .select mailbox with paths scoped to
// the plugin instance. A prior module-scoped poll referenced factory-local vars
// directly, threw ReferenceError every tick, and silently left .select unread.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-select-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-select-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      writeFileSync(path.join(stateDir, key + '.json'), JSON.stringify({
        repo: 'agent-fleet-select-repo', cwd: directory, session: null, pid: process.pid,
        sessions: { ses_hidden: { state: 'needs-attention', reason: 'question', ts: 123, title: 'hidden' } },
      }));
      writeFileSync(path.join(stateDir, key + '.select'), JSON.stringify({ sessionID: 'ses_hidden' }));
      const calls = [];
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: { tui: { _client: { post: async ({ body }) => { calls.push(body.sessionID); return { data: true }; } } } },
      });
      await new Promise((resolve) => setTimeout(resolve, 900));
      const viewedPath = path.join(stateDir, key + '.viewed.json');
      if (calls[0] !== 'ses_hidden') throw new Error('select not posted: ' + JSON.stringify(calls));
      if (existsSync(path.join(stateDir, key + '.select'))) throw new Error('.select not deleted');
      if (JSON.parse(readFileSync(viewedPath, 'utf8')).ses_hidden !== 123) throw new Error('viewed not written');
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Regression: a subagent/child session.idle must not mark the resolved top-level
// session done. The parent can still stream output after the child idles; only the
// top-level session's own idle event is the real "turn ended" signal.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-child-idle-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-child-idle-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-child-idle-repo', cwd: directory, session: null, pid: process.pid,
        sessions: { parent: { state: 'working', reason: null, ts: 100, title: 'parent' } },
      }));
      const hooks = await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async () => ({ data: false }) } },
          session: { get: async ({ path: { id } }) => ({ data: id === 'child'
            ? { id: 'child', parentID: 'parent', title: 'child' }
            : { id: 'parent', parentID: null, title: 'parent' } }) },
        },
      });
      await hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'child' } } });
      const entry = JSON.parse(readFileSync(statePath, 'utf8')).sessions.parent;
      if (entry.state !== 'working') throw new Error('child idle wrote parent state: ' + JSON.stringify(entry));
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Task 1 (restart-safe): plugin startup (deferred, un-awaited) calls client.session.list
// with the instance's directory, seeds every TOP-LEVEL session as `unknown / sensor
// restarted` (skipping any row carrying a `parentID`), and preserves entries already on
// disk — a seed must NEVER clobber an event-derived transition that landed first.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-seed-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-seed-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      // pre-existing event-derived entry must survive the seed untouched.
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-seed-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: null, selectedTs: null,
        sessions: { ses_existing: { state: 'working', reason: null, task: null, ts: 100, title: 'existing' } },
      }));
      let listCalled = false;
      let listDirectory = null;
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async () => ({ data: false }) } },
          session: {
            list: async ({ query }) => { listCalled = true; listDirectory = query?.directory; return { data: [
              { id: 'ses_top1', title: 'Top 1', parentID: null },
              { id: 'ses_child', title: 'Child', parentID: 'ses_top1' },
              { id: 'ses_top2' },
            ] }; },
            get: async () => ({ data: null }),
          },
        },
      });
      // flavor: a 'seed started' stderr line is OK (informational), but unhandled rejections are not.
      // flush the deferred seed (runs on a microtask / next tick after factory returns).
      await new Promise((resolve) => setTimeout(resolve, 0));
      if (!listCalled) throw new Error('client.session.list not called');
      if (listDirectory !== directory) throw new Error('list called with wrong directory: ' + listDirectory);
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      // existing entry preserved untouched (state, ts, title).
      const existing = record.sessions.ses_existing;
      if (!existing || existing.state !== 'working' || existing.ts !== 100 || existing.title !== 'existing')
        throw new Error('existing entry clobbered: ' + JSON.stringify(existing));
      // child session with parentID MUST be skipped — no synthetic key.
      if (record.sessions.ses_child) throw new Error('child session seeded: ' + JSON.stringify(record.sessions.ses_child));
      // top-level sessions seeded as unknown / sensor restarted / one shared ts.
      const top1 = record.sessions.ses_top1;
      if (!top1 || top1.state !== 'unknown' || top1.reason !== 'sensor restarted' || top1.title !== 'Top 1')
        throw new Error('ses_top1 wrong: ' + JSON.stringify(top1));
      const top2 = record.sessions.ses_top2;
      if (!top2) throw new Error('ses_top2 not seeded');
      if (top2.state !== 'unknown' || top2.reason !== 'sensor restarted')
        throw new Error('ses_top2 wrong: ' + JSON.stringify(top2));
      // title fallback: no title -> id.slice(0, TITLE_FALLBACK_LEN) where TITLE_FALLBACK_LEN === 8.
      if (top2.title !== 'ses_top2'.slice(0, 8))
        throw new Error('ses_top2 wrong title fallback: ' + top2.title);
      // shared action-layer timestamp: every seeded entry carries the SAME ts (one Date.now()).
      if (top1.ts !== top2.ts) throw new Error('seeded ts diverge: ' + JSON.stringify([top1.ts, top2.ts]));
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Task 1 (restart-safe): if client.session.list REJECTS, the failure is caught.
// The plugin still returns its hooks object normally AND existing state stays untouched —
// no partial write, no crash, no unhandled rejection.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-seed-fail-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-seed-fail-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-seed-fail-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: 'ses_prev', selectedTs: 999,
        sessions: { ses_prev: { state: 'working', reason: null, task: null, ts: 100, title: 'prev' } },
      }));
      let hooks;
      try {
        hooks = await plugin({
          directory,
          $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
          client: {
            tui: { _client: { post: async () => ({ data: false }) } },
            session: {
              list: async () => { throw new Error('list boom'); },
              get: async () => ({ data: null }),
            },
          },
        });
      } catch (err) {
        throw new Error('plugin threw on seed failure: ' + err);
      }
      if (!hooks || typeof hooks.event !== 'function') throw new Error('hooks not returned normally');
      // flush deferred seed so any unhandled rejection surfaces here, not as test hang.
      await new Promise((resolve) => setTimeout(resolve, 0));
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      const prevEntry = record.sessions.ses_prev;
      if (!prevEntry || prevEntry.ts !== 100 || prevEntry.state !== 'working' || prevEntry.title !== 'prev')
        throw new Error('existing entry clobbered despite seed fail: ' + JSON.stringify(prevEntry));
      if (record.selectedSid !== 'ses_prev' || record.selectedTs !== 999)
        throw new Error('cursor clobbered despite seed fail: ' + JSON.stringify({selectedSid: record.selectedSid, selectedTs: record.selectedTs}));
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Task 1 (restart-safe): successful mailbox select writes selectedSid + selectedTs
// (Date.now()) into the state file. This is the ONLY cursor writer — manual TUI
// switches emit no plugin event, so mailbox-consume is sole writer for the cursor.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-cursor-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-cursor-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      const viewedPath = statePath.replace('.json', '.viewed.json');
      const selectPath = statePath.replace('.json', '.select');
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-cursor-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: null, selectedTs: null,
        sessions: { ses_target: { state: 'needs-attention', reason: 'permission', task: null, ts: 500, title: 'target' } },
      }));
      writeFileSync(selectPath, JSON.stringify({ sessionID: 'ses_target' }));
      const beforeMs = Date.now();
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async () => ({ data: true }) } },
          session: {
            list: async () => ({ data: [] }),
            get: async ({ path: { id } }) => ({ data: { id, parentID: null, title: id } }),
          },
        },
      });
      // 400ms poll + buffer for the deferred seed to flush.
      await new Promise((resolve) => setTimeout(resolve, 900));
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      if (record.selectedSid !== 'ses_target') throw new Error('selectedSid not written: ' + record.selectedSid);
      // selectedTs is a wall-clock-ish Date.now(), NOT the entry's ts of 500.
      if (typeof record.selectedTs !== 'number' || record.selectedTs <= 0)
        throw new Error('selectedTs not written: ' + record.selectedTs);
      if (record.selectedTs === 500 || record.selectedTs < beforeMs - 5000)
        throw new Error('selectedTs not derived from Date.now(): ' + record.selectedTs);
      if (!existsSync(viewedPath)) throw new Error('viewed.json not written on successful jump');
      if (JSON.parse(readFileSync(viewedPath, 'utf8')).ses_target !== 500)
        throw new Error('viewed mark wrong: ' + readFileSync(viewedPath, 'utf8'));
      if (existsSync(selectPath)) throw new Error('.select not deleted on successful jump');
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Task 1 (restart-safe): a FAILED mailbox select must NOT change the cursor.
// The mailbox deletes (no wedge), but selectedSid/selectedTs stay at whatever they
// were before the poll — a failed jump didn't put the user on the target session.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-cursor-fail-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-cursor-fail-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      const selectPath = statePath.replace('.json', '.select');
      const viewedPath = statePath.replace('.json', '.viewed.json');
      // pre-existing cursor: poll must NOT change it.
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-cursor-fail-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: 'ses_prev', selectedTs: 777,
        sessions: { ses_prev: { state: 'done', reason: null, task: null, ts: 100, title: 'prev' },
                    ses_target: { state: 'needs-attention', reason: 'permission', task: null, ts: 200, title: 'target' } },
      }));
      writeFileSync(selectPath, JSON.stringify({ sessionID: 'ses_target' }));
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async () => ({ data: false }) } },
          session: {
            list: async () => ({ data: [] }),
            get: async ({ path: { id } }) => ({ data: { id, parentID: null, title: id } }),
          },
        },
      });
      await new Promise((resolve) => setTimeout(resolve, 900));
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      if (record.selectedSid !== 'ses_prev') throw new Error('selectedSid changed on failed select: ' + record.selectedSid);
      if (record.selectedTs !== 777) throw new Error('selectedTs changed on failed select: ' + record.selectedTs);
      // viewed.json entry for ses_target MUST NOT exist on a failed jump.
      if (existsSync(viewedPath)) {
        const viewed = JSON.parse(readFileSync(viewedPath, 'utf8'));
        if (viewed.ses_target != null) throw new Error('viewed written despite failed jump: ' + JSON.stringify(viewed));
      }
      // mailbox still deleted so we don't wedge.
      if (existsSync(selectPath)) throw new Error('.select not deleted on failed jump');
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Task 1 (restart-safe): an unknown/deleted session id in the mailbox (TUI post
// returns false) skips BOTH viewed AND cursor writes. No sid resolution lives in
// the mailbox path — the model's mailbox sids are already top-level, and selectOk
// short-circuits the writes inside the same enqueue body. Verify nothing leaks.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-unknown-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-unknown-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      const selectPath = statePath.replace('.json', '.select');
      const viewedPath = statePath.replace('.json', '.viewed.json');
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-unknown-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: 'ses_prev', selectedTs: 777,
        sessions: { ses_prev: { state: 'done', reason: null, task: null, ts: 100, title: 'prev' } },
      }));
      // TUI post returns false specifically for ses_unknown (the deleted-session case).
      writeFileSync(selectPath, JSON.stringify({ sessionID: 'ses_unknown' }));
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async ({ body }) => ({ data: body.sessionID === 'ses_unknown' ? false : true }) } },
          session: {
            list: async () => ({ data: [] }),
            get: async ({ path: { id } }) => ({ data: id === 'ses_unknown' ? null : { id, parentID: null, title: id } }),
          },
        },
      });
      await new Promise((resolve) => setTimeout(resolve, 900));
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      if (record.selectedSid !== 'ses_prev') throw new Error('selectedSid changed on unknown sid: ' + record.selectedSid);
      if (record.selectedTs !== 777) throw new Error('selectedTs changed on unknown sid: ' + record.selectedTs);
      // NO viewed.json entry for the unknown sid (planSelect.markViewed === false on selectOk === false).
      if (existsSync(viewedPath)) {
        const viewed = JSON.parse(readFileSync(viewedPath, 'utf8'));
        if (viewed.ses_unknown != null) throw new Error('viewed written for unknown sid: ' + JSON.stringify(viewed));
      }
      if (existsSync(selectPath)) throw new Error('.select not deleted for unknown sid');
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 3000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// Task 1 (restart-safe): a slow session.list landing AFTER a mailbox-consume cursor
// persist must NOT erase the just-persisted selectedSid/selectedTs. session.list latency
// can exceed the 400ms mailbox poll, so the seed's envelope rebuild has to thread the
// existing cursor through — the whitelist-rebuild caveat (Step 6) lives on this rule.
{
  const home = mkdtempSync(path.join(os.tmpdir(), 'agent-fleet-defer-'));
  try {
    const script = String.raw`
      import plugin from ${JSON.stringify(new URL('./agent-fleet-sensor.js', import.meta.url).href)};
      import { stateKeyForProcess } from ${JSON.stringify(new URL('./agent-fleet-sensor-core.mjs', import.meta.url).href)};
      import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
      import path from 'node:path';
      const directory = '/tmp/agent-fleet-defer-repo';
      const key = stateKeyForProcess(directory, process.pid);
      const stateDir = path.join(process.env.HOME, '.local/state/agent-fleet');
      mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, key + '.json');
      const selectPath = path.join(stateDir, key + '.select');
      writeFileSync(statePath, JSON.stringify({
        repo: 'agent-fleet-defer-repo', cwd: directory, session: null, pid: process.pid,
        selectedSid: null, selectedTs: null,
        sessions: { ses_target: { state: 'needs-attention', reason: 'permission', task: null, ts: 500, title: 'target' } },
      }));
      writeFileSync(selectPath, JSON.stringify({ sessionID: 'ses_target' }));
      await plugin({
        directory,
        $: () => ({ quiet: () => ({ text: async () => '[]' }) }),
        client: {
          tui: { _client: { post: async () => ({ data: true }) } },
          session: {
            // slow list: resolves AFTER the 400ms mailbox poll cycles and persists the cursor.
            list: async () => { await new Promise((r) => setTimeout(r, 1200)); return { data: [
              { id: 'ses_new', title: 'New', parentID: null },
            ] }; },
            get: async ({ path: { id } }) => ({ data: { id, parentID: null, title: id } }),
          },
        },
      });
      // poll lands ~400-800ms in; deferred seed lands ~1200ms in; flush both writes.
      await new Promise((resolve) => setTimeout(resolve, 1700));
      const record = JSON.parse(readFileSync(statePath, 'utf8'));
      // cursor survived the deferred seed rebuild.
      if (record.selectedSid !== 'ses_target') throw new Error('cursor erased by deferred seed: ' + record.selectedSid);
      if (typeof record.selectedTs !== 'number' || record.selectedTs <= 0)
        throw new Error('cursor ts erased by deferred seed: ' + record.selectedTs);
      // deferred seed landed (otherwise this test is a no-op and a false positive).
      if (!record.sessions.ses_new || record.sessions.ses_new.state !== 'unknown' || record.sessions.ses_new.reason !== 'sensor restarted')
        throw new Error('deferred seed did not land: ' + JSON.stringify(record.sessions));
      // event-derived entry preserved through the seed.
      if (!record.sessions.ses_target || record.sessions.ses_target.state !== 'needs-attention')
        throw new Error('event-derived entry lost during seed: ' + JSON.stringify(record.sessions.ses_target));
      process.exit(0);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 5000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

console.log('PASS: sensor pure-logic unit checks');
