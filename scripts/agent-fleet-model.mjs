#!/usr/bin/env node
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  isSuppressed,
  repoNameFromCwd,
  stateRank,
} from '../external/opencode/plugins/agent-fleet-sensor-core.mjs';

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
    const obj = readJson(file);
    if (!obj?.cwd) continue;
    if (!live.has(obj.cwd)) continue;
    const key = path.basename(file, '.json');
    if (obj.sessions && typeof obj.sessions === 'object') {
      if (!obj.pid || !pidAliveOpencode(obj.pid)) continue;
      const rows = v2.get(obj.cwd) ?? [];
      rows.push({ key, obj });
      v2.set(obj.cwd, rows);
    } else {
      v1.set(obj.cwd, { key, obj });
    }
  }
  return { v1, v2 };
}

function viewedFor(key) {
  return readJson(path.join(stateDir, `${key}.viewed.json`), {});
}

function baseRow({ cwd, live, key, obj, sid, entry, source }) {
  const state = entry.state ?? 'unknown';
  const ts = Number(entry.ts ?? 0);
  const viewedTs = sid ? viewedFor(key)[sid] : null;
  const suppressed = isSuppressed(state, ts, viewedTs ?? null);
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
  const live = liveByCwd(panes);
  const { v1, v2 } = readUsableState(live);
  const ambiguous = new Set();
  for (const [cwd, pane] of live.entries()) if (pane.count >= 2) ambiguous.add(cwd);
  for (const [cwd, files] of v2.entries()) if (files.length >= 2) ambiguous.add(cwd);

  const rows = [];
  for (const [cwd, pane] of live.entries()) {
    if (ambiguous.has(cwd)) {
      rows.push({ cwd, session: pane.session, pane: pane.pane, tabId: pane.tabId, state: 'duplicate', reason: 'duplicate opencode instance', ts: 0, suppressed: false, rank: null, source: 'warning', label: cwd, sid: null, key: null, pid: null, repo: repoNameFromCwd(cwd) });
      continue;
    }
    const v2Files = v2.get(cwd);
    if (v2Files?.length === 1) {
      const { key, obj } = v2Files[0];
      for (const [sid, entry] of Object.entries(obj.sessions ?? {})) {
        if (sid === '__pane__') continue;
        rows.push(baseRow({ cwd, live: pane, key, obj, sid, entry, source: 'v2' }));
      }
      continue;
    }
    const legacy = v1.get(cwd);
    if (legacy) {
      rows.push(baseRow({ cwd, live: pane, key: legacy.key, obj: legacy.obj, sid: null, entry: legacy.obj, source: 'v1' }));
      continue;
    }
    rows.push({ cwd, session: pane.session, pane: pane.pane, tabId: pane.tabId, key: null, pid: null, repo: repoNameFromCwd(cwd), sid: null, state: 'unknown', reason: 'no sensor yet - restart agent', ts: Date.now(), title: null, label: repoNameFromCwd(cwd), suppressed: false, rank: null, source: 'synthetic' });
  }

  const actionable = rows
    .filter((row) => row.suppressed === false && row.rank != null && row.source !== 'warning')
    .sort((a, b) => b.rank - a.rank || b.ts - a.ts);

  return { live: panes, ambiguous: [...ambiguous], rows, actionable };
}

process.stdout.write(`${JSON.stringify(model())}\n`);
