<?php
// Certive EDMS — Single Document Stamp (PHP)

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

// ─── Step 1: Compute SHA-256 ──────────────────────────────────────────────────
// The file is hashed locally. Only the hex digest is transmitted to Certive —
// the file itself is never uploaded.

function computeSHA256(string $filePath): string
{
    return hash_file('sha256', $filePath);
}

// ─── Step 2: Submit the stamp ────────────────────────────────────────────────

function stampDocument(Client $client, string $hashValue, string $fileName, int $fileSize, string $description): array
{
    try {
        $response = $client->post('/api/stamp', [
            'json' => [
                'hashValue'   => $hashValue,
                'fileName'    => $fileName,
                'fileSize'    => $fileSize,
                'description' => $description,
            ],
        ]);
    } catch (ClientException $e) {
        $body = json_decode((string) $e->getResponse()->getBody(), true);
        $code = $body['error']['code'] ?? 'UNKNOWN';
        throw new RuntimeException("Stamp failed [{$code}]: {$body['message']}");
    }

    $body = json_decode((string) $response->getBody(), true);
    return $body['data']; // ['documentId' => ..., 'publicVerifyUrl' => ...]
}

// ─── Step 3: Poll for status ─────────────────────────────────────────────────
// POST /stamp is async — the document starts as "Pending" while the blockchain
// transaction is processed. Poll until status is "Stamped" or "Failed".

function pollStatus(Client $client, string $documentId, int $intervalMs = 3000, int $timeoutMs = 120000): array
{
    $deadline = microtime(true) * 1000 + $timeoutMs;

    while (microtime(true) * 1000 < $deadline) {
        try {
            $response = $client->get("/api/documents/{$documentId}");
        } catch (ClientException $e) {
            $body = json_decode((string) $e->getResponse()->getBody(), true);
            $code = $body['error']['code'] ?? 'UNKNOWN';
            throw new RuntimeException("Status check failed [{$code}]: {$body['message']}");
        }

        $body   = json_decode((string) $response->getBody(), true);
        $data   = $body['data'];
        $status = $data['status'];
        $tx     = $data['txHash'] ?? '';

        echo "  Status: {$status}" . ($tx ? " | tx: {$tx}" : '') . "\n";

        if ($status === 'Stamped') return $data;
        if ($status === 'Failed')  throw new RuntimeException("Stamping failed on-chain. To retry, call POST /stamp/{$documentId}/retry.");

        usleep($intervalMs * 1000);
    }

    throw new RuntimeException("Timed out after " . ($timeoutMs / 1000) . "s waiting for stamp confirmation.");
}

// ─── Main ─────────────────────────────────────────────────────────────────────

try {
    if ($argc < 2) {
        fwrite(STDERR, "Usage: php single_stamp.php <file>\n");
        exit(1);
    }

    $filePath = realpath($argv[1]);
    if (!$filePath || !file_exists($filePath)) {
        fwrite(STDERR, "Error: File not found: {$argv[1]}\n");
        exit(1);
    }

    $fileName = basename($filePath);
    $fileSize = filesize($filePath);

    echo "File   : {$fileName}\n";
    echo "Size   : {$fileSize} bytes\n";

    echo "\n[1/3] Computing SHA-256 hash...\n";
    $hashValue = computeSHA256($filePath);
    echo "Hash   : {$hashValue}\n";

    echo "\n[2/3] Submitting stamp request...\n";
    $data           = stampDocument($client, $hashValue, $fileName, $fileSize, 'Stamped on ' . date('Y-m-d') . ": {$fileName}");
    $documentId     = $data['documentId'];
    $publicVerifyUrl = $data['publicVerifyUrl'];
    echo "Document ID : {$documentId}\n";

    echo "\n[3/3] Waiting for on-chain confirmation...\n";
    $result = pollStatus($client, $documentId);

    echo "\nStamp confirmed.\n";
    echo "Transaction : {$result['txHash']}\n";
    echo "Verify URL  : {$publicVerifyUrl}\n";

} catch (Throwable $e) {
    fwrite(STDERR, "\nError: {$e->getMessage()}\n");
    exit(1);
}
