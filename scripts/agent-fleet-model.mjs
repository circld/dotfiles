#!/usr/bin/env node
import { readdirSync, readFileSync, mkdirSync, writeFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  isSuppressed,
  repoNameFromCwd,
  stateKeyFromCwd,
  stateRank,
} from '../external/opencode/plugins/agent-fleet-sensor-core.mjs';

// -- trace collection (env-gated; sidecar written at end of run) --
const TRACE_DIR = process.env.AGENT_FLEET_TRACE_DIR ?? null;
const TRACE_REQ = process.env.AF_REQUEST_ID ?? null;
const TRACING = TRACE_DIR != null && TRACE_REQ != null;
const trace = { ts: Date.now(), files: [], identity: [], livePanes: null, ps: [] };

function sha1(s) {
  return createHash('sha1').update(s).digest('hex');
}

function psTree() {
  const ov = process.env.AGENT_FLEET_PS_TREE_OVERRIDE;
  let out = '';
  if (ov) {
    try { out = readFileSync(ov, 'utf8'); } catch {}
  } else {
    out = spawnSync('ps', ['-axo', 'pid=,ppid=,comm='], { encoding: 'utf8' }).stdout ?? '';
  }
  const byPid = new Map();
  for (const line of out.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (m) byPid.set(Number(m[1]), { ppid: Number(m[2]), comm: m[3] });
  }
  return byPid;
}

function zellijDescendant(pid, tree) {
  let cur = pid;
  for (let hops = 0; hops < 32; hops++) {
    const node = tree.get(cur);
    if (!node) return false;
    if (node.comm.includes('zellij')) return true;
    if (node.ppid === cur || node.ppid <= 1) return false;
    cur = node.ppid;
  }
  return false;
}

function cwdMatches(pid, cwd) {
  const ov = process.env.AGENT_FLEET_LSOF_OVERRIDE;
  let out = '';
  if (ov) {
    try { out = readFileSync(ov, 'utf8'); } catch {}
  } else {
    out = spawnSync('lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'], { encoding: 'utf8' }).stdout ?? '';
  }
  const n = out.split('\n').find((line) => line.startsWith('n'));
  return n != null && n.slice(1) === cwd;
}

const stateDir = process.env.AGENT_FLEET_STATE_DIR
  ?? path.join(process.env.HOME, '.local/state/agent-fleet');

function readJson(file, fallback = null) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function livePanes() {
  const override = process.env.AGENT_FLEET_LIVE_PANES_OVERRIDE;
  if (override) {
    return readFileSync(override, 'utf8')
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        const [cwd, session, pane, tabId] = line.split('\t');
        return { cwd, session, pane, tabId };
      })
      .filter((pane) => pane.cwd);
  }

  const sessions = spawnSync('zellij', ['list-sessions', '-s', '-n'], { encoding: 'utf8' });
  if (sessions.status !== 0) return [];
  return sessions.stdout.split('\n').filter(Boolean).flatMap((session) => {
    const panes = spawnSync('zellij', ['--session', session, 'action', 'list-panes', '--json', '--all'], { encoding: 'utf8' });
    if (panes.status !== 0) return [];
    let parsed = [];
    try {
      parsed = JSON.parse(panes.stdout || '[]');
    } catch {}
    return parsed
      .filter((pane) => pane.is_plugin === false && pane.pane_command === 'opencode' && pane.pane_cwd)
      .map((pane) => ({ cwd: pane.pane_cwd, session, pane: `terminal_${pane.id}`, tabId: String(pane.tab_id) }));
  });
}

function pidAliveOpencode(pid) {
  const result = (() => {
    const override = process.env.AGENT_FLEET_PS_OVERRIDE;
    if (override) {
      const hit = readFileSync(override, 'utf8')
        .split('\n')
        .map((line) => line.split('\t'))
        .find(([, p]) => p === String(pid));
      if (hit?.[0] === 'OPENCODE') return true;
      if (hit?.[0] === 'DEAD') return false;
    }
    try {
      process.kill(Number(pid), 0);
    } catch {
      return false;
    }
    const ps = spawnSync('ps', ['-o', 'comm=', '-p', String(pid)], { encoding: 'utf8' });
    return ps.status === 0 && ps.stdout.includes('opencode');
  })();
  if (TRACING) trace.ps.push({ pid, alive: result });
  return result;
}

function stateFiles() {
  try {
    return readdirSync(stateDir)
      .filter((name) => name.endsWith('.json') && !name.endsWith('.viewed.json'))
      .map((name) => path.join(stateDir, name));
  } catch {
    return [];
  }
}

function liveByCwd(panes) {
  const byCwd = new Map();
  for (const pane of panes) {
    const current = byCwd.get(pane.cwd) ?? { count: 0, ...pane };
    current.count += 1;
    current.session = pane.session;
    current.pane = pane.pane;
    current.tabId = pane.tabId;
    byCwd.set(pane.cwd, current);
  }
  return byCwd;
}

function readUsableState(live) {
  const v1 = new Map();
  const v2 = new Map();
  for (const file of stateFiles()) {
    const name = path.basename(file);
    let raw = null;
    try { raw = readFileSync(file, 'utf8'); } catch {}
    const rec = { name, mtimeMs: null, size: null, sha1: null, pid: null, verdict: 'rejected', reason: null };
    if (TRACING) {
      try { const st = statSync(file); rec.mtimeMs = st.mtimeMs; rec.size = st.size; } catch {}
      if (raw != null) rec.sha1 = sha1(raw);
    }
    let obj = null;
    try { obj = JSON.parse(raw ?? ''); } catch { rec.reason = 'parse-fail'; }
    if (rec.reason == null) {
      if (!obj?.cwd) rec.reason = 'no-cwd';
      else if (!live.has(obj.cwd)) rec.reason = 'not-live';
      else if (obj.sessions && typeof obj.sessions === 'object') {
        rec.pid = obj.pid ?? null;
        if (!obj.pid || !pidAliveOpencode(obj.pid)) rec.reason = 'dead-pid';
      }
    }
    if (rec.reason != null) { if (TRACING) trace.files.push(rec); continue; }
    const key = path.basename(file, '.json');
    if (obj.sessions && typeof obj.sessions === 'object') {
      rec.pid = obj.pid ?? null;
      rec.verdict = 'v2-used';
      const rows = v2.get(obj.cwd) ?? [];
      rows.push({ key, obj });
      v2.set(obj.cwd, rows);
    } else {
      rec.verdict = 'v1-used';
      v1.set(obj.cwd, { key, obj });
    }
    if (TRACING) trace.files.push(rec);
  }
  return { v1, v2 };
}

// -- action: cwd-scoped merge of viewed marks across pid siblings.
// Reads every file in stateDir whose name matches `^<cwd-hash>(-[0-9]+)?\.viewed\.json$`
// — bare hash OR hash joined to a NUMERIC pid suffix only. Strict regex so
// `hash-backup.viewed.json` (non-numeric pid suffix) does NOT participate.
// Corrupt / non-object / non-numeric-ts payloads are ignored. On a duplicate
// sid across sibling files, the MAX numeric ts wins (fresh local view
// overrides stale sibling view). ---
function viewedMapForCwd(cwd) {
  const hash = stateKeyFromCwd(cwd);
  const re = new RegExp(`^${hash}(-[0-9]+)?\\.viewed\\.json$`);
  let names;
  try {
    names = readdirSync(stateDir).filter((n) => re.test(n));
  } catch {
    return {};
  }
  const out = {};
  for (const name of names) {
    const obj = readJson(path.join(stateDir, name));
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) continue;
    for (const [sid, ts] of Object.entries(obj)) {
      if (typeof ts !== 'number' || Number.isNaN(ts)) continue;
      if (out[sid] == null || ts > out[sid]) out[sid] = ts;
    }
  }
  return out;
}

function baseRow({ cwd, live, key, obj, sid, entry, source, getViewedMap }) {
  const state = entry.state ?? 'unknown';
  const ts = Number(entry.ts ?? 0);
  const viewedTs = sid ? getViewedMap(cwd)[sid] ?? null : null;
  const suppressed = isSuppressed(state, ts, viewedTs);
  const rank = stateRank(state);
  return {
    cwd,
    session: live.session,
    pane: live.pane,
    tabId: live.tabId,
    key,
    pid: obj.pid ?? null,
    repo: obj.repo || repoNameFromCwd(cwd),
    sid: sid ?? null,
    state,
    reason: entry.reason ?? null,
    ts,
    title: entry.title ?? null,
    label: entry.title || obj.repo || repoNameFromCwd(cwd),
    suppressed,
    rank,
    source,
  };
}

function model() {
  const panes = livePanes();
  if (TRACING) trace.livePanes = { override: process.env.AGENT_FLEET_LIVE_PANES_OVERRIDE != null, count: panes.length };
  const live = liveByCwd(panes);
  const { v1, v2 } = readUsableState(live);
  if (TRACING) {
    const tree = psTree();
    for (const files of v2.values()) {
      for (const { obj } of files) {
        if (!obj.pid) continue;
        trace.identity.push({
          pid: obj.pid,
          cwd: obj.cwd,
          zellijDescendant: zellijDescendant(obj.pid, tree),
          cwdMatch: cwdMatches(obj.pid, obj.cwd),
        });
      }
    }
  }
  const ambiguous = new Set();
  for (const [cwd, pane] of live.entries()) if (pane.count >= 2) ambiguous.add(cwd);
  for (const [cwd, files] of v2.entries()) if (files.length >= 2) ambiguous.add(cwd);

  // -- cwd-keyed viewed-map cache so baseRow and the timeline join see the
  // same merged map per cwd within ONE model() run (audit consistency:
  // a file mid-run rewrite cannot make suppression and timeline differ). ---
  const viewedMapCache = new Map();
  const getViewedMap = (cwd) => {
    let m = viewedMapCache.get(cwd);
    if (!m) {
      m = viewedMapForCwd(cwd);
      viewedMapCache.set(cwd, m);
    }
    return m;
  };

  // -- calculation: live instances, one per usable v2 file (ambiguous included).
  // Used by the timeline join to scope viewed marks and by the press-time
  // resolver to identify the working file behind a (sid, ts) landing. ---
  const instances = [];
  for (const files of v2.values()) {
    for (const { key, obj } of files) {
      instances.push({
        key,
        cwd: obj.cwd,
        selectedSid: obj.selectedSid ?? null,
        selectedTs: obj.selectedTs ?? null,
        sessions: Object.keys(obj.sessions ?? {}).filter((sid) => sid !== '__pane__'),
      });
    }
  }

  const rows = [];
  for (const [cwd, pane] of live.entries()) {
    if (ambiguous.has(cwd)) {
      rows.push({ cwd, session: pane.session, pane: pane.pane, tabId: pane.tabId, state: 'duplicate', reason: 'duplicate opencode instance', ts: 0, suppressed: false, rank: null, source: 'warning', label: cwd, sid: null, key: null, pid: null, repo: repoNameFromCwd(cwd) });
      continue;
    }
    const v2Files = v2.get(cwd);
    if (v2Files?.length === 1) {
      const { key, obj } = v2Files[0];
      const sessionRows = [];
      for (const [sid, entry] of Object.entries(obj.sessions ?? {})) {
        if (sid === '__pane__') continue;
        // Startup-seeded sessions remain in instances[] for traversal, but
        // unknown rows are not actionable board entries.
        if (entry.state === 'unknown') continue;
        sessionRows.push(baseRow({ cwd, live: pane, key, obj, sid, entry, source: 'v2', getViewedMap }));
      }
      rows.push(...sessionRows);
      if (sessionRows.length > 0 && sessionRows.every((row) => row.state === 'done' && row.suppressed)) {
        rows.push({ cwd, session: pane.session, pane: pane.pane, tabId: pane.tabId, key, pid: obj.pid ?? null, repo: obj.repo || repoNameFromCwd(cwd), sid: null, state: 'idle', reason: 'all chats viewed', ts: Math.max(...sessionRows.map((row) => row.ts)), title: null, label: obj.repo || repoNameFromCwd(cwd), suppressed: false, rank: null, source: 'idle' });
      }
      continue;
    }
    const legacy = v1.get(cwd);
    if (legacy) {
      rows.push(baseRow({ cwd, live: pane, key: legacy.key, obj: legacy.obj, sid: null, entry: legacy.obj, source: 'v1', getViewedMap }));
      continue;
    }
    rows.push({ cwd, session: pane.session, pane: pane.pane, tabId: pane.tabId, key: null, pid: null, repo: repoNameFromCwd(cwd), sid: null, state: 'unknown', reason: 'no sensor yet - restart agent', ts: Date.now(), title: null, label: repoNameFromCwd(cwd), suppressed: false, rank: null, source: 'synthetic' });
  }

  const actionable = rows
    .filter((row) => row.suppressed === false && row.rank != null && row.source !== 'warning')
    .sort((a, b) => b.rank - a.rank || b.ts - a.ts);

  // -- timeline: pending FIFO + viewed join over live instances.
  // pending preserves actionable rows (all reachable sessions, FIFO oldest
  // first regardless of rank so the user sees the actual order of events).
  // viewed joins the cwd-scoped merged viewed map onto each instance's live
  // sessions (drops the ghost sids), dedupes by sid at max viewedTs, removes
  // anything in pending (pending wins), and sorts newest-first for the
  // landing payload (sid + viewedTs). Both consumers read via getViewedMap
  // so they share the cached per-cwd merge from this run. ---
  const pending = actionable
    .filter((row) => row.sid != null)
    .sort((a, b) => a.ts - b.ts);
  const pendingSidSet = new Set(pending.map((row) => row.sid));
  const viewedBySid = new Map();
  for (const inst of instances) {
    const merged = getViewedMap(inst.cwd);
    for (const sid of inst.sessions) {
      if (!(sid in merged)) continue;
      const ts = merged[sid];
      const cur = viewedBySid.get(sid);
      if (cur == null || ts > cur) viewedBySid.set(sid, ts);
    }
  }
  const viewed = [...viewedBySid.entries()]
    .filter(([sid]) => !pendingSidSet.has(sid))
    .map(([sid, viewedTs]) => ({ sid, viewedTs }))
    .sort((a, b) => b.viewedTs - a.viewedTs);

  return {
    live: panes,
    ambiguous: [...ambiguous],
    rows,
    actionable,
    instances,
    timeline: { viewed, pending },
  };
}

const result = model();
if (TRACING) {
  try {
    mkdirSync(path.join(TRACE_DIR, TRACE_REQ), { recursive: true });
    writeFileSync(path.join(TRACE_DIR, TRACE_REQ, 'model-trace.json'), JSON.stringify(trace, null, 2));
  } catch {}
}
process.stdout.write(`${JSON.stringify(result)}\n`);
