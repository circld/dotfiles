// external/opencode/plugins/agent-fleet-sensor.test.mjs
// Run: node external/opencode/plugins/agent-fleet-sensor.test.mjs
import assert from 'node:assert/strict';
// Helpers live in agent-fleet-sensor-core.mjs (not ./agent-fleet-sensor.js):
// opencode treats each named export of a plugin module as a separate plugin
// factory and invokes it; exposing these pure helpers from sensor.js would
// break plugin loading. See the core module's header for the full rationale.
import { idleShouldWriteDone, planTransition, stateKeyFromCwd, repoNameFromCwd, escapeAppleScriptString } from './agent-fleet-sensor-core.mjs';

// idle must NOT clobber an unanswered needs-attention state (feedback #4)
assert.equal(idleShouldWriteDone({ state: 'needs-attention', reason: 'permission' }), false);
assert.equal(idleShouldWriteDone({ state: 'needs-attention', reason: 'error' }), false);
// idle IS allowed from working / done / fresh
assert.equal(idleShouldWriteDone({ state: 'working' }), true);
assert.equal(idleShouldWriteDone({ state: 'done' }), true);
assert.equal(idleShouldWriteDone(null), true);

// --- transition table (the core feature path, previously untested) ---
// permission.ask -> needs-attention, from a working agent: write + notify (rising edge)
assert.deepEqual(planTransition({ state: 'working' }, 'needs-attention'),
  { write: true, notify: true });
// session.error -> needs-attention, from working: write + notify
assert.deepEqual(planTransition({ state: 'working' }, 'needs-attention'),
  { write: true, notify: true });
// needs-attention -> needs-attention (2nd prompt while already red): write, but NO re-notify
assert.deepEqual(planTransition({ state: 'needs-attention' }, 'needs-attention'),
  { write: true, notify: false });
// needs-attention on a fresh agent (no existing record): write + notify
assert.deepEqual(planTransition(null, 'needs-attention'),
  { write: true, notify: true });
// permission.replied -> working: write, never notify
assert.deepEqual(planTransition({ state: 'needs-attention' }, 'working'),
  { write: true, notify: false });
// chat.message -> working: write, never notify
assert.deepEqual(planTransition({ state: 'done' }, 'working'),
  { write: true, notify: false });
// session.idle -> done from working: write, no notify
assert.deepEqual(planTransition({ state: 'working' }, 'done'),
  { write: true, notify: false });
// session.idle -> done while red: DROPPED (guard), no write, no notify
assert.deepEqual(planTransition({ state: 'needs-attention', reason: 'permission' }, 'done'),
  { write: false, notify: false });

// question.asked -> needs-attention: same transition as permission.asked (board-red
// rule is "blocked on human", not "permission specifically") — write + notify on the
// rising edge, and a 2nd question while already red must not re-notify.
assert.deepEqual(planTransition({ state: 'working' }, 'needs-attention'),
  { write: true, notify: true });
assert.deepEqual(planTransition({ state: 'needs-attention', reason: 'question' }, 'needs-attention'),
  { write: true, notify: false });
// question.replied / question.rejected -> working: write, never notify (same as
// permission.replied — both are "the human answered, unblock the agent")
assert.deepEqual(planTransition({ state: 'needs-attention', reason: 'question' }, 'working'),
  { write: true, notify: false });
// session.idle must not clobber a pending question either — same guard as permission
assert.equal(idleShouldWriteDone({ state: 'needs-attention', reason: 'question' }), false);

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

console.log('PASS: sensor pure-logic unit checks');
