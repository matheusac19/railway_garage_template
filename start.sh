#!/bin/sh
set -e

GARAGE_VERSION="v2.2.0"

echo "=========================================================="
echo "  Garage S3 ${GARAGE_VERSION} — S3-compatible object storage"
echo "=========================================================="

# 1. Create volume directories at runtime
mkdir -p /data/meta /data/data

PORT=${PORT:-3900}
GARAGE_BUCKET=${GARAGE_BUCKET:-"my-bucket"}
GARAGE_KEY_NAME=${GARAGE_KEY_NAME:-"admin-key"}

# 2. Intelligent RPC secret management:
#    - On restart: reuse the secret saved to the persistent volume
#    - First boot: validate the user-supplied secret or generate a random one
if [ -f "/data/rpc_secret" ]; then
    GARAGE_RPC_SECRET=$(cat /data/rpc_secret)
    echo "[INFO] RPC secret loaded from persistent volume."
else
    USER_SECRET=$(echo "$GARAGE_RPC_SECRET" | tr -d ' ' | tr -d '\n')

    if echo "$USER_SECRET" | grep -qE '^[0-9a-fA-F]{64}$'; then
        echo "[INFO] Using RPC secret supplied via GARAGE_RPC_SECRET."
        GARAGE_RPC_SECRET=$USER_SECRET
    else
        echo "[INFO] GARAGE_RPC_SECRET not set or invalid — generating a secure random secret."
        GARAGE_RPC_SECRET=$(openssl rand -hex 32)
    fi
    echo -n "$GARAGE_RPC_SECRET" > /data/rpc_secret
fi

# 3. Write Garage configuration file
cat <<EOF > /etc/garage.toml
metadata_dir = "/data/meta"
data_dir = "/data/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:${PORT}"
EOF

# 4. Start Garage server in the background
echo "[INFO] Starting Garage server on port ${PORT}..."
garage -c /etc/garage.toml server > /tmp/garage.log 2>&1 &
GARAGE_PID=$!

# Wait until Garage responds (up to 30 seconds) instead of a fixed sleep
echo "[INFO] Waiting for Garage to be ready..."
MAX_WAIT=30
WAITED=0
until garage -c /etc/garage.toml node id > /dev/null 2>&1; do
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo "[ERROR] Garage did not become ready after ${MAX_WAIT}s. Server logs:"
        cat /tmp/garage.log
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
echo "[INFO] Garage is ready (${WAITED}s elapsed)."

# 5. One-time cluster initialization (guarded by a flag file on the volume)
if [ ! -f "/data/.initialized" ]; then
    echo "----------------------------------------------------------"
    echo "[INIT] First-boot cluster setup..."

    NODE_ID=$(garage -c /etc/garage.toml node id | head -n 1 | awk -F'@' '{print $1}')
    if [ -z "$NODE_ID" ]; then
        echo "[ERROR] Could not retrieve node ID. Server logs:"
        cat /tmp/garage.log
        exit 1
    fi
    echo "[INIT] Node ID: ${NODE_ID}"

    # Assign layout — safe to run multiple times; skip silently if already done
    garage -c /etc/garage.toml layout assign -z dc1 -c 1G "$NODE_ID" 2>/dev/null \
        || echo "[INIT] Layout already assigned — skipping."
    garage -c /etc/garage.toml layout apply --version 1 2>/dev/null \
        || echo "[INIT] Layout version 1 already applied — skipping."

    # Create the default bucket
    echo "[INIT] Creating bucket: ${GARAGE_BUCKET}"
    garage -c /etc/garage.toml bucket create "$GARAGE_BUCKET" 2>/dev/null \
        || echo "[INIT] Bucket already exists — skipping."

    # Configure access keys
    if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
        # Use the custom key pair provided via environment variables
        echo "[INIT] Importing custom access key: ${GARAGE_ACCESS_KEY}"
        garage -c /etc/garage.toml key import --yes "$GARAGE_ACCESS_KEY" "$GARAGE_SECRET_KEY" 2>/dev/null \
            || echo "[INIT] Key already imported — skipping."
        garage -c /etc/garage.toml bucket allow "$GARAGE_BUCKET" --read --write --key "$GARAGE_ACCESS_KEY" 2>/dev/null \
            || echo "[INIT] Permission already granted — skipping."
    else
        # Generate a new random key with the configured name
        echo "[INIT] Creating access key: ${GARAGE_KEY_NAME}"
        garage -c /etc/garage.toml key create "$GARAGE_KEY_NAME" 2>/dev/null \
            || echo "[INIT] Key already exists — skipping."
        garage -c /etc/garage.toml bucket allow "$GARAGE_BUCKET" --read --write --key "$GARAGE_KEY_NAME" 2>/dev/null \
            || echo "[INIT] Permission already granted — skipping."
    fi

    touch /data/.initialized
    echo "[INIT] Cluster initialization complete."
    echo "----------------------------------------------------------"
else
    echo "[INFO] Volume already initialized — skipping cluster setup."
fi

# 6. Print a connection summary so users know how to connect immediately
echo "=========================================================="
echo "  CONNECTION DETAILS"
echo "=========================================================="

if [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    ENDPOINT="https://${RAILWAY_PUBLIC_DOMAIN}"
else
    ENDPOINT="http://localhost:${PORT}"
fi

echo "  Endpoint : ${ENDPOINT}"
echo "  Region   : garage"
echo "  Bucket   : ${GARAGE_BUCKET}"

if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
    echo "  Access Key: ${GARAGE_ACCESS_KEY}"
    echo "  Secret Key: (value of GARAGE_SECRET_KEY env var)"
else
    KEY_INFO=$(garage -c /etc/garage.toml key info "$GARAGE_KEY_NAME" 2>/dev/null || true)
    ACCESS_KEY=$(echo "$KEY_INFO" | awk '/Key ID/{print $NF}')
    SECRET_KEY=$(echo "$KEY_INFO" | awk '/Secret key/{print $NF}')
    if [ -n "$ACCESS_KEY" ]; then
        echo "  Access Key: ${ACCESS_KEY}"
        echo "  Secret Key: ${SECRET_KEY}"
    fi
fi

echo ""
echo "  AWS CLI quick-start:"
echo "    export AWS_ACCESS_KEY_ID=<access-key>"
echo "    export AWS_SECRET_ACCESS_KEY=<secret-key>"
echo "    aws s3 ls s3://${GARAGE_BUCKET} \\"
echo "      --endpoint-url ${ENDPOINT} \\"
echo "      --region garage"
echo ""
echo "  Available environment variables:"
echo "    GARAGE_BUCKET       bucket name              (default: my-bucket)"
echo "    GARAGE_KEY_NAME     auto-generated key name  (default: admin-key)"
echo "    GARAGE_RPC_SECRET   64-char hex RPC secret   (auto-generated)"
echo "    GARAGE_ACCESS_KEY   custom S3 access key     (must start with GK)"
echo "    GARAGE_SECRET_KEY   custom S3 secret key     (64-char hex)"
echo "=========================================================="

# Keep the container alive by waiting on the Garage process
wait $GARAGE_PID
