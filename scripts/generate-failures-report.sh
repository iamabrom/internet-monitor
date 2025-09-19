#!/usr/bin/env bash
set -euo pipefail

# generate-failures-report.sh
# Produces a CSV listing all ping failures keyed on 1.1.1.1, with the status of the other targets.
#
# Usage:
#   ./generate-failures-report.sh            # exports for yesterday (local date)
#   ./generate-failures-report.sh 2025-09-01 # exports for specific date (YYYY-MM-DD)
#
# Places output at: ~/lan-internet-monitor/reports/ping-failures-YYYY-MM-DD.csv
# Designed to be robust against "database is locked" by using PRAGMA busy_timeout + retries.
# Assumes WAL has been enabled on the DB (recommended): sqlite3 monitor.db "PRAGMA journal_mode=WAL;"

BASE_DIR="${HOME}/lan-internet-monitor"
SCRIPTS_DIR="${BASE_DIR}/scripts"
REPORTS_DIR="${BASE_DIR}/reports"
DB_FILE="${BASE_DIR}/monitor.db"

# Tolerance window (ms) around the 1.1.1.1 failure timestamp to look for other-target responses.
TOL_MS=1500

# Define targets
TARGET_KEY="1.1.1.1"
TARGETS_OTHER=("8.8.8.8" "google.com" "frontier.com" "192.168.2.1")

# Day to export
DAY="${1:-$(date -d 'yesterday' +%F)}"

# Time range in ms
START_S=$(date -d "${DAY} 00:00:00" +%s)
END_S=$((START_S + 24*60*60))
START_MS=$((START_S * 1000))
END_MS=$((END_S * 1000))

mkdir -p "${REPORTS_DIR}"

OUTFILE="${REPORTS_DIR}/ping-failures-${DAY}.csv"
OUTFILE_TMP="${OUTFILE}.inprogress.$(date +%s)"
TMP_SQL="$(mktemp /tmp/generate_failures_sql_XXXXXX.sql)"
SQLERR="$(mktemp /tmp/generate_failures_sqlerr_XXXXXX.log)"
trap 'rm -f "${TMP_SQL}" "${SQLERR}" || true' EXIT

echo
echo "Generating failures report for ${DAY}"
echo " DB:       ${DB_FILE}"
echo " Output:   ${OUTFILE}"
echo " Temp out: ${OUTFILE_TMP}"
echo " Range ms: ${START_MS} -> ${END_MS}"
echo " Tolerance ms: +/- ${TOL_MS}"
echo

# Basic checks
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 is not installed. Install with: sudo apt install sqlite3"
  exit 1
fi

if [ ! -f "${DB_FILE}" ]; then
  echo "ERROR: DB not found at ${DB_FILE}"
  exit 1
fi

# Build the SQL template into the temp SQL file with header/mode settings and numeric substitution
{
  echo "-- Generated SQL for ${DAY} (TOL=${TOL_MS})"
  echo ".headers on"
  echo ".mode csv"
} > "${TMP_SQL}"

# Append the query, substituting TOL, START_MS, END_MS by using awk to replace tokens.
awk -v TOL="${TOL_MS}" -v START_MS="${START_MS}" -v END_MS="${END_MS}" '{
  gsub("TOL",TOL);
  gsub("START_MS",START_MS);
  gsub("END_MS",END_MS);
  print
}' <<'AWK_SQL' >> "${TMP_SQL}"
SELECT
  datetime(f.ts/1000,'unixepoch','localtime') AS datetime,
  'fail' AS "1.1.1.1",
  CASE
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='8.8.8.8' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 1) THEN 'success'
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='8.8.8.8' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 0) THEN 'fail'
    ELSE 'no_data'
  END AS "8.8.8.8",
  CASE
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='google.com' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 1) THEN 'success'
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='google.com' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 0) THEN 'fail'
    ELSE 'no_data'
  END AS "google.com",
  CASE
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='frontier.com' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 1) THEN 'success'
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='frontier.com' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 0) THEN 'fail'
    ELSE 'no_data'
  END AS "frontier.com",
  CASE
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='192.168.2.1' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 1) THEN 'success'
    WHEN EXISTS (SELECT 1 FROM pings p2 WHERE p2.target='192.168.2.1' AND p2.ts BETWEEN f.ts - TOL AND f.ts + TOL AND p2.alive = 0) THEN 'fail'
    ELSE 'no_data'
  END AS "Local DNS"
FROM pings f
WHERE f.target = '1.1.1.1'
  AND f.alive = 0
  AND f.ts >= START_MS
  AND f.ts < END_MS
ORDER BY f.ts ASC;
AWK_SQL

# Attempt sqlite3 with retries & busy_timeout to handle transient locks
ATTEMPTS=5
RC=1
for attempt in $(seq 1 $ATTEMPTS); do
  echo "sqlite3 attempt ${attempt}/${ATTEMPTS}..."
  # Use PRAGMA busy_timeout to have sqlite wait for locks (10000 ms)
  sqlite3 -cmd "PRAGMA busy_timeout=10000;" "${DB_FILE}" < "${TMP_SQL}" > "${OUTFILE_TMP}" 2> "${SQLERR}" && RC=0 && break || RC=$?
  # If stderr indicates lock, back off and retry
  if grep -qi "database is locked" "${SQLERR}" 2>/dev/null; then
    echo "  database is locked on attempt ${attempt}. backing off..."
    sleep $((attempt * 2))
    continue
  fi
  # If other error, show first lines of stderr and abort
  if [ -s "${SQLERR}" ]; then
    echo "  sqlite3 error (non-lock). stderr (first 200 lines):"
    sed -n '1,200p' "${SQLERR}" || true
    rm -f "${OUTFILE_TMP}"
    exit "${RC}"
  fi
done

if [ "${RC}" -ne 0 ]; then
  echo "All sqlite3 attempts failed (RC=${RC}). See ${SQLERR} for details."
  rm -f "${OUTFILE_TMP}"
  exit 1
fi

# Move temp file to final file atomically
mv -f "${OUTFILE_TMP}" "${OUTFILE}"

# Post-run summary
LINE_COUNT=$(wc -l < "${OUTFILE}" 2>/dev/null || echo 0)
echo
echo "Wrote ${OUTFILE} (${LINE_COUNT} lines, including header)."
echo "Preview (first 20 lines):"
head -n 20 "${OUTFILE}" || true
echo
echo "Done."
