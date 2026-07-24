// external/opencode/plugins/agent-fleet-sensor-core.mjs
//
// Pure-logic helpers extracted from the sensor plugin so unit tests can import
// them WITHOUT colliding with opencode's multi-plugin loader.
//
// Why this split exists (verified 2026-07-23 against opencode 1.18.3):
// opencode treats every top-level NAMED export of a plugin module as a separate
// plugin factory and AWAITs it with a PluginInput ({ directory, $, ... }). The
// pure helpers in this file (stateKeyFromCwd, planTransition, etc.) are NOT
// plugin factories; when the sensor plugin file exported them as named
// bindings, opencode called e.g. escapeAppleScriptString({ directory, $ }),
// and our function crashed on `s.replace(...)` because the args aren't a
// string. Mitigation: helpers live in this .mjs file (no plugin loader sees
// them), and sensor.js imports them from here. The plugin file itself only
// default-exports the plugin factory — opencode is happy with that.

import path from 'node:path';
import { createHash } from 'node:crypto';

// -- calculation: state-file key from absolute cwd (identity key; survives worktrees) --
// cwd is the only stable identity: session name, repo basename, and tab name all diverge
// (verified: session=notes, cwd-basename=ai_default_project, tab=ai for one agent).
// Use a sha256 prefix, NOT a char-substitution: sanitizing "/" -> "_" collides
// (verified: "/a_b" and "/a/b" both map to "a_b"). The hash is reproducible in bash
// via `printf '%s' "$cwd" | shasum -a 256 | cut -c1-16` so render/jump/test agree.
export function stateKeyFromCwd(cwd) {
  return createHash('sha256').update(cwd).digest('hex').slice(0, 16);
}

// -- calculation: repo label from a worktree/cwd path (display only; NOT an identity key) --
// For a worktree (.../<repo>/.worktrees/<wt>), disambiguate as "<repo>:<wt>" so two
// same-named worktree dirs from DIFFERENT repos don't render as two identical rows
// (verified wart: /octane/.worktrees/feat and /dotfiles/.worktrees/feat both basename
// to "feat"). Non-worktree cwds fall back to plain basename.
export function repoNameFromCwd(cwd) {
  const parts = cwd.split(path.sep).filter(Boolean);   // filter(Boolean) drops the empty
                                                        // segment from a trailing slash
  const wtIdx = parts.lastIndexOf('.worktrees');
  if (wtIdx > 0 && wtIdx < parts.length - 1) {
    return `${parts[wtIdx - 1]}:${parts[wtIdx + 1]}`;   // <repo>:<worktree>
  }
  return path.basename(cwd);
}

// -- calculation: build the next state record (pure, no I/O) --
export function buildStateRecord({ repo, cwd, session, state, reason, previousTask }) {
  return {
    repo,
    cwd,
    session,
    state,
    reason: reason ?? null,
    task: previousTask ?? null,
    ts: Date.now(),
  };
}

// -- calculation: should this idle event be allowed to write `done`? --
// Guard: never let an idle event clobber an unanswered needs-attention/permission state.
// opencode can emit session.idle while a permission prompt is still pending; writing `done`
// there would drop the red board state before the human acts.
export function idleShouldWriteDone(existing) {
  if (!existing) return true;
  if (existing.state === 'needs-attention') return false;
  return true;
}

// -- calculation: decide the outcome of a transition (pure; no I/O) --
// Given the existing record and the requested (state, reason), return:
//   { write: boolean, notify: boolean }
// This is the ONE place the transition table's semantics live, so it is unit-tested
// directly (all rows: permission.ask, session.error, session.idle, permission.replied,
// chat.message) without needing a running opencode. transition() below is a thin action
// wrapper that just executes this plan.
//   - a `done` request is dropped when idle must not clobber needs-attention (guard above)
//   - notify fires ONLY on the rising edge into needs-attention (not attention->attention),
//     so a second permission prompt while already red does not re-notify
export function planTransition(existing, state) {
  if (state === 'done' && !idleShouldWriteDone(existing)) {
    return { write: false, notify: false };
  }
  const wasAttention = existing?.state === 'needs-attention';
  const notify = state === 'needs-attention' && !wasAttention;
  return { write: true, notify };
}

// -- AppleScript injection guard for the notification string literal --
// SECURITY: repo/reason are interpolated into an AppleScript string literal.
// A repo/worktree dir name can legally contain `"` and `\`, and a hostile
// clone/worktree path could carry `foo" & (do shell script "...") & "bar`,
// which osascript would EXECUTE (verified: crafted name ran arbitrary shell).
// Escape `\` first, then `"`, so the value stays inert data inside the quotes.
export function escapeAppleScriptString(s) {
  return s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}
