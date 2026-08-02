# Certive EDMS — Python Examples

Requires **Python >= 3.8** and **pip**.

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env
# Edit .env and set your CERTIVE_API_KEY
```

## Examples

### Single stamp

Stamps one document and polls until confirmed on-chain.

```bash
python single_stamp.py ./your-document.pdf
```

### Batch stamp

Stamps multiple documents in one job and polls until the job completes.

```bash
python batch_stamp.py ./doc1.pdf ./doc2.pdf ./doc3.pdf
```

## API Reference

Full endpoint documentation: <https://api.certive.id/docs>
