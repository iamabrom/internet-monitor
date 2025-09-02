#!/usr/bin/env bash
set -euo pipefail

# export_daily_csv.sh
# Usage:
#   ./export_daily_csv.sh            # exports yesterday (local date)
#   ./export_daily_csv.sh 2025-09-01 # exports that specific date (YYYY-MM-DD)
#
# Produces a CSV with 1440 minutes * 5 targets = 7200 rows for the given day.

# CONFIG - update these paths if your setup differs
PROJECT_DIR="${HOME}/lan-internet-monitor"
DB_FILE="${PROJECT_DIR}/monitor.db"
OUT_DIR="${PROJECT_DIR}/reports"
TARGETS_SQL="(VALUES ('google.com'),('8.8.8.8'),('1.1.1.1'),('frontier.com'),('192.168.2.1'))"

# choose day to export (default = yesterday)
DAY="${1:-$(date -d 'yesterday' +%F)}"

# compute ms epoch for start of day and end of day
START_S=$(date -d "${DAY} 00:00:00" +%s)
END_S=$((START_S + 24*60*60))
START_MS=$((START_S * 1000))
END_MS=$((END_S * 1000))

mkdir -p "${OUT_DIR}"

OUTFILE="${OUT_DIR}/ping-report-${DAY}.csv"

echo "Exporting day=${DAY} (start_ms=${START_MS}) -> ${OUTFILE}"
echo "This may take a few seconds..."

# SQL: generate 1440 minute slots, cross join 5 targets, left join aggregated ping stats
read -r -d '' SQL <<EOF
-- header row added by sqlite3 -header -csv
WITH
  -- generate 1440 minutes starting from START_MS
  RECURSIVE minutes(idx, ts) AS (
    SELECT 0, ${START_MS}
    UNION ALL
    SELECT idx+1, ts + 60000 FROM minutes WHERE idx < 1439
  ),

  -- targets set
  targets(t) AS (
    ${TARGETS_SQL}
  ),

  -- aggregated ping stats per-minute per-target within the requested window
  agg AS (
    SELECT
      ( (p.ts / 60000) * 60000 ) AS minute_ts,
      p.target AS target,
      COUNT(*) AS total,
      SUM(CASE WHEN p.alive = 1 THEN 1 ELSE 0 END) AS success_count,
      AVG(p.time_ms) AS avg_ms
    FROM pings p
    WHERE p.ts >= ${START_MS} AND p.ts < ${END_MS}
    GROUP BY minute_ts, p.target
  )

SELECT
  datetime(m.ts/1000, 'unixepoch', 'localtime') AS minute,
  t.t AS target,
  COALESCE(a.success_count, 0) AS success_count,
  COALESCE(a.total, 0) AS total,
  CASE
    WHEN COALESCE(a.total,0) = 0 THEN '0.000'
    ELSE printf('%.3f', COALESCE(a.success_count,0) * 1.0 / a.total)
  END AS success_ratio,
  CASE
    WHEN a.avg_ms IS NULL THEN ''
    ELSE printf('%.2f', a.avg_ms)
  END AS avg_ms,
  CASE
    WHEN COALESCE(a.total,0) = 0 THEN 'no_data'
    WHEN COALESCE(a.success_count,0) * 1.0 / a.total >= 0.9 THEN 'UP'
    WHEN COALESCE(a.success_count,0) * 1.0 / a.total >= 0.5 THEN 'DEGRADED'
    ELSE 'DOWN'
  END AS result
FROM minutes m
CROSS JOIN targets t
LEFT JOIN agg a ON a.minute_ts = m.ts AND a.target = t.t
ORDER BY m.ts ASC, t.t ASC;
EOF

# Run sqlite3 to produce csv. We use -header and -csv.
sqlite3 -header -csv "${DB_FILE}" "${SQL}" > "${OUTFILE}"

# print summary
LINE_COUNT=$(wc -l < "${OUTFILE}" || echo 0)
echo "Wrote ${OUTFILE} (${LINE_COUNT} lines, including header)."
echo "Done."
