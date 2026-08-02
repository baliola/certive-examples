# Certive EDMS — PHP Examples

Requires **PHP >= 8.0** and **Composer**.

## Setup

```bash
composer install
cp .env.example .env
# Edit .env and set your CERTIVE_API_KEY
```

## Examples

### Single stamp

Stamps one document and polls until confirmed on-chain.

```bash
php single_stamp.php ./your-document.pdf
```

### Batch stamp

Stamps multiple documents in one job and polls until the job completes.

```bash
php batch_stamp.php ./doc1.pdf ./doc2.pdf ./doc3.pdf
```

## API Reference

Full endpoint documentation: <https://api.certive.id/docs>
