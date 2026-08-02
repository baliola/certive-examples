// Certive EDMS — Batch Document Stamp (Node.js)

"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

require("dotenv").config({ path: path.join(__dirname, ".env") });

const API_BASE = "https://api.certive.id/api";
const API_KEY = process.env.CERTIVE_API_KEY?.trim();

if (!API_KEY) {
  console.error("Error: CERTIVE_API_KEY is not set.");
  console.error(`  Expected: ${path.join(__dirname, ".env")} with CERTIVE_API_KEY=ck_...`);
  process.exit(1);
}

// ─── Step 1: Compute SHA-256 for each file ───────────────────────────────────
// Each file is hashed locally. Only the hex digests are transmitted to Certive —
// the files themselves are never uploaded.

function computeSHA256 (filePath) {
  const buffer = fs.readFileSync(filePath);
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function buildItems (filePaths) {
  return filePaths.map((filePath) => {
    const absolutePath = path.resolve(filePath);
    if (!fs.existsSync(absolutePath)) {
      throw new Error(`File not found: ${absolutePath}`);
    }
    return {
      hashValue: computeSHA256(absolutePath),
      fileName: path.basename(absolutePath),
      fileSize: fs.statSync(absolutePath).size,
      description: `Stamped on ${new Date().toISOString().slice(0, 10)}: ${path.basename(absolutePath)}`,
    };
  });
}

// ─── Step 2: Submit the batch job ────────────────────────────────────────────
// API key callers do not need an OTP — the org is resolved from the key.
// anchoringMode is omitted to let the API auto-select (Merkle for ≥10 docs,
// Direct otherwise).

async function submitBatch ({ batchName, items }) {
  const response = await fetch(`${API_BASE}/stamp/batch`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": API_KEY,
    },
    body: JSON.stringify({ batchName, items }),
  });

  const json = await response.json();

  if (!response.ok) {
    throw new Error(`Batch submit failed [${json.error?.code}]: ${json.message}`);
  }

  return json.data; // { jobId }
}

// ─── Step 3: Poll job status ─────────────────────────────────────────────────
// Batch jobs move through: queued → processing → completed | failed | partial_failure.
// Poll until one of the terminal statuses is reached.

const TERMINAL_STATUSES = new Set(["completed", "failed", "partial_failure"]);

async function pollBatchStatus (jobId, { intervalMs = 5000, timeoutMs = 300_000 } = {}) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const response = await fetch(`${API_BASE}/documents/batch/${jobId}`, {
      headers: { "X-API-Key": API_KEY },
    });

    const json = await response.json();

    if (!response.ok) {
      throw new Error(`Status check failed [${json.error?.code}]: ${json.message}`);
    }

    const { job } = json.data;
    console.log(`  Status: ${job.status} | ${job.stampedCount}/${job.totalCount} stamped, ${job.failedCount} failed`);

    if (TERMINAL_STATUSES.has(job.status)) return job;

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  throw new Error(`Timed out after ${timeoutMs / 1000}s waiting for batch completion.`);
}

// ─── Step 4: Fetch per-item results ──────────────────────────────────────────

async function fetchItems (jobId) {
  const response = await fetch(`${API_BASE}/documents/batch/${jobId}/items?limit=100`, {
    headers: { "X-API-Key": API_KEY },
  });

  const json = await response.json();

  if (!response.ok) {
    throw new Error(`Failed to fetch items [${json.error?.code}]: ${json.message}`);
  }

  return json.data.items;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main () {
  const filePaths = process.argv.slice(2);

  if (filePaths.length < 2) {
    console.error("Usage: node batch_stamp.js <file1> <file2> [file3 ...]");
    console.error("Minimum 2 files required for a batch job.");
    process.exit(1);
  }

  console.log(`Files  : ${filePaths.length} file(s)`);

  console.log("\n[1/4] Computing SHA-256 hashes...");
  const items = buildItems(filePaths);
  items.forEach((item) => console.log(`  ${item.hashValue.slice(0, 16)}...  ${item.fileName}`));

  const batchName = `API Batch ${new Date().toISOString().slice(0, 10)}`;

  console.log(`\n[2/4] Submitting batch job "${batchName}"...`);
  const { jobId } = await submitBatch({ batchName, items });
  console.log(`Job ID : ${jobId}`);

  console.log("\n[3/4] Waiting for job to complete...");
  const job = await pollBatchStatus(jobId);

  console.log("\n[4/4] Fetching per-item results...");
  const stampedItems = await fetchItems(jobId);

  console.log("\nResults:");
  for (const item of stampedItems) {
    const doc = item.document;
    const status = item.status.padEnd(10);
    const hash = item.hashValue.slice(0, 16) + "...";
    const tx = doc?.txHash ? doc.txHash.slice(0, 16) + "..." : "—";
    console.log(`  [${status}]  ${hash}  ${item.fileName ?? "—"}  tx: ${tx}`);
  }

  console.log(`\nBatch complete. Status: ${job.status}`);
  if (job.status === "partial_failure") {
    console.log(`  ${job.failedCount} item(s) failed. To retry, call POST /stamp/batch/${jobId}/retry.`);
  }
  if (job.anchorTxHash) {
    console.log(`  Anchor tx: ${job.anchorTxHash}`);
  }
}

main().catch((err) => {
  console.error(`\nError: ${err.message}`);
  process.exit(1);
});
