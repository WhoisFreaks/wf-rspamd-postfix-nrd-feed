#!/usr/bin/env bash
# wf-nrd-fetch.sh — WhoisFreaks NRD feed fetcher for Rspamd
#
# Daily run:  fetches yesterday's gTLD + ccTLD files (already-cached days skipped)
# First run:  backfills all WINDOW_DAYS days automatically
#
# Usage:
#   WINDOW_DAYS=10 /usr/local/bin/wf-nrd-fetch.sh
#
# Environment:
#   WINDOW_DAYS   Rolling window size in days (default: 10)
#   API_KEY_FILE  Path to the WhoisFreaks API key file
#                 (default: /etc/whoisfreaks/apikey)

set -uo pipefail
# Note: -e is intentionally omitted — arithmetic increments and grep returning
# no matches both exit non-zero, which would kill the script under -e.

# ── Configuration ──────────────────────────────────────────────────────────────
WINDOW_DAYS="${WINDOW_DAYS:-10}"
API_KEY_FILE="${API_KEY_FILE:-/etc/whoisfreaks/apikey}"
CACHE_DIR="/var/cache/wf-nrd"
MAP_FILE="/var/lib/rspamd/maps/nrd_domains.map"
BASE_URL="https://files.whoisfreaks.com/v3.1/download/domainer"
LOG_TAG="[wf-nrd]"

# ── Validate API key ───────────────────────────────────────────────────────────
if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "$LOG_TAG ERROR: API key file not found at $API_KEY_FILE" >&2
  echo "$LOG_TAG Run: echo 'YOUR_KEY' | sudo tee $API_KEY_FILE && sudo chmod 600 $API_KEY_FILE" >&2
  exit 1
fi

API_KEY=$(cat "$API_KEY_FILE")
if [[ -z "$API_KEY" ]]; then
  echo "$LOG_TAG ERROR: API key file is empty." >&2
  exit 1
fi

# ── Setup ──────────────────────────────────────────────────────────────────────
mkdir -p "$CACHE_DIR"
echo "$LOG_TAG Starting NRD fetch (window: ${WINDOW_DAYS} days)"

# ── Backfill loop: fetch all WINDOW_DAYS days ─────────────────────────────────
# WhoisFreaks publishes the previous day's registrations after consolidation.
# We iterate from 1 day ago back to WINDOW_DAYS days ago.
# Already-cached files are skipped — daily runs only download 1 new day,
# while the first run automatically backfills the full window.

NEW_DOWNLOADS=0
FAILED=0

for (( i=1; i<=WINDOW_DAYS; i++ )); do
  DATE=$(date -u -d "${i} days ago" +%Y-%m-%d)

  for TYPE in gtld cctld; do
    OUT="$CACHE_DIR/${DATE}_${TYPE}.txt"

    if [[ -f "$OUT" ]]; then
      echo "$LOG_TAG Skipping ${TYPE} for ${DATE} (cached)"
      continue
    fi

    echo "$LOG_TAG Fetching ${TYPE} for ${DATE}..."

    # Capture HTTP status separately; don't let curl failure exit the script
    HTTP_STATUS=$(curl -sSL \
      --write-out "%{http_code}" \
      --output "$OUT.gz" \
      "${BASE_URL}/${TYPE}?apiKey=${API_KEY}&date=${DATE}&whois=false" \
      2>/dev/null)
    CURL_EXIT=$?

    if [[ $CURL_EXIT -eq 0 && "$HTTP_STATUS" == "200" ]]; then
      # Decompress + normalize into plain text cache file
      # grep exits 1 if no lines match — use || true to keep going
      zcat "$OUT.gz" \
        | tr -d '\r' \
        | tr '[:upper:]' '[:lower:]' \
        | grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' \
        > "$OUT" || true
      rm -f "$OUT.gz"
      LINES=$(wc -l < "$OUT")
      echo "$LOG_TAG Fetched ${TYPE} for ${DATE}: ${LINES} domains"
      NEW_DOWNLOADS=$(( NEW_DOWNLOADS + 1 ))
    else
      rm -f "$OUT.gz"
      echo "$LOG_TAG WARNING: Failed to fetch ${TYPE} for ${DATE} (HTTP ${HTTP_STATUS}, curl exit ${CURL_EXIT}) — skipping" >&2
      FAILED=$(( FAILED + 1 ))
    fi
  done
done

# ── Evict files outside the window ────────────────────────────────────────────
EVICTED=$(find "$CACHE_DIR" -name "*.txt" -mtime +"$WINDOW_DAYS" -print -delete | wc -l)
if [[ "$EVICTED" -gt 0 ]]; then
  echo "$LOG_TAG Evicted ${EVICTED} expired cache file(s)"
fi

# ── Rebuild map atomically ─────────────────────────────────────────────────────
CACHE_FILES=$(find "$CACHE_DIR" -name "*.txt" | wc -l)
if [[ "$CACHE_FILES" -eq 0 ]]; then
  echo "$LOG_TAG WARNING: No cached files found — map not updated" >&2
  exit 1
fi

TMP=$(mktemp)
cat "$CACHE_DIR"/*.txt | sort -u > "$TMP"
mv "$TMP" "$MAP_FILE"

# Fix ownership so Rspamd (_rspamd user) can read the file
chown _rspamd:_rspamd /var/lib/rspamd/maps "$MAP_FILE"
chmod 755 /var/lib/rspamd/maps
chmod 644 "$MAP_FILE"

TOTAL=$(wc -l < "$MAP_FILE")
echo "$LOG_TAG Map updated: ${TOTAL} unique domains (${WINDOW_DAYS}-day window, ${NEW_DOWNLOADS} new downloads, ${FAILED} failed)"
echo "$LOG_TAG Done."