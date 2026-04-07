# Dockerfile
# Usa uma imagem Alpine levíssima
FROM alpine:3.19

# Instala ferramentas necessárias (Garantindo awk e openssl)
RUN apk add --no-cache curl openssl gawk

# Baixa a versão oficial mais recente do Garage
RUN curl -L -o /usr/local/bin/garage https://garagehq.deuxfleurs.fr/_releases/v2.2.0/x86_64-unknown-linux-musl/garage \
    && chmod +x /usr/local/bin/garage

# Cria as pastas necessárias
RUN mkdir -p /data/meta /data/data /etc/garage

# Copia o nosso script e dá permissão
COPY start.sh /start.sh
RUN chmod +x /start.sh

# A LINHA QUE ESTÁ FALTANDO NO LOG:
CMD ["/start.sh"]