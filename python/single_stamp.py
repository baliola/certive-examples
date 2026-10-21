#!/usr/bin/env python3
# Certive EDMS — Single Document Stamp (Python)

import hashlib
import os
import sys
import time
from datetime import date
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

API_BASE = "https://api.certive.io/api"
API_KEY  = (os.environ.get("CERTIVE_API_KEY") or "").strip() or None

if not API_KEY:
    print("Error: CERTIVE_API_KEY is not set.", file=sys.stderr)
    print(f"  Expected: {Path(__file__).parent / '.env'} with CERTIVE_API_KEY=ck_...", file=sys.stderr)
    sys.exit(1)

HEADERS = {
    "Content-Type": "application/json",
    "X-API-Key": API_KEY,
}


# ─── Step 1: Compute SHA-256 ──────────────────────────────────────────────────
# The file is hashed locally. Only the hex digest is transmitted to Certive —
# the file itself is never uploaded.

def compute_sha256(file_path: Path) -> str:
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# ─── Step 2: Submit the stamp ────────────────────────────────────────────────

def stamp_document(hash_value: str, file_name: str, file_size: int, description: str) -> dict:
    response = requests.post(
        f"{API_BASE}/stamp",
        headers=HEADERS,
        json={
            "hashValue":   hash_value,
            "fileName":    file_name,
            "fileSize":    file_size,
            "description": description,
        },
    )
    body = response.json()
    if not response.ok:
        code = body.get("error", {}).get("code", "UNKNOWN")
        raise RuntimeError(f"Stamp failed [{code}]: {body.get('message')}")
    return body["data"]  # { documentId, publicVerifyUrl }


# ─── Step 3: Poll for status ─────────────────────────────────────────────────
# POST /stamp is async — the document starts as "Pending" while the blockchain
# transaction is processed. Poll until status is "Stamped" or "Failed".

def poll_status(document_id: str, interval_s: float = 3.0, timeout_s: float = 120.0) -> dict:
    deadline = time.monotonic() + timeout_s

    while time.monotonic() < deadline:
        response = requests.get(f"{API_BASE}/documents/{document_id}", headers=HEADERS)
        body = response.json()

        if not response.ok:
            code = body.get("error", {}).get("code", "UNKNOWN")
            raise RuntimeError(f"Status check failed [{code}]: {body.get('message')}")

        data   = body["data"]
        status = data["status"]
        tx     = data.get("txHash") or ""
        print(f"  Status: {status}" + (f" | tx: {tx}" if tx else ""))

        if status == "Stamped":
            return data
        if status == "Failed":
            raise RuntimeError(f"Stamping failed on-chain. To retry, call POST /stamp/{document_id}/retry.")

        time.sleep(interval_s)

    raise TimeoutError(f"Timed out after {timeout_s}s waiting for stamp confirmation.")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: python single_stamp.py <file>", file=sys.stderr)
        sys.exit(1)

    file_path = Path(sys.argv[1]).resolve()
    if not file_path.exists():
        print(f"Error: File not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    file_name = file_path.name
    file_size = file_path.stat().st_size

    print(f"File   : {file_name}")
    print(f"Size   : {file_size} bytes")

    print("\n[1/3] Computing SHA-256 hash...")
    hash_value = compute_sha256(file_path)
    print(f"Hash   : {hash_value}")

    print("\n[2/3] Submitting stamp request...")
    data = stamp_document(
        hash_value=hash_value,
        file_name=file_name,
        file_size=file_size,
        description=f"Stamped on {date.today().isoformat()}: {file_name}",
    )
    document_id     = data["documentId"]
    public_verify_url = data["publicVerifyUrl"]
    print(f"Document ID : {document_id}")

    print("\n[3/3] Waiting for on-chain confirmation...")
    result = poll_status(document_id)

    print("\nStamp confirmed.")
    print(f"Transaction : {result.get('txHash')}")
    print(f"Verify URL  : {public_verify_url}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)
