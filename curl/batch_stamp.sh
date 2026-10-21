#!/usr/bin/env bash
# Certive EDMS — Batch Document Stamp (cURL)

set -euo pipefail

API_BASE="https://api.certive.io/api"

if [[ -z "${CERTIVE_API_KEY:-}" ]]; then
  echo "Error: CERTIVE_API_KEY is not set."
  echo "  export CERTIVE_API_KEY=ck_your_api_key_here"
  exit 1
fi

if [[ $# -lt 2 ]]; then
  echo "Usage: bash batch_stamp.sh <file1> <file2> [file3 ...]"
  echo "Minimum 2 files required for a batch job."
  exit 1
fi

# ─── Step 1: Compute SHA-256 for each file ───────────────────────────────────
# Each file is hashed locally. Only the hex digests are transmitted to Certive —
# the files themselves are never uploaded.

sha256_of() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

echo "Files  : $# file(s)"

echo ""
echo "[1/4] Computing SHA-256 hashes..."

ITEMS_JSON=""
for FILE in "$@"; do
  if [[ ! -f "$FILE" ]]; then
    echo "Error: File not found: $FILE" >&2
    exit 1
  fi
  HASH=$(sha256_of "$FILE")
  NAME=$(basename "$FILE")
  SIZE=$(wc -c < "$FILE" | tr -d ' ')
  DATE=$(date +%Y-%m-%d)
  echo "  ${HASH:0:16}...  $NAME"
  ITEM=$(jq -n \
    --arg  h "$HASH" \
    --arg  n "$NAME" \
    --argjson s "$SIZE" \
    --arg  d "Stamped on ${DATE}: ${NAME}" \
    '{hashValue:$h,fileName:$n,fileSize:$s,description:$d}')
  ITEMS_JSON="${ITEMS_JSON:+${ITEMS_JSON},}${ITEM}"
done

# ─── Step 2: Submit the batch job ────────────────────────────────────────────
# API key callers do not need an OTP — the org is resolved from the key.
# anchoringMode is omitted to let the API auto-select (Merkle for ≥10 docs,
# Direct otherwise).

BATCH_NAME="API Batch $(date +%Y-%m-%d)"

echo ""
echo "[2/4] Submitting batch job \"${BATCH_NAME}\"..."

BODY=$(jq -n \
  --arg     name  "$BATCH_NAME" \
  --argjson items "[${ITEMS_JSON}]" \
  '{batchName:$name,items:$items}')

SUBMIT_RESPONSE=$(curl --silent --fail-with-body \
  --request POST "${API_BASE}/stamp/batch" \
  --header "Content-Type: application/json" \
  --header "X-API-Key: ${CERTIVE_API_KEY}" \
  --data "$BODY") || {
  CODE=$(echo "$SUBMIT_RESPONSE" | jq -r '.error.code // "UNKNOWN"')
  MSG=$(echo "$SUBMIT_RESPONSE" | jq -r '.message // "Request failed"')
  echo "Error: Batch submit failed [${CODE}]: ${MSG}" >&2
  exit 1
}

JOB_ID=$(echo "$SUBMIT_RESPONSE" | jq -r '.data.jobId')
echo "Job ID : ${JOB_ID}"

# ─── Step 3: Poll job status ─────────────────────────────────────────────────
# Batch jobs move through: queued → processing → completed | failed | partial_failure.
# Poll until one of the terminal statuses is reached.

echo ""
echo "[3/4] Waiting for job to complete..."

TIMEOUT=300
ELAPSED=0
INTERVAL=5
JOB_STATUS=""
STATUS_RESPONSE=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS_RESPONSE=$(curl --silent --fail-with-body \
    --header "X-API-Key: ${CERTIVE_API_KEY}" \
    "${API_BASE}/documents/batch/${JOB_ID}") || {
    CODE=$(echo "$STATUS_RESPONSE" | jq -r '.error.code // "UNKNOWN"')
    MSG=$(echo "$STATUS_RESPONSE" | jq -r '.message // "Request failed"')
    echo "Error: Status check failed [${CODE}]: ${MSG}" >&2
    exit 1
  }

  JOB_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.data.job.status')
  STAMPED=$(echo "$STATUS_RESPONSE"    | jq -r '.data.job.stampedCount')
  TOTAL=$(echo "$STATUS_RESPONSE"      | jq -r '.data.job.totalCount')
  FAILED=$(echo "$STATUS_RESPONSE"     | jq -r '.data.job.failedCount')

  echo "  Status: ${JOB_STATUS} | ${STAMPED}/${TOTAL} stamped, ${FAILED} failed"

  if [[ "$JOB_STATUS" == "completed" || "$JOB_STATUS" == "failed" || "$JOB_STATUS" == "partial_failure" ]]; then
    break
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "Error: Timed out after ${TIMEOUT}s waiting for batch completion."
  exit 1
fi

# ─── Step 4: Fetch per-item results ──────────────────────────────────────────

echo ""
echo "[4/4] Fetching per-item results..."

ITEMS_RESPONSE=$(curl --silent --fail-with-body \
  --header "X-API-Key: ${CERTIVE_API_KEY}" \
  "${API_BASE}/documents/batch/${JOB_ID}/items?limit=100") || {
  CODE=$(echo "$ITEMS_RESPONSE" | jq -r '.error.code // "UNKNOWN"')
  MSG=$(echo "$ITEMS_RESPONSE" | jq -r '.message // "Request failed"')
  echo "Error: Failed to fetch items [${CODE}]: ${MSG}" >&2
  exit 1
}

echo ""
echo "Results:"
while IFS=$'\t' read -r STATUS HASH FILENAME TX; do
  PADDED=$(printf "%-10s" "$STATUS")
  TX_STR="${TX:+${TX:0:16}...}"
  TX_STR="${TX_STR:-—}"
  printf "  [%s]  %s...  %s  tx: %s\n" "$PADDED" "${HASH:0:16}" "${FILENAME:-—}" "$TX_STR"
done < <(echo "$ITEMS_RESPONSE" | jq -r \
  '.data.items[] | [.status, .hashValue, (.fileName // ""), (.document.txHash // "")] | @tsv')

ANCHOR_TX=$(echo "$STATUS_RESPONSE" | jq -r '.data.job.anchorTxHash // ""')

echo ""
echo "Batch complete. Status: ${JOB_STATUS}"
if [[ "$JOB_STATUS" == "partial_failure" ]]; then
  echo "  ${FAILED} item(s) failed. To retry, call POST /stamp/batch/${JOB_ID}/retry."
fi
if [[ -n "$ANCHOR_TX" ]]; then
  echo "  Anchor tx: ${ANCHOR_TX}"
fi
