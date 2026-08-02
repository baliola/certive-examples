#!/usr/bin/env python3
# Certive EDMS — Batch Document Stamp (Python)

import hashlib
import os
import sys
import time
from datetime import date
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

API_BASE = "https://api.certive.id/api"
API_KEY  = (os.environ.get("CERTIVE_API_KEY") or "").strip() or None

if not API_KEY:
    print("Error: CERTIVE_API_KEY is not set.", file=sys.stderr)
    print(f"  Expected: {Path(__file__).parent / '.env'} with CERTIVE_API_KEY=ck_...", file=sys.stderr)
    sys.exit(1)

HEADERS = {
    "Content-Type": "application/json",
    "X-API-Key": API_KEY,
}


# ─── Step 1: Compute SHA-256 for each file ───────────────────────────────────
# Each file is hashed locally. Only the hex digests are transmitted to Certive —
# the files themselves are never uploaded.

def compute_sha256(file_path: Path) -> str:
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def build_items(file_paths: list[Path]) -> list[dict]:
    items = []
    for file_path in file_paths:
        resolved = file_path.resolve()
        if not resolved.exists():
            raise FileNotFoundError(f"File not found: {resolved}")
        items.append({
            "hashValue":   compute_sha256(resolved),
            "fileName":    resolved.name,
            "fileSize":    resolved.stat().st_size,
            "description": f"Stamped on {date.today().isoformat()}: {resolved.name}",
        })
    return items


# ─── Step 2: Submit the batch job ────────────────────────────────────────────
# API key callers do not need an OTP — the org is resolved from the key.
# anchoringMode is omitted to let the API auto-select (Merkle for ≥10 docs,
# Direct otherwise).

def submit_batch(batch_name: str, items: list[dict]) -> dict:
    response = requests.post(
        f"{API_BASE}/stamp/batch",
        headers=HEADERS,
        json={"batchName": batch_name, "items": items},
    )
    body = response.json()
    if not response.ok:
        code = body.get("error", {}).get("code", "UNKNOWN")
        raise RuntimeError(f"Batch submit failed [{code}]: {body.get('message')}")
    return body["data"]  # { jobId }


# ─── Step 3: Poll job status ─────────────────────────────────────────────────
# Batch jobs move through: queued → processing → completed | failed | partial_failure.
# Poll until one of the terminal statuses is reached.

def poll_batch_status(job_id: str, interval_s: float = 5.0, timeout_s: float = 300.0) -> dict:
    deadline = time.monotonic() + timeout_s

    while time.monotonic() < deadline:
        response = requests.get(f"{API_BASE}/documents/batch/{job_id}", headers=HEADERS)
        body = response.json()

        if not response.ok:
            code = body.get("error", {}).get("code", "UNKNOWN")
            raise RuntimeError(f"Status check failed [{code}]: {body.get('message')}")

        job = body["data"]["job"]
        print(f"  Status: {job['status']} | {job['stampedCount']}/{job['totalCount']} stamped, {job['failedCount']} failed")

        if job["status"] in ("completed", "failed", "partial_failure"):
            return job

        time.sleep(interval_s)

    raise TimeoutError(f"Timed out after {timeout_s}s waiting for batch completion.")


# ─── Step 4: Fetch per-item results ──────────────────────────────────────────

def fetch_items(job_id: str) -> list[dict]:
    response = requests.get(
        f"{API_BASE}/documents/batch/{job_id}/items",
        headers=HEADERS,
        params={"limit": 100},
    )
    body = response.json()
    if not response.ok:
        code = body.get("error", {}).get("code", "UNKNOWN")
        raise RuntimeError(f"Failed to fetch items [{code}]: {body.get('message')}")
    return body["data"]["items"]


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        print("Usage: python batch_stamp.py <file1> <file2> [file3 ...]", file=sys.stderr)
        print("Minimum 2 files required for a batch job.", file=sys.stderr)
        sys.exit(1)

    file_paths = [Path(p) for p in sys.argv[1:]]
    print(f"Files  : {len(file_paths)} file(s)")

    print("\n[1/4] Computing SHA-256 hashes...")
    items = build_items(file_paths)
    for item in items:
        print(f"  {item['hashValue'][:16]}...  {item['fileName']}")

    batch_name = f"API Batch {date.today().isoformat()}"

    print(f'\n[2/4] Submitting batch job "{batch_name}"...')
    result  = submit_batch(batch_name, items)
    job_id  = result["jobId"]
    print(f"Job ID : {job_id}")

    print("\n[3/4] Waiting for job to complete...")
    job = poll_batch_status(job_id)

    print("\n[4/4] Fetching per-item results...")
    stamped_items = fetch_items(job_id)

    print("\nResults:")
    for item in stamped_items:
        doc    = item.get("document") or {}
        status = item["status"].ljust(10)
        h      = item["hashValue"][:16] + "..."
        tx     = (doc.get("txHash") or "")[:16]
        tx_str = (tx + "...") if tx else "—"
        print(f"  [{status}]  {h}  {item.get('fileName') or '—'}  tx: {tx_str}")

    print(f"\nBatch complete. Status: {job['status']}")
    if job["status"] == "partial_failure":
        print(f"  {job['failedCount']} item(s) failed. To retry, call POST /stamp/batch/{job_id}/retry.")
    if job.get("anchorTxHash"):
        print(f"  Anchor tx: {job['anchorTxHash']}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)
