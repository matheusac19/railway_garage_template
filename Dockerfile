# Usa uma imagem Alpine levíssima
FROM alpine:3.19

# Instala ferramentas necessárias
RUN apk add --no-cache curl awk openssl

# Baixa a versão oficial mais recente do Garage (v2.2.0)
RUN curl -L -o /usr/local/bin/garage https://garagehq.deuxfleurs.fr/_releases/v2.2.0/x86_64-unknown-linux-musl/garage \
    && chmod +x /usr/local/bin/garage

# Cria as pastas necessárias
RUN mkdir -p /data/meta /data/data /etc/garage

# Copia o nosso script mágico e dá permissão de execução
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Inicia o container pelo nosso script
CMD ["/start.sh"]