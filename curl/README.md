# Certive EDMS — cURL Examples

Requires **curl >= 7.76**, **jq >= 1.6**, and **sha256sum** (Linux) or **shasum** (macOS).

## Setup

```bash
export CERTIVE_API_KEY=ck_your_api_key_here
```

## Examples

### Single stamp

Stamps one document and polls until confirmed on-chain.

```bash
bash single_stamp.sh ./your-document.pdf
```

### Batch stamp

Stamps multiple documents in one job and polls until the job completes.

```bash
bash batch_stamp.sh ./doc1.pdf ./doc2.pdf ./doc3.pdf
```

## API Reference

Full endpoint documentation: <https://api.certive.io/docs>
