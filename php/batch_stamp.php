<?php
// Certive EDMS — Batch Document Stamp (PHP)

require __DIR__ . '/vendor/autoload.php';

use GuzzleHttp\Client;
use GuzzleHttp\Exception\ClientException;
use Dotenv\Dotenv;

$dotenv = Dotenv::createImmutable(__DIR__);
$dotenv->load();

define('API_BASE', 'https://api.certive.io/api');
define('API_KEY',  $_ENV['CERTIVE_API_KEY'] ?? '');

if (!API_KEY) {
    fwrite(STDERR, "Error: CERTIVE_API_KEY is not set. Copy .env.example to .env and fill in your key.\n");
    exit(1);
}

$client = new Client([
    'base_uri' => API_BASE,
    'headers'  => [
        'Content-Type' => 'application/json',
        'X-API-Key'    => API_KEY,
    ],
]);

// ─── Step 1: Compute SHA-256 for each file ───────────────────────────────────
// Each file is hashed locally. Only the hex digests are transmitted to Certive —
// the files themselves are never uploaded.

function computeSHA256(string $filePath): string
{
    return hash_file('sha256', $filePath);
}

function buildItems(array $filePaths): array
{
    $items = [];
    foreach ($filePaths as $filePath) {
        $resolved = realpath($filePath);
        if (!$resolved || !file_exists($resolved)) {
            throw new RuntimeException("File not found: {$filePath}");
        }
        $items[] = [
            'hashValue'   => computeSHA256($resolved),
            'fileName'    => basename($resolved),
            'fileSize'    => filesize($resolved),
            'description' => 'Stamped on ' . date('Y-m-d') . ': ' . basename($resolved),
        ];
    }
    return $items;
}

// ─── Step 2: Submit the batch job ────────────────────────────────────────────
// API key callers do not need an OTP — the org is resolved from the key.
// anchoringMode is omitted to let the API auto-select (Merkle for ≥10 docs,
// Direct otherwise).

function submitBatch(Client $client, string $batchName, array $items): array
{
    try {
        $response = $client->post('/api/stamp/batch', [
            'json' => ['batchName' => $batchName, 'items' => $items],
        ]);
    } catch (ClientException $e) {
        $body = json_decode((string) $e->getResponse()->getBody(), true);
        $code = $body['error']['code'] ?? 'UNKNOWN';
        throw new RuntimeException("Batch submit failed [{$code}]: {$body['message']}");
    }

    $body = json_decode((string) $response->getBody(), true);
    return $body['data']; // ['jobId' => ...]
}

// ─── Step 3: Poll job status ─────────────────────────────────────────────────
// Batch jobs move through: queued → processing → completed | failed | partial_failure.
// Poll until one of the terminal statuses is reached.

function pollBatchStatus(Client $client, string $jobId, int $intervalMs = 5000, int $timeoutMs = 300000): array
{
    $deadline = microtime(true) * 1000 + $timeoutMs;

    while (microtime(true) * 1000 < $deadline) {
        try {
            $response = $client->get("/api/documents/batch/{$jobId}");
        } catch (ClientException $e) {
            $body = json_decode((string) $e->getResponse()->getBody(), true);
            $code = $body['error']['code'] ?? 'UNKNOWN';
            throw new RuntimeException("Status check failed [{$code}]: {$body['message']}");
        }

        $body = json_decode((string) $response->getBody(), true);
        $job  = $body['data']['job'];

        echo "  Status: {$job['status']} | {$job['stampedCount']}/{$job['totalCount']} stamped, {$job['failedCount']} failed\n";

        if (in_array($job['status'], ['completed', 'failed', 'partial_failure'], true)) return $job;

        usleep($intervalMs * 1000);
    }

    throw new RuntimeException("Timed out after " . ($timeoutMs / 1000) . "s waiting for batch completion.");
}

// ─── Step 4: Fetch per-item results ──────────────────────────────────────────

function fetchItems(Client $client, string $jobId): array
{
    try {
        $response = $client->get("/api/documents/batch/{$jobId}/items", [
            'query' => ['limit' => 100],
        ]);
    } catch (ClientException $e) {
        $body = json_decode((string) $e->getResponse()->getBody(), true);
        $code = $body['error']['code'] ?? 'UNKNOWN';
        throw new RuntimeException("Failed to fetch items [{$code}]: {$body['message']}");
    }

    $body = json_decode((string) $response->getBody(), true);
    return $body['data']['items'];
}

// ─── Main ─────────────────────────────────────────────────────────────────────

try {
    $filePaths = array_slice($argv, 1);

    if (count($filePaths) < 2) {
        fwrite(STDERR, "Usage: php batch_stamp.php <file1> <file2> [file3 ...]\n");
        fwrite(STDERR, "Minimum 2 files required for a batch job.\n");
        exit(1);
    }

    echo "Files  : " . count($filePaths) . " file(s)\n";

    echo "\n[1/4] Computing SHA-256 hashes...\n";
    $items = buildItems($filePaths);
    foreach ($items as $item) {
        echo '  ' . substr($item['hashValue'], 0, 16) . "...  {$item['fileName']}\n";
    }

    $batchName = 'API Batch ' . date('Y-m-d');

    echo "\n[2/4] Submitting batch job \"{$batchName}\"...\n";
    $result = submitBatch($client, $batchName, $items);
    $jobId  = $result['jobId'];
    echo "Job ID : {$jobId}\n";

    echo "\n[3/4] Waiting for job to complete...\n";
    $job = pollBatchStatus($client, $jobId);

    echo "\n[4/4] Fetching per-item results...\n";
    $stampedItems = fetchItems($client, $jobId);

    echo "\nResults:\n";
    foreach ($stampedItems as $item) {
        $doc    = $item['document'] ?? [];
        $status = str_pad($item['status'], 10);
        $hash   = substr($item['hashValue'], 0, 16) . '...';
        $tx     = isset($doc['txHash']) ? substr($doc['txHash'], 0, 16) . '...' : '—';
        $name   = $item['fileName'] ?? '—';
        echo "  [{$status}]  {$hash}  {$name}  tx: {$tx}\n";
    }

    echo "\nBatch complete. Status: {$job['status']}\n";
    if ($job['status'] === 'partial_failure') {
        echo "  {$job['failedCount']} item(s) failed. To retry, call POST /stamp/batch/{$jobId}/retry.\n";
    }
    if (!empty($job['anchorTxHash'])) {
        echo "  Anchor tx: {$job['anchorTxHash']}\n";
    }

} catch (Throwable $e) {
    fwrite(STDERR, "\nError: {$e->getMessage()}\n");
    exit(1);
}
