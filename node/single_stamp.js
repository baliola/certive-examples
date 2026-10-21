// Certive EDMS — Single Document Stamp (Node.js)

"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

require("dotenv").config({ path: path.join(__dirname, ".env") });

const API_BASE = "https://api.certive.io/api";
const API_KEY = process.env.CERTIVE_API_KEY?.trim();

if (!API_KEY) {
  console.error("Error: CERTIVE_API_KEY is not set.");
  console.error(`  Expected: ${path.join(__dirname, ".env")} with CERTIVE_API_KEY=ck_...`);
  process.exit(1);
}

// ─── Step 1: Compute SHA-256 ──────────────────────────────────────────────────
// The file is hashed locally. Only the hex digest is transmitted to Certive —
// the file itself is never uploaded.

function computeSHA256 (filePath) {
  const buffer = fs.readFileSync(filePath);
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

// ─── Step 2: Submit the stamp ────────────────────────────────────────────────

async function stampDocument ({ hashValue, fileName, fileSize, description }) {
  const response = await fetch(`${API_BASE}/stamp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": API_KEY,
    },
    body: JSON.stringify({ hashValue, fileName, fileSize, description }),
  });

  const json = await response.json();

  if (!response.ok) {
    throw new Error(`Stamp failed [${json.error?.code}]: ${json.message}`);
  }

  return json.data; // { documentId, publicVerifyUrl }
}

// ─── Step 3: Poll for status ─────────────────────────────────────────────────
// POST /stamp is async — the document starts as "Pending" while the blockchain
// transaction is processed. Poll until status is "Stamped" or "Failed".

async function pollStatus (documentId, { intervalMs = 3000, timeoutMs = 120_000 } = {}) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const response = await fetch(`${API_BASE}/documents/${documentId}`, {
      headers: { "X-API-Key": API_KEY },
    });

    const json = await response.json();

    if (!response.ok) {
      throw new Error(`Status check failed [${json.error?.code}]: ${json.message}`);
    }

    const { status, txHash } = json.data;
    console.log(`  Status: ${status}${txHash ? ` | tx: ${txHash}` : ""}`);

    if (status === "Stamped") return json.data;
    if (status === "Failed") throw new Error(`Stamping failed on-chain. To retry, call POST /stamp/${documentId}/retry.`);

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  throw new Error(`Timed out after ${timeoutMs / 1000}s waiting for stamp confirmation.`);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main () {
  const filePath = process.argv[2];
  if (!filePath) {
    console.error("Usage: node single_stamp.js <file>");
    process.exit(1);
  }

  const absolutePath = path.resolve(filePath);
  if (!fs.existsSync(absolutePath)) {
    console.error(`Error: File not found: ${absolutePath}`);
    process.exit(1);
  }

  const fileName = path.basename(absolutePath);
  const fileSize = fs.statSync(absolutePath).size;

  console.log(`File   : ${fileName}`);
  console.log(`Size   : ${fileSize} bytes`);

  console.log("\n[1/3] Computing SHA-256 hash...");
  const hashValue = computeSHA256(absolutePath);
  console.log(`Hash   : ${hashValue}`);

  console.log("\n[2/3] Submitting stamp request...");
  const { documentId, publicVerifyUrl } = await stampDocument({
    hashValue,
    fileName,
    fileSize,
    description: `Stamped on ${new Date().toISOString().slice(0, 10)}: ${fileName}`,
  });
  console.log(`Document ID : ${documentId}`);

  console.log("\n[3/3] Waiting for on-chain confirmation...");
  const result = await pollStatus(documentId);

  console.log("\nStamp confirmed.");
  console.log(`Transaction : ${result.txHash}`);
  console.log(`Verify URL  : ${publicVerifyUrl}`);
}

main().catch((err) => {
  console.error(`\nError: ${err.message}`);
  process.exit(1);
});
