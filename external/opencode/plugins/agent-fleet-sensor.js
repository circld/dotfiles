// external/opencode/plugins/agent-fleet-sensor.js
//
// Global opencode plugin. Writes one state file per agent to
// ~/.local/state/agent-fleet/<key>.json on every relevant lifecycle event,
// where <key> is a sha256 prefix of the absolute cwd (identity that survives worktrees),
// and fires an osascript notification on transitions INTO needs-attention (red, blocked
// on human) OR done (green, agent finished and ready for review) — not on every event,
// to avoid notification noise — and only when the repo isn't already the frontmost
// window (see isRepoVisible in agent-fleet-sensor-core.mjs).
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
// so they are recorded for display but never used as the join key.
//
// IMPORTANT: this module's ONLY module-level named/default export is the plugin
// factory itself. Pure-logic helpers (stateKeyFromCwd, planTransition, etc.)
// live in ./agent-fleet-sensor-core.mjs and are imported here. opencode treats
// every named export of a plugin module as a separate plugin factory it MUST
// successfully invoke, so re-exporting the helpers here would break loading
// (verified: opencode awaited escapeAppleScriptString({directory,$}) which
// then crashed on `s.replace(...)`). See agent-fleet-sensor-core.mjs header.

import { mkdirSync, writeFileSync, readFileSync, renameSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

import {
  stateKeyFromCwd,
  repoNameFromCwd,
  buildStateRecord,
  planTransition,
  escapeAppleScriptString,
  isRepoVisible,
} from './agent-fleet-sensor-core.mjs';

const STATE_DIR = path.join(os.homedir(), '.local', 'state', 'agent-fleet');

// -- action: read existing state file (I/O, returns null on any failure) --
function readExistingState(statePath) {
  try {
    return JSON.parse(readFileSync(statePath, 'utf8'));
  } catch {
    return null;
  }
}

// -- action: write state file ATOMICALLY (I/O) --
// Write to a temp file then rename onto the target. rename(2) is atomic on the same
// filesystem, so the board's render (which reads these files continuously) can never
// observe a half-written file. A plain writeFileSync truncates-then-writes, leaving a
// window where a concurrent reader gets partial JSON — verified to crash the board's
// `jq` under `set -e`. The temp name includes pid so concurrent agents don't collide.
function writeStateRecord(statePath, record) {
  mkdirSync(path.dirname(statePath), { recursive: true });
  const tmp = `${statePath}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(record, null, 2));
  renameSync(tmp, statePath);
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
function notify($, repo, message) {
  (async () => {
    const focusedTitle = await getFocusedWindowTitle($);
    if (isRepoVisible(focusedTitle, repo)) return;   // human's already looking — skip
    const safeTitle = escapeAppleScriptString('opencode');
    const safeMessage = escapeAppleScriptString(message);
    const script = 'display notification "' + safeMessage + '" with title "' + safeTitle + '"';
    await $`timeout 5 osascript -e ${script}`.quiet();
  })().catch(() => {});
}

function statePathFor(key) {
  return path.join(STATE_DIR, `${key}.json`);
}

export const AgentFleetSensorPlugin = async ({ directory, $ }) => {
  const repo = repoNameFromCwd(directory);        // display label only
  const key = stateKeyFromCwd(directory);         // identity key (survives worktrees)
  const statePath = statePathFor(key);
  // session is recorded best-effort from the zellij env of the opencode process.
  // It is NOT assumed equal to repo — the board/jump join on cwd, not session name.
  const session = process.env.ZELLIJ_SESSION_NAME ?? null;

  async function transition(state, reason) {
    const existing = readExistingState(statePath);
    const plan = planTransition(existing, state);   // pure decision (unit-tested)
    if (!plan.write) return;
    const record = buildStateRecord({
      repo,
      cwd: directory,
      session,
      state,
      reason,
      previousTask: existing?.task,
    });
    writeStateRecord(statePath, record);
    if (plan.notify) {
      const message = state === 'done'
        ? `${repo} is done and ready`
        : `${repo} needs attention (${reason ?? 'unknown'})`;
      // fire-and-forget: NOT awaited, so a hung/slow aerospace or osascript can never
      // stall the permission.ask hook (which opencode awaits). See notify().
      notify($, repo, message);
    }
  }

  return {
    event: async ({ event } = {}) => {
      if (!event) return;
      if (event.type === 'session.error') await transition('needs-attention', 'error');
      if (event.type === 'session.idle') await transition('done', null);
      if (event.type === 'permission.replied') await transition('working', null);
      // NOT the 'permission.ask' hook key (see below): opencode 1.18.3 declares it in
      // @opencode-ai/plugin's Hooks type but never invokes it — verified live against a
      // real Desktop-access prompt: the dedicated hook never fired while the prompt sat
      // on screen, and only the generic `event` dispatcher saw the permission lifecycle,
      // as `permission.asked` / `permission.replied` EVENT TYPES (not hook keys). Board
      // stayed yellow/"working" through an entire live permission prompt as a result —
      // the exact bug this fixes.
      if (event.type === 'permission.asked') await transition('needs-attention', 'permission');
      // The `question` tool (interactive multi-choice prompt) blocks the agent exactly
      // like a permission prompt: opencode awaits the human's answer before the turn
      // can continue. Same event-dispatcher pattern as permission.asked/replied above —
      // verified present as event types on opencode 1.18.3 (`strings` on the binary
      // shows question.asked/replied/rejected; no dedicated plugin hook exists for it,
      // same as permission). Board must go red for ANY blocking-on-human condition,
      // not just permission — this is that broader rule's second instance.
      if (event.type === 'question.asked') await transition('needs-attention', 'question');
      // .rejected (user dismissed without answering) still resolves the block — the
      // agent is no longer waiting, so it must clear needs-attention same as .replied.
      if (event.type === 'question.replied' || event.type === 'question.rejected') {
        await transition('working', null);
      }
    },

    'chat.message': async () => {
      await transition('working', null);
    },
  };
};

export default AgentFleetSensorPlugin;
