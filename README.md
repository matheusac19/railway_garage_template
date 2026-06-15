# Garage S3 Storage — Railway Template

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/dsYToe?referralCode=BZRwJ9&utm_medium=integration&utm_source=template&utm_campaign=generic)

Self-hosted S3-compatible object storage running on Railway. Powered by [Garage](https://garagehq.deuxfleurs.fr/), a lightweight open-source distributed storage server written in Rust (~30–50 MB RAM).

---

## Quick Start

### Option A — Auto-Generated Credentials (Simplest)

1. Click **Deploy on Railway** above.
2. Set `GARAGE_BUCKET` to your bucket name (e.g. `my-app-storage`).
3. Leave `GARAGE_ACCESS_KEY` and `GARAGE_SECRET_KEY` **empty** — Garage generates them automatically.
4. Click **Deploy** and wait ~30 seconds.
5. Open the **Deploy Logs** tab. Your credentials are printed at the bottom:

```
==========================================================
  CONNECTION DETAILS
==========================================================
  Endpoint : https://your-service.up.railway.app
  Region   : garage
  Bucket   : my-app-storage
  Access Key: GK3a7f9c2e1b4d6a8e5f7c9d2ba3f8
  Secret Key: 8f3a7c1d9e2b4a6f5c8d7e1a9b3c4d...
```

Save these values — the secret key is shown **only once**.

---

### Option B — Custom Credentials

Set the following variables in Railway **before** clicking Deploy:

| Variable | Description | Example |
|---|---|---|
| `GARAGE_BUCKET` | Bucket name | `my-app-storage` |
| `GARAGE_ACCESS_KEY` | S3 access key ID | `GK3a7f9c2e1b4d6a8e5f7c9d2ba3` |
| `GARAGE_SECRET_KEY` | S3 secret key | `8f3a7c1d9e2b4a6f5c8d7e1a9b3c4d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c` |
| `GARAGE_KEY_NAME` | Friendly label for the key | `my-app-key` |

#### ⚠️ Access Key Format — #1 cause of `AccessDenied` errors

`GARAGE_ACCESS_KEY` must follow this **exact** format (enforced by Garage v2):
- Start with `GK`
- Followed by **exactly 24 hexadecimal characters** (`0–9` and `a–f` only — no other letters)
- **Total: 26 characters**

| | Value | Problem |
|---|---|---|
| ❌ | `GKmykey` | Too short + invalid chars |
| ❌ | `GKenergiaDoBem2026` | `n`, `r`, `g`, `i` are not hex |
| ❌ | `GKenergiaDoBemProjeto2026001` | Invalid hex chars + wrong length |
| ✅ | `GK3a7f9c2e1b4d6a8e5f7c9d2b` | Correct — GK + 24 hex = 26 total |

**Generate a valid key pair with one command:**

```bash
# Run in any terminal (Linux, Mac, Git Bash, WSL):

# Access Key (GK + 24 hex chars = 26 total):
echo "GK$(openssl rand -hex 12)"

# Secret Key (64 hex chars):
openssl rand -hex 32
```

`GARAGE_SECRET_KEY` must be a **64-character hexadecimal string** (`0–9` and `a–f` only).

---

## Connecting Your Application

> **Railway does not support wildcard subdomains.** You **must** configure your S3 client to use **path-style addressing**, or uploads and downloads will fail.

### AWS CLI

```bash
export AWS_ACCESS_KEY_ID="GKyour28charkey..."
export AWS_SECRET_ACCESS_KEY="your64hexsecret..."

# List bucket contents:
aws s3 ls s3://my-app-storage \
  --endpoint-url https://your-service.up.railway.app \
  --region garage

# Upload a file (use a relative key, not the full OS path):
aws s3 cp ./report.pdf s3://my-app-storage/report.pdf \
  --endpoint-url https://your-service.up.railway.app \
  --region garage
```

> ⚠️ **Common mistake:** Do NOT use the full local file path as the S3 key.
> ```
> # Wrong — uploads to s3://bucket/C:/Users/you/file.txt
> aws s3 cp .\file.txt s3://my-bucket/C:/Users/you/file.txt
>
> # Correct — uploads to s3://bucket/file.txt
> aws s3 cp .\file.txt s3://my-bucket/file.txt
> ```

### Python (boto3)

```python
import boto3
from botocore.client import Config

s3 = boto3.client(
    's3',
    endpoint_url='https://your-service.up.railway.app',
    aws_access_key_id='GKyour28charkey...',
    aws_secret_access_key='your64hexsecret...',
    region_name='garage',
    config=Config(s3={'addressing_style': 'path'})  # REQUIRED on Railway
)

# Upload
s3.upload_file('report.pdf', 'my-app-storage', 'report.pdf')

# Download
s3.download_file('my-app-storage', 'report.pdf', 'report_downloaded.pdf')
```

### Node.js (AWS SDK v3)

```javascript
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { readFileSync } from "fs";

const s3 = new S3Client({
  endpoint: "https://your-service.up.railway.app",
  region: "garage",
  credentials: {
    accessKeyId: "GKyour28charkey...",
    secretAccessKey: "your64hexsecret...",
  },
  forcePathStyle: true,  // REQUIRED on Railway
});

await s3.send(new PutObjectCommand({
  Bucket: "my-app-storage",
  Key: "report.pdf",
  Body: readFileSync("./report.pdf"),
}));
```

### s3cmd

```bash
s3cmd --access_key="GKyour28charkey..." \
      --secret_key="your64hexsecret..." \
      --host="your-service.up.railway.app" \
      --host-bucket="" \
      --region="garage" \
      ls s3://my-app-storage
```

---

## Troubleshooting

### `AccessDenied: No such key: GK...`

The access key does not exist in Garage. Most common causes:

1. **Invalid key format** — Check that `GARAGE_ACCESS_KEY` is `GK` + 24 hex chars (`0-9a-f`) = 26 total. See the format rules above.
2. **Initialization failed mid-way** — The service started but credentials were never fully set up.

**How to reset and retry:**

1. Open the **Console** tab in your Railway service.
2. Run: `rm /data/.initialized`
3. Fix your variables (key format, etc.).
4. Go to **Deployments** and click **Redeploy**.

### `AccessDenied: No such key: my-admin-key`

You used a key **name** (`my-admin-key`) instead of a key **ID** (`GKxxxxx`) as the AWS access key.  
`GARAGE_KEY_NAME` is just a label — it is not the access key ID.  
Use the `GKxxxxx` value shown in the Deploy Logs under **Access Key**.

### `SignatureDoesNotMatch` or `InvalidRegion`

Make sure `--region garage` (or `region_name='garage'`) is set. Garage uses `garage` as the region identifier.

### Uploads or downloads returning wrong results

Confirm your S3 client is using **path-style addressing** (see the connection examples above). Virtual-hosted style (`bucket.domain.com`) does not work on Railway.

---

## Environment Variables Reference

| Variable | Default | Description |
|---|---|---|
| `GARAGE_BUCKET` | `my-bucket` | Name of the primary bucket created on first boot |
| `GARAGE_KEY_NAME` | `admin-key` | Label for the auto-generated key (not the key ID) |
| `GARAGE_RPC_SECRET` | *(auto)* | 64-char hex RPC secret — auto-generated and persisted to volume |
| `GARAGE_ACCESS_KEY` | *(auto)* | Custom access key ID — must be `GK` + 24 hex chars (`0-9a-f`) = 26 total |
| `GARAGE_SECRET_KEY` | *(auto)* | Custom secret key — must be a 64-char hexadecimal string (`0-9a-f`) |
| `PORT` | `3900` | S3 API port — set automatically by Railway, do not change |

---

## How It Works

On first boot, the startup script:
1. Generates a secure RPC secret and saves it to the persistent volume.
2. Starts Garage and waits for it to be ready.
3. Assigns a single-node cluster layout (`dc1`, 1 GB usable).
4. Creates the primary bucket.
5. Imports your custom key pair **or** generates a random one.
6. Writes a `.initialized` flag to the volume so subsequent restarts skip setup.

On every restart after that, Garage loads directly from the persisted data — no re-initialization.
