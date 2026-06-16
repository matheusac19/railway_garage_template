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

# 2b. Admin API token management
#     The WebUI (and any admin API client) MUST send this token as a
#     "Authorization: Bearer" header. Without an admin_token configured,
#     Garage v2 returns 403 Forbidden on EVERY admin endpoint
#     (GetClusterHealth, ListBuckets, ...). The /health endpoint stays public.
#     Priority: user-supplied env var > token saved on volume > generate a new one.
if [ -n "$GARAGE_ADMIN_TOKEN" ]; then
    ADMIN_TOKEN=$(echo "$GARAGE_ADMIN_TOKEN" | tr -d ' ' | tr -d '\n')
    echo "[INFO] Using admin token supplied via GARAGE_ADMIN_TOKEN."
elif [ -f "/data/admin_token" ]; then
    ADMIN_TOKEN=$(cat /data/admin_token)
    echo "[INFO] Admin token loaded from persistent volume."
else
    ADMIN_TOKEN=$(openssl rand -hex 32)
    echo "[INFO] GARAGE_ADMIN_TOKEN not set — generated a secure random admin token."
fi
echo -n "$ADMIN_TOKEN" > /data/admin_token

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

[admin]
api_bind_addr = "[::]:3902"
admin_token = "${ADMIN_TOKEN}"
EOF

# 4. Start Garage server in the background
echo "[INFO] Starting Garage server on port ${PORT}..."
garage -c /etc/garage.toml server > /tmp/garage.log 2>&1 &
GARAGE_PID=$!

# Wait until the Garage admin API responds (up to 30 seconds).
# We use the admin API health endpoint because `garage node id` reads from
# local SQLite and returns before the RPC port is actually bound — which
# causes subsequent CLI commands to fail with "Connection refused".
echo "[INFO] Waiting for Garage to be ready..."
MAX_WAIT=30
WAITED=0
until curl -s --max-time 3 http://127.0.0.1:3902/health -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^(200|503)'; do
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
#    The flag is only written at the END, so a partial failure forces a clean retry.
if [ ! -f "/data/.initialized" ]; then
    echo "----------------------------------------------------------"
    echo "[INIT] First-boot cluster setup..."

    # Suppress Garage's verbose CLI output — only our [INIT] messages are shown
    NODE_ID=$(garage -c /etc/garage.toml node id 2>/dev/null | head -n 1 | awk -F'@' '{print $1}')
    if [ -z "$NODE_ID" ]; then
        echo "[ERROR] Could not retrieve node ID. Server logs:"
        cat /tmp/garage.log
        exit 1
    fi
    echo "[INIT] Node ID: ${NODE_ID}"

    # Assign layout — both stdout and stderr suppressed; only our messages show
    garage -c /etc/garage.toml layout assign -z dc1 -c 1G "$NODE_ID" >/dev/null 2>&1 \
        && echo "[INIT] Layout assigned (zone: dc1, capacity: 1G, partitions: 256)." \
        || echo "[INIT] Layout already assigned — skipping."
    garage -c /etc/garage.toml layout apply --version 1 >/dev/null 2>&1 \
        && echo "[INIT] Layout applied." \
        || echo "[INIT] Layout version 1 already applied — skipping."

    # Create the default bucket
    echo "[INIT] Creating bucket: ${GARAGE_BUCKET}"
    garage -c /etc/garage.toml bucket create "$GARAGE_BUCKET" >/dev/null 2>&1 \
        || echo "[INIT] Bucket already exists — skipping."

    # Configure access credentials
    if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
        # --- Custom key path ---
        # Validate: Garage key IDs must be exactly 'GK' + 26 alphanumeric characters (28 total).
        # Keys shorter or longer than this will be rejected by Garage on import.
        KEY_LEN=${#GARAGE_ACCESS_KEY}
        KEY_SUFFIX=$(echo "$GARAGE_ACCESS_KEY" | sed 's/^GK//')
        SUFFIX_LEN=${#KEY_SUFFIX}
        # Garage v2 requires: GK + exactly 12 hex-encoded bytes = GK + 24 hex chars = 26 total
        # Only 0-9 and a-f are valid — letters like g, n, r, etc. are NOT hex
        if [ "$KEY_LEN" -ne 26 ] || ! echo "$KEY_SUFFIX" | grep -qE '^[0-9a-fA-F]{24}$'; then
            echo "[ERROR] --------------------------------------------------------"
            echo "[ERROR] GARAGE_ACCESS_KEY is invalid: '${GARAGE_ACCESS_KEY}'"
            echo "[ERROR]"
            echo "[ERROR] Garage requires: GK + 24 hex characters (0-9, a-f) = 26 total"
            echo "[ERROR]   Your key  : GK + ${SUFFIX_LEN} chars = ${KEY_LEN} total"
            echo "[ERROR]   Required  : GK + 24 hex chars = 26 total"
            echo "[ERROR]   Hex chars : only 0-9 and a-f  (not g, h, i, n, r...)"
            echo "[ERROR]"
            echo "[ERROR] Fix — run in any terminal (Linux, Mac, Git Bash, WSL):"
            echo "[ERROR]   Access Key: echo \"GK\$(openssl rand -hex 12)\""
            echo "[ERROR]   Secret Key: openssl rand -hex 32"
            echo "[ERROR]"
            echo "[ERROR] Update GARAGE_ACCESS_KEY and GARAGE_SECRET_KEY in"
            echo "[ERROR] Railway → Variables, then redeploy."
            echo "[ERROR] --------------------------------------------------------"
            echo "[ERROR] Waiting 60s before restarting to avoid log flooding..."
            sleep 60
            exit 1
        fi

        echo "[INIT] Importing custom access key: ${GARAGE_ACCESS_KEY}"
        IMPORT_OUT=$(garage -c /etc/garage.toml key import --yes "$GARAGE_ACCESS_KEY" "$GARAGE_SECRET_KEY" 2>&1) \
            && echo "[INIT] Custom access key imported successfully." \
            || {
                echo "[ERROR] Key import failed. Garage response:"
                echo "        ${IMPORT_OUT}"
                echo "[ERROR] Check that GARAGE_ACCESS_KEY and GARAGE_SECRET_KEY are valid."
                echo "[ERROR] Waiting 60s before restarting to avoid log flooding..."
                sleep 60
                exit 1
            }
        garage -c /etc/garage.toml bucket allow "$GARAGE_BUCKET" --read --write --key "$GARAGE_ACCESS_KEY" >/dev/null 2>&1 \
            || echo "[INIT] Bucket permission already set."

    else
        # --- Auto-generated key path ---
        echo "[INIT] Creating auto-generated access key: ${GARAGE_KEY_NAME}"
        # Capture key create output to extract and persist credentials (secret is only shown once)
        KEY_OUT=$(garage -c /etc/garage.toml key create "$GARAGE_KEY_NAME" 2>&1) || true
        if echo "$KEY_OUT" | grep -q "Key ID"; then
            GEN_KEY_ID=$(echo "$KEY_OUT" | awk '/Key ID/{print $NF}')
            GEN_SECRET=$(echo "$KEY_OUT" | awk '/Secret key/{print $NF}')
            # Save to volume — survives restarts and is used in the connection summary
            printf '%s\n' "$GEN_KEY_ID" > /data/auto_key_id
            printf '%s\n' "$GEN_SECRET" > /data/auto_key_secret
            echo "[INIT] Access key created: ${GEN_KEY_ID}"
        else
            echo "[INIT] Key '${GARAGE_KEY_NAME}' already exists."
        fi
        garage -c /etc/garage.toml bucket allow "$GARAGE_BUCKET" --read --write --key "$GARAGE_KEY_NAME" >/dev/null 2>&1 \
            || echo "[INIT] Bucket permission already set."
    fi

    # Only mark as initialized after ALL steps succeed
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

echo "  Endpoint   : ${ENDPOINT}"
echo "  Region     : garage"
echo "  Bucket     : ${GARAGE_BUCKET}"
echo "  Admin API  : http://${RAILWAY_PRIVATE_DOMAIN:-<service>.railway.internal}:3902"
echo "  Admin Token: ${ADMIN_TOKEN}"
echo "               ^ set this as API_ADMIN_KEY in the WebUI service"

if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
    # Custom key — show the key ID, reference the env var for the secret
    DISPLAY_ACCESS_KEY="$GARAGE_ACCESS_KEY"
    CLI_SECRET_KEY='$GARAGE_SECRET_KEY'   # literal shell var reference, not the value
    echo "  Access Key: ${DISPLAY_ACCESS_KEY}"
    echo "  Secret Key: (see GARAGE_SECRET_KEY environment variable)"
elif [ -f "/data/auto_key_id" ]; then
    # Auto-generated key — read credentials saved during init
    DISPLAY_ACCESS_KEY=$(cat /data/auto_key_id)
    CLI_SECRET_KEY=$(cat /data/auto_key_secret 2>/dev/null || echo "<not found>")
    echo "  Access Key: ${DISPLAY_ACCESS_KEY}"
    echo "  Secret Key: ${CLI_SECRET_KEY}"
else
    # Fallback: query Garage (secret may not be available after first boot)
    KEY_INFO=$(garage -c /etc/garage.toml key info "$GARAGE_KEY_NAME" 2>/dev/null || true)
    DISPLAY_ACCESS_KEY=$(echo "$KEY_INFO" | awk '/Key ID/{print $NF}')
    CLI_SECRET_KEY=$(echo "$KEY_INFO" | awk '/Secret key/{print $NF}')
    if [ -n "$DISPLAY_ACCESS_KEY" ]; then
        echo "  Access Key: ${DISPLAY_ACCESS_KEY}"
        echo "  Secret Key: ${CLI_SECRET_KEY:-run 'garage key info ${GARAGE_KEY_NAME}' in Railway console}"
    else
        echo "  Credentials: run 'garage key info ${GARAGE_KEY_NAME}' in the Railway console"
    fi
fi

echo ""
echo "  AWS CLI quick-start:"
echo "    export AWS_ACCESS_KEY_ID=${DISPLAY_ACCESS_KEY:-<access-key>}"
echo "    export AWS_SECRET_ACCESS_KEY=${CLI_SECRET_KEY:-<secret-key>}"
echo "    aws s3 cp ./file.txt s3://${GARAGE_BUCKET}/file.txt \\"
echo "      --endpoint-url ${ENDPOINT} \\"
echo "      --region garage"
echo ""
echo "  !! REQUIRED — path-style addressing (Railway has no wildcard subdomains):"
echo "     boto3   : Config(s3={'addressing_style': 'path'})"
echo "     AWS SDK : forcePathStyle: true"
echo "     s3cmd   : --host-bucket=''"
echo ""
echo "  !! S3 key must be a relative path, not a full OS path:"
echo "     Wrong  : s3://${GARAGE_BUCKET}/C:/Users/you/file.txt"
echo "     Correct: s3://${GARAGE_BUCKET}/file.txt"
echo ""
echo "  Env vars (Railway → Variables):"
echo "    GARAGE_BUCKET       bucket name                   (default: my-bucket)"
echo "    GARAGE_KEY_NAME     label for auto-generated key  (default: admin-key)"
echo "    GARAGE_ACCESS_KEY   custom key ID  → GK + 24 hex chars (0-9a-f) = 26 total"
echo "    GARAGE_SECRET_KEY   custom secret  → 64-char hexadecimal string"
echo ""
echo "  If something is broken: open Console tab and run 'rm /data/.initialized'"
echo "  then fix your Variables and redeploy. See README for full troubleshooting."
echo "=========================================================="

# Keep the container alive by waiting on the Garage process
wait $GARAGE_PID
