// public/app.js
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
  el.style.borderLeft = anyDown ? '50px solid #ef4444' : '50px solid #16a34a';
  lastUpdate.textContent = lastTs ? `Last sample: ${new Date(lastTs).toLocaleString()}` : '';
}

function buildAggregatedTimeline(entries) {
  const now = Date.now();
  const minutes = 12 * 60;
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

async function fetchLatestTraceroute(target) {
  try {
    const resp = await fetchJson(`/api/traceroute?target=${encodeURIComponent(target)}`);
    if (!resp.ok) return null;
    return resp.row || null;
  } catch (e) {
    console.error('traceroute fetch error', e);
    return null;
  }
}

function renderTraceroute(row) {
  const el = document.getElementById('traceroute-1111');
  if (!el) return;
  if (!row) {
    el.textContent = 'No traceroute available for 1.1.1.1';
    return;
  }
  const ts = row.ts ? `Recorded: ${new Date(row.ts).toLocaleString()}\n\n` : '';
  el.textContent = ts + (row.raw || '').trim();
}

async function refreshAll() {
  try {
    const status = await fetchJson('/api/status');
    renderStatusGrid(status.targets, status.latest);
    renderGlobalIndicator(status.latest);

    // fetch last 24 hours of pings and render timeline & failures
    const pingsResp = await fetchJson('/api/pings?hours=12');
    const entries = pingsResp.rows || [];
    const agg = buildAggregatedTimeline(entries);
    renderTimeline(agg);
    renderFailures(entries);

    // fetch latest traceroute for 1.1.1.1 and render
    const traceRow = await fetchLatestTraceroute('1.1.1.1');
    renderTraceroute(traceRow);

  } catch (e) {
    console.error(e);
  }
}

refreshAll();
setInterval(refreshAll, 10_000);
