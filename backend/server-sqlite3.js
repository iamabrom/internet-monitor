// server-sqlite3.js - fallback using sqlite3 (async)
const express = require('express');
const { exec } = require('child_process');
const os = require('os');
const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const app = express();
const dbFile = path.join(__dirname, 'monitor.db');
const db = new sqlite3.Database(dbFile);

// Targets
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
          const stmt = db.prepare(`INSERT INTO pings (ts,target,alive,time_ms,ttl,raw) VALUES (?,?,?,?,?,?)`);
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
          const stmt = db.prepare(`INSERT INTO traceroutes (ts,target,raw) VALUES (?,?,?)`);
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

// Serve UI
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
