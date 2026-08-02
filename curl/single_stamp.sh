#!/usr/bin/env bash
# Certive EDMS — Single Document Stamp (cURL)

set -euo pipefail

API_BASE="https://api.certive.id/api"

if [[ -z "${CERTIVE_API_KEY:-}" ]]; then
  echo "Error: CERTIVE_API_KEY is not set."
  echo "  export CERTIVE_API_KEY=ck_your_api_key_here"
  exit 1
fi

FILE="${1:-}"
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "Usage: bash single_stamp.sh <file>"
  exit 1
fi

FILE_NAME=$(basename "$FILE")
FILE_SIZE=$(wc -c < "$FILE" | tr -d ' ')

# ─── Step 1: Compute SHA-256 ──────────────────────────────────────────────────
# The file is hashed locally. Only the hex digest is transmitted to Certive —
# the file itself is never uploaded.

echo "[1/3] Computing SHA-256 hash..."
if command -v sha256sum &>/dev/null; then
  HASH=$(sha256sum "$FILE" | awk '{print $1}')
else
  HASH=$(shasum -a 256 "$FILE" | awk '{print $1}')
fi
echo "Hash   : $HASH"

# ─── Step 2: Submit the stamp ────────────────────────────────────────────────

echo ""
echo "[2/3] Submitting stamp request..."
STAMP_RESPONSE=$(curl --silent --fail-with-body \
  --request POST "${API_BASE}/stamp" \
  --header "Content-Type: application/json" \
  --header "X-API-Key: ${CERTIVE_API_KEY}" \
  --data "{
    \"hashValue\":   \"${HASH}\",
    \"fileName\":    \"${FILE_NAME}\",
    \"fileSize\":    ${FILE_SIZE},
    \"description\": \"Stamped on $(date +%Y-%m-%d): ${FILE_NAME}\"
  }") || {
  CODE=$(echo "$STAMP_RESPONSE" | jq -r '.error.code // "UNKNOWN"')
  MSG=$(echo "$STAMP_RESPONSE" | jq -r '.message // "Request failed"')
  echo "Error: Stamp failed [${CODE}]: ${MSG}" >&2
  exit 1
}

DOCUMENT_ID=$(echo "$STAMP_RESPONSE" | jq -r '.data.documentId')
PUBLIC_VERIFY_URL=$(echo "$STAMP_RESPONSE" | jq -r '.data.publicVerifyUrl')

echo "Document ID : $DOCUMENT_ID"

# ─── Step 3: Poll for status ─────────────────────────────────────────────────
# POST /stamp is async. Poll GET /stamp/:documentId until status leaves "Pending".

echo ""
echo "[3/3] Waiting for on-chain confirmation..."
TIMEOUT=120
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS_RESPONSE=$(curl --silent --fail-with-body \
    --header "X-API-Key: ${CERTIVE_API_KEY}" \
    "${API_BASE}/documents/${DOCUMENT_ID}") || {
    CODE=$(echo "$STATUS_RESPONSE" | jq -r '.error.code // "UNKNOWN"')
    MSG=$(echo "$STATUS_RESPONSE" | jq -r '.message // "Request failed"')
    echo "Error: Status check failed [${CODE}]: ${MSG}" >&2
    exit 1
  }

  STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.data.status')
  TX_HASH=$(echo "$STATUS_RESPONSE" | jq -r '.data.txHash // ""')

  echo "  Status: $STATUS${TX_HASH:+ | tx: $TX_HASH}"

  if [[ "$STATUS" == "Stamped" ]]; then
    break
  fi
  if [[ "$STATUS" == "Failed" ]]; then
    echo "Error: Stamping failed on-chain."
    echo "  To retry, call: POST /stamp/${DOCUMENT_ID}/retry"
    exit 1
  fi

  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "Error: Timed out after ${TIMEOUT}s."
  exit 1
fi

echo ""
echo "Stamp confirmed."
echo "Transaction : $TX_HASH"
echo "Verify URL  : $PUBLIC_VERIFY_URL"
