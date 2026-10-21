# Certive EDMS — Node.js Examples

Requires **Node.js >= 18** and **npm**.

## Setup

```bash
npm install
cp .env.example .env
# Edit .env and set your CERTIVE_API_KEY
```

## Examples

### Single stamp

Stamps one document and polls until confirmed on-chain.

```bash
node single_stamp.js ./your-document.pdf
```

### Batch stamp

Stamps multiple documents in one job and polls until the job completes.

```bash
node batch_stamp.js ./doc1.pdf ./doc2.pdf ./doc3.pdf
```

## API Reference

Full endpoint documentation: <https://api.certive.io/docs>
