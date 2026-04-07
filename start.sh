#!/bin/sh
set -e

# 1. Cria as pastas no Volume em tempo de execução
mkdir -p /data/meta /data/data

PORT=${PORT:-3900}
GARAGE_BUCKET=${GARAGE_BUCKET:-"meu-bucket"}
GARAGE_KEY_NAME=${GARAGE_KEY_NAME:-"admin-key"}

# 2. GESTÃO INTELIGENTE DO RPC SECRET
if [ -f "/data/rpc_secret" ]; then
    GARAGE_RPC_SECRET=$(cat /data/rpc_secret)
    echo "🔒 RPC Secret carregado do volume persistente."
else
    USER_SECRET=$(echo "$GARAGE_RPC_SECRET" | tr -d ' ' | tr -d '\n')
    
    if echo "$USER_SECRET" | grep -qE '^[0-9a-fA-F]{64}$'; then
        echo "🔒 Usando a senha RPC fornecida pela variável..."
        GARAGE_RPC_SECRET=$USER_SECRET
    else
        echo "⚠️ Gerando RPC Secret aleatório e seguro..."
        GARAGE_RPC_SECRET=$(openssl rand -hex 32)
    fi
    echo -n "$GARAGE_RPC_SECRET" > /data/rpc_secret
fi

# 3. Gera o arquivo de configuração
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

# 4. Inicia o Garage em background
echo "Iniciando o Garage localmente na porta $PORT..."
garage -c /etc/garage.toml server > /tmp/garage.log 2>&1 &
GARAGE_PID=$!

sleep 5

# 5. AUTO-INICIALIZAÇÃO BLINDADA (Ignora erros de coisas já feitas)
if [ ! -f "/data/.initialized" ]; then
    echo "=========================================================="
    echo "🚀 Inicializando Cluster Garage..."
    
    NODE_ID=$(garage -c /etc/garage.toml node id | head -n 1 | awk -F'@' '{print $1}')
    
    if [ -z "$NODE_ID" ]; then
         echo "❌ ERRO FATAL: Veja os logs do Garage:"
         cat /tmp/garage.log
         exit 1
    fi

    # Tenta aplicar o layout (se falhar porque já existe num reboot, ele avisa e ignora)
    garage -c /etc/garage.toml layout assign -z dc1 -c 1G $NODE_ID || echo "⚠️ Layout já estava assinalado."
    garage -c /etc/garage.toml layout apply --version 1 || echo "⚠️ Layout versão 1 já estava aplicado."
    
    # Tenta criar o bucket
    garage -c /etc/garage.toml bucket create $GARAGE_BUCKET || echo "⚠️ Bucket já existe."
    
    # Importa chaves e dá permissão
    if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
        echo "🔑 Configurando chaves personalizadas..."
        garage -c /etc/garage.toml key import $GARAGE_ACCESS_KEY $GARAGE_SECRET_KEY || echo "⚠️ Chave já importada."
        garage -c /etc/garage.toml bucket allow $GARAGE_BUCKET --read --write --key $GARAGE_ACCESS_KEY || echo "⚠️ Permissão já concedida."
    else
        echo "🔑 Configurando chaves aleatórias..."
        garage -c /etc/garage.toml key create $GARAGE_KEY_NAME || echo "⚠️ Chave já existe."
        garage -c /etc/garage.toml bucket allow $GARAGE_BUCKET --read --write --key $GARAGE_KEY_NAME || echo "⚠️ Permissão já concedida."
    fi
    
    touch /data/.initialized
    echo "✅ Inicialização concluída com sucesso!"
    echo "=========================================================="
else
    echo "✅ Garage já estava inicializado. Carregando dados..."
fi

# Mantém o container vivo
wait $GARAGE_PID