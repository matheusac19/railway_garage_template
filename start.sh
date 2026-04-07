#!/bin/sh
set -e

# 1. Cria as pastas no Volume em tempo de execução
mkdir -p /data/meta /data/data

PORT=${PORT:-3900}
GARAGE_BUCKET=${GARAGE_BUCKET:-"meu-bucket"}
GARAGE_KEY_NAME=${GARAGE_KEY_NAME:-"admin-key"}

# 2. GESTÃO INTELIGENTE DO RPC SECRET
if [ -f "/data/rpc_secret" ]; then
    # Se já inicializou antes, usa o do disco para garantir consistência
    GARAGE_RPC_SECRET=$(cat /data/rpc_secret)
    echo "🔒 RPC Secret carregado do volume persistente."
else
    # Limpa possíveis espaços em branco que a Railway possa injetar
    USER_SECRET=$(echo "$GARAGE_RPC_SECRET" | tr -d ' ' | tr -d '\n')
    
    # Verifica se o usuário passou uma senha válida no padrão hexa de 64 chars
    if echo "$USER_SECRET" | grep -qE '^[0-9a-fA-F]{64}$'; then
        echo "🔒 Usando a senha RPC fornecida pela variável da Railway..."
        GARAGE_RPC_SECRET=$USER_SECRET
    else
        echo "⚠️ RPC Secret não fornecido ou inválido (precisa ter 64 caracteres hexadecimais). Gerando um aleatório..."
        GARAGE_RPC_SECRET=$(openssl rand -hex 32)
    fi
    
    # Salva no disco para os próximos reboots
    echo -n "$GARAGE_RPC_SECRET" > /data/rpc_secret
fi

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
        # Correção: O comando 'import' não aceita '--name' no Garage v2.2.0
        garage -c /etc/garage.toml key import --name $GARAGE_KEY_NAME $GARAGE_ACCESS_KEY $GARAGE_SECRET_KEY || \
        garage -c /etc/garage.toml key import $GARAGE_ACCESS_KEY $GARAGE_SECRET_KEY
    else
        echo "⚠️ AVISO: Nenhuma chave personalizada definida nas variáveis."
        echo "🔑 GERANDO CHAVES DE ACESSO ALEATÓRIAS (Copie isso!):"
        garage -c /etc/garage.toml key create $GARAGE_KEY_NAME
    fi
    
    # Autoriza o uso do bucket
    echo "🔐 Aplicando permissões ao Bucket..."
    if [ -n "$GARAGE_ACCESS_KEY" ] && [ -n "$GARAGE_SECRET_KEY" ]; then
        garage -c /etc/garage.toml bucket allow $GARAGE_BUCKET --read --write --key $GARAGE_ACCESS_KEY
    else
        garage -c /etc/garage.toml bucket allow $GARAGE_BUCKET --read --write --key $GARAGE_KEY_NAME
    fi
    
    # Marca como inicializado para não rodar de novo
    touch /data/.initialized
    echo "✅ Inicialização concluída com sucesso!"
    echo "=========================================================="
else
    echo "✅ Garage já estava inicializado. Carregando dados do Volume..."
fi

# Mantém o container vivo
wait $GARAGE_PID