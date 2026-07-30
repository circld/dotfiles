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

// -- calculation: per-session slot for the v2 record (pure, no I/O; ts is INPUT) --
// v2 shape moves `state`/`reason`/`ts`/`task` off the file-level row and into
// record.sessions[<topLevelSessionID>] (one entry per opencode session active
// in this pane). `ts` is INPUT (not Date.now() inside the helper): the action
// layer stamps via planTransition's returned ts and pipes it in — keeping
// the helper pure is what makes the unit test deterministic (tests pass a
// fixed NOW constant). `title` is display-only (resolved via
// client.session.get in the action layer; falls back to a truncated sessionID
// on the render side if absent — the action layer still passes what it has
// here). previousTask -> task field on the record (the public/persistent
// field name diverges from the helper argument name — the JSON file uses
// `task` everywhere; the helper's argument name is `previousTask` because
// callers pass `existing?.sessions?.[id]?.task`).
//
// This is the entry-shape helper downstream readers (Tasks 5/6) should
// lock against: it intentionally does NOT carry file-level identity (no
// repo/cwd/session/pid — those live on the envelope), so callers assembling
// a full file just compose: buildV2StateRecord({ ..., sessions: { [id]:
// buildSessionEntry({ ... }) } }).
export function buildSessionEntry({ state, reason, previousTask, ts, title }) {
  return {
    state,
    reason: reason ?? null,
    task: previousTask ?? null,
    ts,
    title: title ?? null,
  };
}

// -- calculation: v2 file-level envelope (pure, no I/O) --
// Assembles the on-disk record shape: file-level identity (repo/cwd/session/
// pid) wraps a per-session map. The plugin's atomic-write helper
// (sensor.js: writeStateRecord) serializes THIS object; readers
// (Tasks 5/6) consume via the same shape. Pure so callers don't accidentally
// capture I/O / `Date.now()` here — those belong in the action layer. Naming
// ("StateRecord") matches the prior v1 helper to keep call-sites legible.
//
// Task 1: the envelope also carries the SELECTION CURSOR at file level —
// `selectedSid` (top-level session id the TUI is currently on) plus `selectedTs`
// (the wall-clock election time, NOT the entry's `ts`). Restart-safety rationale:
// without these at file level, "which session is focused right now" dies with the
// process. The cursor is `null`-coalesced like `session` so readers can tell a
// never-selected process apart from a deleted JSON. Every rebuild MUST thread
// existing values through (the action layer passes `existing?.selectedSid` /
// `existing?.selectedTs`) — a transition rebuild that forgets the cursor would
// silently copy fields with `undefined` and erase the live selection.
export function buildV2StateRecord({ repo, cwd, session, pid, selectedSid, selectedTs, sessions }) {
  return {
    repo,
    cwd,
    session: session ?? null,
    pid,
    selectedSid: selectedSid ?? null,
    selectedTs: selectedTs ?? null,
    sessions,
  };
}

// -- calculation: should this idle event be allowed to write `done`? --
// Guard: never let an idle event clobber an unanswered needs-attention state, regardless
// of WHY it's red (permission prompt, question tool, etc. — see planTransition below).
// opencode can emit session.idle while a prompt is still pending; writing `done` there
// would drop the red board state before the human acts.
export function idleShouldWriteDone(existing) {
  if (!existing) return true;
  if (existing.state === 'needs-attention') return false;
  return true;
}

// -- calculation: per-process identity key (cwd + pid; jump.sh targets a specific tmux pane) --
// Returns "<cwd-hash>-<pid>" when pid is present (the live-process case — jump.sh
// uses this to find a specific shell's state file, since two opencode panes can
// share the same cwd in worktrees). Falls back to the bare cwd-hash when pid is
// absent (legacy / cross-pane lookups, e.g. board rendering by cwd alone). The
// fallback intentionally does NOT include a trailing "-" — downstream scripts
// grep/match on the bare hash and would miss "hash-" if we used a sentinel.
export function stateKeyForProcess(cwd, pid) {
  const base = stateKeyFromCwd(cwd);
  return pid != null ? `${base}-${pid}` : base;
}

// -- calculation: is this row suppressed (previously viewed)? --
// Only terminal/blocked states ('done', 'needs-attention') can be suppressed.
// 'working' is never suppressed — a long-running agent's age advancing past the
// viewer's last-seen ts is the normal case, not a suppression signal; rendering
// must always show working rows. The viewedTs >= entryTs rule means "the user
// has already seen this specific event since it landed", which is what makes
// the per-event ts the right key (not some coarser window): a state flip while
// the user wasn't looking produces a fresh entryTs > old viewedTs, hence
// NOT suppressed, hence surfaces on the board as the new event. A null viewedTs
// (never viewed) is NOT suppressed, by design — freshly-arrived rows always
// render until the user has explicitly marked them seen.
export function isSuppressed(state, entryTs, viewedTs) {
  if (state !== 'done' && state !== 'needs-attention') return false;
  if (viewedTs == null) return false;
  return viewedTs >= entryTs;
}

export function stateRank(state) {
  if (state === 'needs-attention') return 1;
  if (state === 'done') return 0;
  return null;
}

// -- calculation: decide the outcome of a transition (pure; no I/O; ts-aware) --
// Given (existingEntry, nextState, nextReason, now), returns:
//   { write: boolean, notify: boolean, ts: number | undefined }
// This is the ONE place the transition table's semantics live, so it is unit-tested
// directly (all rows: permission.asked/replied, question.asked/replied/rejected,
// session.error, session.idle, chat.message) without needing a running opencode.
// `now` is PASSED IN BY THE CALLER (sensor.js does `Date.now()` in the action layer);
// planTransition must NOT call Date.now() itself — keeping the helper pure is what
// makes the unit tests deterministic (tests pass a fixed NOW constant).
//
// Why ts is part of the returned plan (Task 2): the no-change repeat rule. If
// (nextState, nextReason) === (existingEntry.state, existingEntry.reason) the
// event is a true repeat and the existing ts is preserved. Otherwise ts = now.
// "Reason" must be part of the identity check (NOT just state): a fresh `needs-
// attention/question` arriving on top of a previously-viewed `needs-attention/
// permission` is a NEW actionable event. Keying the repeat check on state alone
// would keep the old ts, let isSuppressed hide the new entry against the
// viewer's stale viewedTs, and silently drop a real attention signal.
//
//   - a `done` request is dropped when idle must not clobber needs-attention (guard above).
//     The dropped case has no ts: the caller won't build a record when write=false.
//   - notify fires on the rising edge into needs-attention OR done (not attention->attention
//     or done->done), so a 2nd prompt of the SAME kind while already red, or a 2nd idle tick
//     while already green, does not re-notify. done-notify is the human-UX signal that an
//     agent finished its turn and is ready for review — symmetric to the red "blocked on
//     human" signal, just the opposite direction (agent waiting FOR vs agent waiting ON).
export function planTransition(existingEntry, nextState, nextReason, now) {
  if (nextState === 'done' && !idleShouldWriteDone(existingEntry)) {
    return { write: false, notify: false };
  }
  const sameState = existingEntry?.state === nextState;
  const sameReason = (existingEntry?.reason ?? null) === (nextReason ?? null);
  const isRepeat = sameState && sameReason;
  const ts = isRepeat && existingEntry ? existingEntry.ts : now;
  const wasAttention = existingEntry?.state === 'needs-attention';
  const wasDone = existingEntry?.state === 'done';
  const notify = (nextState === 'needs-attention' && !wasAttention)
    || (nextState === 'done' && !wasDone);
  return { write: true, notify, ts };
}

// -- calculation: does the frontmost window's title indicate this repo is on screen? --
// Notifications exist to alert a human who is NOT looking at the terminal already —
// firing them while the agent's own repo is the focused window is pure noise (you're
// already looking at the thing that just changed). opencode itself writes window titles
// as "<repo> | OC | <chat title>" (verified live against opencode 1.18.3 + Ghostty via
// `aerospace list-windows --focused --json`), so a prefix match against that title is a
// cheap, precise-enough visibility proxy — no Accessibility API, no new dependency.
//
// Ceiling (ponytail: named, not hidden): single-frontmost-window heuristic only. A
// second monitor showing the repo in a non-focused window still reads as "not visible"
// here and WILL notify. Upgrade path if that gap matters: `aerospace list-windows --all`
// + monitor geometry instead of `--focused`.
//
// null title (aerospace missing/not running, or no focused window) fails OPEN to "not
// visible" — same fail-safe direction as every other guard in this file: a broken
// visibility check must never silently swallow a real attention-needed signal.
export function isRepoVisible(focusedTitle, repo) {
  if (!focusedTitle) return false;
  return focusedTitle.startsWith(`${repo} |`);
}

export function notificationMessage({ repo, zellijSession, chatTitle, state, reason }) {
  const target = [zellijSession, chatTitle].filter(Boolean).join(' / ') || repo;
  if (state === 'done') return `${target} is done and ready`;
  return `${target} needs attention (${reason ?? 'unknown'})`;
}

export function notificationSoundForState(state, env = {}) {
  const sound = state === 'needs-attention'
    ? env.AGENT_FLEET_SOUND_BLOCKING
    : state === 'done'
      ? env.AGENT_FLEET_SOUND_DONE
      : null;
  return sound || null;
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

export function notificationScript(message, soundName) {
  const safeTitle = escapeAppleScriptString('opencode');
  const safeMessage = escapeAppleScriptString(message);
  const base = 'display notification "' + safeMessage + '" with title "' + safeTitle + '"';
  if (!soundName) return base;
  return base + ' sound name "' + escapeAppleScriptString(soundName) + '"';
}

// -- calculation: mailbox handling decision — what to do after the poll reads <key>.select --
// Caller (sensor.js, action layer) does the I/O — reads `<key>.select`, calls
// `client.tui._client.post('/tui/select-session')`, captures success/failure — and
// pipes the two inputs in here to get the resulting write plan. This split keeps
// the I/O dependent step out of the unit test (no filesystem, no live TUI) and
// locks the decision rules as tests run against pure data:
//   - mailbox==null OR mailbox.sessionID is falsy/empty (parse failed / missing /
//     partial JSON / sessionID missing or empty string): DELETE the mailbox and
//     DO NOT mark viewed. `delete:true` is the wedge-prevention rule — a partly-
//     written, shape-wrong, or empty-sessionID `.select` must not stick around
//     to be retried forever; `markViewed:false` is correctness, because there is
//     no actionable sessionID to pin a viewed mark against. The sessionID check
//     is defense-in-depth — sensor.js already short-circuits empty-string sessionID
//     before reaching planSelect via `sessionID ? mailbox : null`, but the helper
//     is robust to direct calls so future callers can't silently produce
//     markViewed:true against a junk sessionID.
//   - mailbox!=null, selectOk===true (strict equality — `1`, `'true'`, etc.
//     collapse to failure): BOTH mark viewed AND delete. markViewed is what makes
//     the next render's isSuppressed(viewedTs >= entryTs) actually hide the row —
//     a successful jump means the user is now looking at it. Strict-===lock so a
//     future non-boolean truthy return from the TUI call cannot silently claim a
//     failed jump as a viewed one.
//   - mailbox!=null, selectOk===false: DELETE the mailbox (don't wedge) but DO
//     NOT mark viewed — a failed jump didn't put the user on that session, so
//     claiming they viewed it would silently hide a row they never saw.
//   - mailbox.markOnly===true (Task 6: board-dismiss verb): mark viewed AND delete
//     UNCONDITIONALLY — the user has already seen the row on the board, so the
//     mark is correct by definition, regardless of selectOk. `selectOk` is
//     ignored on this branch because the action layer skips the live TUI call
//     entirely (no jump happens on a mark-only mailbox); also no selectedSid /
//     selectedTs cursor persistence — the cursor writer in the action layer
//     keys on `selectOk`, which is false here.
// All four paths emit `deleteMailbox:true` so a single consumer branch in the
// action layer (`if (plan.deleteMailbox) unlink(...)`) covers every case and the
// poll never wedges.
// Purity contract: takes parsed mailbox + boolean selectOk, returns the plan, no
// I/O, no Date.now() — anything time-/file-dependent belongs in the action layer
// (e.g. the Date.now() fallback for the viewed ts when no entry exists yet).
export function planSelect(mailbox, selectOk) {
  if (mailbox == null || !mailbox.sessionID) {
    return { markViewed: false, deleteMailbox: true };
  }
  if (mailbox.markOnly === true) {
    return { markViewed: true, deleteMailbox: true };
  }
  return {
    markViewed: selectOk === true,
    deleteMailbox: true,
  };
}
