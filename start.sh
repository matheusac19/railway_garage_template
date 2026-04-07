#!/bin/sh
set -e

# 1. Cria as pastas no Volume em tempo de execução
mkdir -p /data/meta /data/data

# Railway fornece a variável $PORT dinamicamente. Se não existir, usa 3900.
PORT=${PORT:-3900}

GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET:-$(openssl rand -hex 32)}
GARAGE_BUCKET=${GARAGE_BUCKET:-"meu-bucket"}
GARAGE_KEY_NAME=${GARAGE_KEY_NAME:-"admin-key"}

# 2. Gera o arquivo de configuração do Garage
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

# 3. Inicia o Garage em background
echo "Iniciando o Garage localmente na porta $PORT..."
garage -c /etc/garage.toml server > /tmp/garage.log 2>&1 &
GARAGE_PID=$!

sleep 5

# 4. AUTO-INICIALIZAÇÃO
if [ ! -f "/data/.initialized" ]; then
    echo "=========================================================="
    echo "🚀 Inicializando Cluster Garage pela primeira vez..."
    
    # Captura o ID do nó cortando o IP (ignora o @127...)
    NODE_ID=$(garage -c /etc/garage.toml node id | head -n 1 | awk -F'@' '{print $1}')
    
    if [ -z "$NODE_ID" ]; then
         echo "❌ ERRO FATAL: O Garage não iniciou corretamente. Veja os logs abaixo:"
         cat /tmp/garage.log
         exit 1
    fi

    # Aplica o layout
    garage -c /etc/garage.toml layout assign -z dc1 -c 1G $NODE_ID
    garage -c /etc/garage.toml layout apply --version 1
    
    # Cria o Bucket
    garage -c /etc/garage.toml bucket create $GARAGE_BUCKET
    
    # Cria a chave e exibe no log
    echo "🔑 GERANDO CHAVES DE ACESSO (Copie isso!):"
    garage -c /etc/garage.toml key create $GARAGE_KEY_NAME
    garage -c /etc/garage.toml bucket allow $GARAGE_BUCKET --read --write --key $GARAGE_KEY_NAME
    
    # Marca como inicializado para não rodar de novo
    touch /data/.initialized
    echo "✅ Inicialização concluída com sucesso!"
    echo "=========================================================="
else
    echo "✅ Garage já estava inicializado. Carregando dados do Volume..."
fi

# Mantém o container vivo
wait $GARAGE_PID