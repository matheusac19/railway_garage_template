#!/bin/sh
set -e

# 1. Cria as pastas no Volume em tempo de execução
mkdir -p /data/meta /data/data

PORT=${PORT:-3900}
GARAGE_BUCKET=${GARAGE_BUCKET:-"meu-bucket"}
GARAGE_KEY_NAME=${GARAGE_KEY_NAME:-"admin-key"}

# 2. VALIDAÇÃO ABSOLUTA DO RPC SECRET (Salvo direto no disco)
if [ ! -f "/data/rpc_secret" ]; then
    echo "🔒 Gerando nova senha RPC interna e salvando no volume persistente..."
    openssl rand -hex 32 > /data/rpc_secret
fi
GARAGE_RPC_SECRET=$(cat /data/rpc_secret)

# 3. Gera o arquivo de configuração do Garage
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

# 5. AUTO-INICIALIZAÇÃO DO CLUSTER
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
    
    # Cria/Importa a chave baseada nas variáveis da Railway
    if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
        echo "🔑 Importando as chaves personalizadas da Railway..."
        garage -c /etc/garage.toml key import --name $GARAGE_KEY_NAME $GARAGE_ACCESS_KEY $GARAGE_SECRET_KEY
    else
        echo "⚠️ AVISO: Nenhuma chave personalizada definida nas variáveis."
        echo "🔑 GERANDO CHAVES DE ACESSO ALEATÓRIAS (Copie isso!):"
        garage -c /etc/garage.toml key create $GARAGE_KEY_NAME
    fi
    
    # Autoriza o uso do bucket
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