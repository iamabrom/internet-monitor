#!/usr/bin/env bash
set -euo pipefail

# Bootstrap installer for LAN Internet Monitor on Raspberry Pi (Bookworm, 64-bit)
# Run as the user that should own the monitor (usually 'pi')

# Configuration
INSTALL_DIR="$HOME/lan-internet-monitor"
NVM_VERSION="v0.39.6"
NODE_VERSION="18"  # change to 20 if you prefer
PM2_NAME="lan-monitor"
CRON_TIME="10 3 * * *" # daily at 03:10

echo "\n=== LAN Internet Monitor Bootstrap ===\n"

read -p "This script will install system packages, Node, and create files in $INSTALL_DIR. Continue? [y/N] " answer
if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
  echo "Aborted by user."
  exit 1
fi

# 1) Update & install OS packages
echo "\n--- Updating OS and installing packages ---\n"
sudo apt update
sudo apt upgrade -y
sudo apt install -y build-essential python3 pkg-config libsqlite3-dev traceroute sqlite3 git curl dphys-swapfile

# 2) Install nvm if not present
if ! command -v nvm >/dev/null 2>&1; then
  echo "Installing nvm ${NVM_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
  # shellcheck disable=SC1090
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
else
  echo "nvm already installed"
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
fi

# 3) Install Node via nvm
echo "Installing Node ${NODE_VERSION} (LTS)..."
nvm install ${NODE_VERSION}
nvm use ${NODE_VERSION}

echo "Node: $(node -v)"
echo "npm: $(npm -v)"

# 4) Create project structure and write files
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# create package.json (overwrite if exists)
cat > package.json <<'JSON'
{
  "name": "lan-internet-monitor",
  "version": "1.0.0",
  "description": "Simple LAN internet up/down monitor for Raspberry Pi",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "start:fallback": "node server-sqlite3.js",
    "dev": "npx nodemon server.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  }
}
JSON

# Write server.js (better-sqlite3 variant)
cat > server.js <<'SERVERJS'
// server.js - recommended (uses better-sqlite3)
const express = require('express');
const { exec } = require('child_process');
const os = require('os');
const path = require('path');

let Database;
try {
  Database = require('better-sqlite3');
} catch (err) {
  console.error('better-sqlite3 not found or failed to load. Install it or use the fallback server-sqlite3.js');
  console.error(err && err.message);
  process.exit(1);
}

const app = express();
const db = new Database(path.join(__dirname, 'monitor.db'));

const TARGETS = [
  'google.com',
  '8.8.8.8',
  '1.1.1.1',
  'frontier.com',
  '192.168.2.1'
];

// Create tables
db.exec(`
CREATE TABLE IF NOT EXISTS pings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  target TEXT NOT NULL,
  alive INTEGER,
  time_ms REAL,
  ttl INTEGER,
  raw TEXT
);
CREATE INDEX IF NOT EXISTS idx_pings_ts ON pings(ts);
CREATE INDEX IF NOT EXISTS idx_pings_target ON pings(target);

CREATE TABLE IF NOT EXISTS traceroutes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  target TEXT NOT NULL,
  raw TEXT
);
CREATE INDEX IF NOT EXISTS idx_tr_ts ON traceroutes(ts);
`);

const insertPingStmt = db.prepare('INSERT INTO pings (ts,target,alive,time_ms,ttl,raw) VALUES (?,?,?,?,?,?)');
const insertTraceStmt = db.prepare('INSERT INTO traceroutes (ts,target,raw) VALUES (?,?,?)');

function runPingCommand(target, cb) {
  const cmd = `ping -c 1 -W 2 ${target}`;
  exec(cmd, { timeout: 5000, maxBuffer: 200 * 1024 }, (err, stdout, stderr) => {
    const raw = (stdout || '') + (stderr || '');
    let time_ms = null;
    let ttl = null;
    const timeMatch = raw.match(/time[=<]\s*([\d.]+)\s*ms/i);
    const ttlMatch = raw.match(/ttl[=|:]\s*(\d+)/i);
    if (timeMatch) time_ms = parseFloat(timeMatch[1]);
    if (ttlMatch) ttl = parseInt(ttlMatch[1], 10);
    let alive = 0;
    if (timeMatch || /bytes from/i.test(raw)) alive = 1;
    cb(null, { raw, alive, time_ms, ttl });
  });
}

function runTracerouteCommand(target, cb) {
  const cmd = `traceroute -m 30 ${target}`;
  exec(cmd, { timeout: 120000, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
    const raw = (stdout || '') + (stderr || '');
    cb(null, { raw });
  });
}

function startPingLoop() {
  TARGETS.forEach((target, idx) => {
    setTimeout(() => {
      setInterval(() => {
        const ts = Date.now();
        runPingCommand(target, (err, res) => {
          if (err) {
            console.error('ping cmd error', err);
            return;
          }
          try {
            insertPingStmt.run(ts, target, res.alive, res.time_ms, res.ttl, res.raw);
          } catch (e) {
            console.error('DB insert ping error', e);
          }
        });
      }, 1000);
    }, idx * 200);
  });
}

function startTracerouteLoop() {
  const runAll = () => {
    const ts = Date.now();
    TARGETS.forEach((target, idx) => {
      setTimeout(() => {
        runTracerouteCommand(target, (err, res) => {
          if (err) {
            console.error('traceroute err', err);
            return;
          }
          try {
            insertTraceStmt.run(ts, target, res.raw);
          } catch (e) {
            console.error('DB insert trace error', e);
          }
        });
      }, idx * 500);
    });
  };
  runAll();
  setInterval(runAll, 5 * 60 * 1000);
}

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/pings', (req, res) => {
  const hours = parseFloat(req.query.hours) || 24;
  const since = Date.now() - Math.max(1, hours) * 60 * 60 * 1000;
  const limit = parseInt(req.query.limit || '200000', 10);
  const rows = db.prepare('SELECT * FROM pings WHERE ts >= ? ORDER BY ts ASC LIMIT ?').all(since, limit);
  res.json({ ok: true, since, rows });
});

app.get('/api/status', (req, res) => {
  const result = {};
  TARGETS.forEach(target => {
    const row = db.prepare('SELECT * FROM pings WHERE target = ? ORDER BY ts DESC LIMIT 1').get(target);
    result[target] = row || null;
  });
  res.json({ ok: true, targets: TARGETS, latest: result });
});

app.get('/api/traceroutes', (req, res) => {
  const limit = parseInt(req.query.limit || '10', 10);
  const rows = db.prepare('SELECT * FROM traceroutes ORDER BY ts DESC LIMIT ?').all(limit);
  res.json({ ok: true, rows });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`monitor server listening on http://0.0.0.0:${PORT}`);
  startPingLoop();
  startTracerouteLoop();
});
SERVERJS

# Write fallback server-sqlite3.js
cat > server-sqlite3.js <<'SERVERF'
// server-sqlite3.js - fallback using sqlite3 (async)
const express = require('express');
const { exec } = require('child_process');
const os = require('os');
const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const app = express();
const dbFile = path.join(__dirname, 'monitor.db');
const db = new sqlite3.Database(dbFile);

const TARGETS = [
  'google.com',
  '8.8.8.8',
  '1.1.1.1',
  'frontier.com',
  '192.168.2.1'
];

db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS pings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    target TEXT NOT NULL,
    alive INTEGER,
    time_ms REAL,
    ttl INTEGER,
    raw TEXT
  )`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_pings_ts ON pings(ts)`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_pings_target ON pings(target)`);

  db.run(`CREATE TABLE IF NOT EXISTS traceroutes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    target TEXT NOT NULL,
    raw TEXT
  )`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_tr_ts ON traceroutes(ts)`);
});

function runPingCommand(target, cb) {
  const cmd = `ping -c 1 -W 2 ${target}`;
  exec(cmd, { timeout: 5000, maxBuffer: 200 * 1024 }, (err, stdout, stderr) => {
    const raw = (stdout || '') + (stderr || '');
    let time_ms = null;
    let ttl = null;
    const timeMatch = raw.match(/time[=<]\s*([\d.]+)\s*ms/i);
    const ttlMatch = raw.match(/ttl[=|:]\s*(\d+)/i);
    if (timeMatch) time_ms = parseFloat(timeMatch[1]);
    if (ttlMatch) ttl = parseInt(ttlMatch[1], 10);
    let alive = 0;
    if (timeMatch || /bytes from/i.test(raw)) alive = 1;
    cb(null, { raw, alive, time_ms, ttl });
  });
}

function runTracerouteCommand(target, cb) {
  const cmd = `traceroute -m 30 ${target}`;
  exec(cmd, { timeout: 120000, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
    const raw = (stdout || '') + (stderr || '');
    cb(null, { raw });
  });
}

function startPingLoop() {
  TARGETS.forEach((target, idx) => {
    setTimeout(() => {
      setInterval(() => {
        const ts = Date.now();
        runPingCommand(target, (err, res) => {
          if (err) {
            console.error('ping cmd error', err);
            return;
          }
          const stmt = `INSERT INTO pings (ts,target,alive,time_ms,ttl,raw) VALUES (?,?,?,?,?,?)`;
          db.run(stmt, [ts, target, res.alive, res.time_ms, res.ttl, res.raw], function(err) {
            if (err) console.error('DB insert ping error', err);
          });
        });
      }, 1000);
    }, idx * 200);
  });
}

function startTracerouteLoop() {
  const runAll = () => {
    const ts = Date.now();
    TARGETS.forEach((target, idx) => {
      setTimeout(() => {
        runTracerouteCommand(target, (err, res) => {
          if (err) {
            console.error('traceroute err', err);
            return;
          }
          const stmt = `INSERT INTO traceroutes (ts,target,raw) VALUES (?,?,?)`;
          db.run(stmt, [ts, target, res.raw], function(err) {
            if (err) console.error('DB insert trace error', err);
          });
        });
      }, idx * 500);
    });
  };
  runAll();
  setInterval(runAll, 5 * 60 * 1000);
}

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/pings', (req, res) => {
  const hours = parseFloat(req.query.hours) || 24;
  const since = Date.now() - Math.max(1, hours) * 60 * 60 * 1000;
  const limit = parseInt(req.query.limit || '200000', 10);
  db.all('SELECT * FROM pings WHERE ts >= ? ORDER BY ts ASC LIMIT ?', [since, limit], (err, rows) => {
    if (err) return res.json({ ok:false, err: err.message });
    res.json({ ok:true, since, rows });
  });
});

app.get('/api/status', (req, res) => {
  const latest = {};
  let processed = 0;
  TARGETS.forEach(target => {
    db.get('SELECT * FROM pings WHERE target = ? ORDER BY ts DESC LIMIT 1', [target], (err, row) => {
      processed++;
      latest[target] = row || null;
      if (processed === TARGETS.length) {
        res.json({ ok:true, targets: TARGETS, latest });
      }
    });
  });
});

app.get('/api/traceroutes', (req, res) => {
  const limit = parseInt(req.query.limit || '10', 10);
  db.all('SELECT * FROM traceroutes ORDER BY ts DESC LIMIT ?', [limit], (err, rows) => {
    if (err) return res.json({ ok:false, err: err.message });
    res.json({ ok:true, rows });
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`monitor server listening on http://0.0.0.0:${PORT}`);
  startPingLoop();
  startTracerouteLoop();
});
SERVERF

# Create public files
mkdir -p public

cat > public/index.html <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>LAN Internet Monitor</title>
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <div class="container">
    <h1>LAN Internet Monitor</h1>
    <div id="statusGrid" class="status-grid"></div>

    <div class="big-status" id="globalIndicator">
      <div id="globalText">Loading...</div>
      <div id="lastUpdate">—</div>
    </div>

    <h2>24-hour timeline (per minute aggregation)</h2>
    <div id="timelineArea"></div>

    <h3>Recent failures</h3>
    <div id="failures"></div>

    <footer>
      <small>Data stored locally in SQLite. Page auto-refreshes aggregation every 10s.</small>
    </footer>
  </div>

  <script src="/app.js"></script>
</body>
</html>
HTML

cat > public/styles.css <<'CSS'
body {
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial;
  background: #0f1724;
  color: #e6eef8;
  margin: 0;
  padding: 16px;
}
.container {
  max-width: 1100px;
  margin: 0 auto;
}
h1 { margin-top: 0; }
.status-grid {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  margin-bottom: 12px;
}
.target-card {
  min-width: 220px;
  background: #0b1320;
  padding: 12px;
  border-radius: 8px;
  box-shadow: 0 6px 18px rgba(0,0,0,0.6);
}
.big-status {
  display:flex;
  align-items:center;
  gap:16px;
  padding: 16px;
  margin: 8px 0 18px 0;
  border-radius: 10px;
  background: linear-gradient(90deg, rgba(0,0,0,0.45), rgba(10,16,24,0.5));
}
.big-status .dot {
  width: 28px;
  height: 28px;
  border-radius: 999px;
}
.timeline-row {
  display:flex;
  align-items:center;
  gap:8px;
  margin: 6px 0;
}
.timeline-canvas {
  height: 28px;
  width: 100%;
  background: #061023;
  border-radius: 6px;
  overflow: hidden;
}
.segment {
  height: 100%;
  display:inline-block;
}
.success { background: #19b44b; }
.warning { background: #f59e0b; }
.fail { background: #ef4444; }
.small-muted { color: #9fb0c8; font-size: 13px; }
#failures { margin-top: 6px; }
.failure-item { background: rgba(255,0,0,0.06); padding:8px; border-radius:6px; margin:6px 0; font-family: monospace; }
CSS

cat > public/app.js <<'JS'
async function fetchJson(url) {
  const r = await fetch(url);
  return r.json();
}

function iso(ts) {
  return new Date(ts).toLocaleString();
}

function createTargetCard(target, data) {
  const div = document.createElement('div');
  div.className = 'target-card';
  const last = data || {};
  div.innerHTML = `
    <h3>${target}</h3>
    <div><strong>Last:</strong> ${ last.ts ? iso(last.ts) : '—' }</div>
    <div><strong>Alive:</strong> ${ last.alive === 1 ? 'Yes' : last.alive === 0 ? 'No' : '—' }</div>
    <div><strong>Latency (ms):</strong> ${ last.time_ms ?? '—' }</div>
    <div class="small-muted">Raw: <code style="font-family:monospace">${ (last.raw || '').slice(0,120).replace(/\n/g,' ')}${ (last.raw||'').length>120 ? '…' : '' }</code></div>
  `;
  return div;
}

function renderStatusGrid(targets, latest) {
  const container = document.getElementById('statusGrid');
  container.innerHTML = '';
  targets.forEach(t => {
    container.appendChild(createTargetCard(t, latest[t]));
  });
}

function renderGlobalIndicator(latest) {
  let anyDown = false;
  let lastTs = 0;
  Object.values(latest).forEach(r => {
    if (!r) { anyDown = true; return; }
    if (r.alive === 0) anyDown = true;
    if (r.ts && r.ts > lastTs) lastTs = r.ts;
  });
  const el = document.getElementById('globalIndicator');
  const text = document.getElementById('globalText');
  const lastUpdate = document.getElementById('lastUpdate');
  text.textContent = anyDown ? 'Internet: DOWN' : 'Internet: UP';
  el.style.borderLeft = anyDown ? '6px solid #ef4444' : '6px solid #16a34a';
  lastUpdate.textContent = lastTs ? `Last sample: ${new Date(lastTs).toLocaleString()}` : '';
}

function buildAggregatedTimeline(entries) {
  const now = Date.now();
  const minutes = 24 * 60;
  const bucketSize = 60 * 1000;
  const start = now - minutes * bucketSize;
  const targets = [...new Set(entries.map(e => e.target))];
  const buckets = {};
  targets.forEach(t => {
    buckets[t] = new Array(minutes).fill(null).map(() => ({ok:0,total:0}));
  });
  entries.forEach(e => {
    const idx = Math.floor((e.ts - start) / bucketSize);
    if (idx < 0 || idx >= minutes) return;
    const b = buckets[e.target][idx];
    b.total++;
    if (e.alive === 1) b.ok++;
  });
  return { start, bucketSize, minutes, buckets, targets };
}

function renderTimeline(agg) {
  const container = document.getElementById('timelineArea');
  container.innerHTML = '';
  const targets = agg.targets.sort();
  targets.forEach(target => {
    const row = document.createElement('div');
    row.className = 'timeline-row';
    const label = document.createElement('div');
    label.style.minWidth = '140px';
    label.textContent = target;
    row.appendChild(label);

    const canvas = document.createElement('div');
    canvas.className = 'timeline-canvas';
    const frag = document.createDocumentFragment();
    const arr = agg.buckets[target];
    arr.forEach(bucket => {
      const seg = document.createElement('div');
      seg.className = 'segment';
      seg.style.width = `${100 / agg.minutes}%`;
      if (bucket.total === 0) {
        seg.classList.add('warning');
      } else {
        const ratio = bucket.ok / bucket.total;
        if (ratio >= 0.9) seg.classList.add('success');
        else if (ratio >= 0.5) seg.classList.add('warning');
        else seg.classList.add('fail');
      }
      frag.appendChild(seg);
    });
    canvas.appendChild(frag);
    row.appendChild(canvas);
    container.appendChild(row);
  });
}

function renderFailures(entries) {
  const failures = entries.filter(e => e.alive === 0).slice(-50).reverse();
  const container = document.getElementById('failures');
  if (failures.length === 0) {
    container.innerHTML = '<div class="small-muted">No failures in the database for the selected range.</div>';
    return;
  }
  container.innerHTML = '';
  failures.forEach(f => {
    const d = document.createElement('div');
    d.className = 'failure-item';
    d.innerHTML = `<div><strong>${f.target}</strong> — ${new Date(f.ts).toLocaleString()}</div>
                   <pre style="white-space:pre-wrap; margin: 6px 0 0 0; font-size:12px">${ (f.raw || '').slice(0,800) }</pre>`;
    container.appendChild(d);
  });
}

async function refreshAll() {
  try {
    const status = await fetchJson('/api/status');
    renderStatusGrid(status.targets, status.latest);
    renderGlobalIndicator(status.latest);

    const pingsResp = await fetchJson('/api/pings?hours=24');
    const entries = pingsResp.rows;
    const agg = buildAggregatedTimeline(entries);
    renderTimeline(agg);
    renderFailures(entries);
  } catch (e) {
    console.error(e);
  }
}

refreshAll();
setInterval(refreshAll, 10_000);
JS

# 5) Install npm deps (with better-sqlite3 attempt)
echo "\n--- Installing npm dependencies ---\n"
npm install express

# Try better-sqlite3 first
if npm install better-sqlite3 --no-audit --no-fund; then
  echo "better-sqlite3 installed successfully"
  START_FILE="server.js"
else
  echo "better-sqlite3 failed to install. Attempting build-from-source with increased swap..."
  # increase swap temporarily
  sudo dphys-swapfile swapoff || true
  sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
  sudo dphys-swapfile setup
  sudo dphys-swapfile swapon

  if npm install --build-from-source --verbose better-sqlite3 --no-audit --no-fund; then
    echo "better-sqlite3 built successfully after increasing swap"
    START_FILE="server.js"
  else
    echo "Still couldn't build better-sqlite3. Falling back to sqlite3 package."
    npm remove better-sqlite3 || true
    npm install sqlite3 --no-audit --no-fund
    START_FILE="server-sqlite3.js"
  fi

  # restore swap to conservative default
  sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=100/' /etc/dphys-swapfile || true
  sudo dphys-swapfile setup || true
  sudo dphys-swapfile swapon || true
fi

# 6) Install pm2 globally and start the app
echo "\n--- Installing pm2 and starting the monitor ---\n"
# Install pm2 globally for this user
npm install -g pm2

# ensure we start the selected server script
if [[ -z "${START_FILE:-}" ]]; then
  START_FILE="server.js"
fi

pm2 start "$START_FILE" --name "$PM2_NAME" || true
pm2 save

# Setup pm2 systemd startup (ensure PATH includes nvm's node)
echo "Running pm2 startup registration..."
sudo env PATH=$PATH:$(dirname "$(which node)") pm2 startup systemd -u $(whoami) --hp $HOME
# after running pm2 startup, re-save list
pm2 save

# 7) Create prune script and cron entry
cat > prune.sh <<'PRUNE'
#!/bin/bash
# prune old rows: pings older than 7 days, traceroutes older than 14 days
DB="$INSTALL_DIR/monitor.db"
if [[ -f "$DB" ]]; then
  sqlite3 "$DB" "DELETE FROM pings WHERE ts < $(($(date +%s) - 7*24*60*60))*1000;"
  sqlite3 "$DB" "DELETE FROM traceroutes WHERE ts < $(($(date +%s) - 14*24*60*60))*1000;"
fi
PRUNE

chmod +x prune.sh

# Add cron if not present
CRON_LINE="$CRON_TIME $INSTALL_DIR/prune.sh >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -F "$INSTALL_DIR/prune.sh") || (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -

# 8) Final info
IP_ADDR=$(hostname -I | awk '{print $1}') || true
echo "\n=== Done ==="
echo "Project installed to: $INSTALL_DIR"
echo "Start file: ${START_FILE}"
echo "Monitor should be visible at: http://${IP_ADDR}:3000 (use pi's LAN IP)"
echo "Use 'pm2 logs $PM2_NAME' to view logs and 'pm2 ls' to view status."

echo "If you used the fallback server (sqlite3), start file is server-sqlite3.js."

exit 0