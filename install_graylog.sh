#!/bin/bash

# Graylog All-in-One Installer for Debian 13
# Executar como root (sudo)

set -e

echo "--- Iniciando instalação do Graylog ---"

# 1. Atualização do Sistema e Dependências
apt-get update && apt-get install -y apt-transport-https gnupg2 curl uuid-runtime dirmngr pwgen openjdk-17-jre-headless

# 2. Instalação do MongoDB 6.0
curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list
apt-get update && apt-get install -y mongodb-org
systemctl enable mongod && systemctl start mongod

# 3. Instalação do OpenSearch 2.x
curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp | gpg --dearmor -o /usr/share/keyrings/opensearch.gpg
echo "deb [ signed-by=/usr/share/keyrings/opensearch.gpg ] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" | tee /etc/apt/sources.list.d/opensearch-2.x.list
apt-get update && apt-get install -y opensearch
systemctl enable opensearch && systemctl start opensearch

# 4. Instalação do Graylog 6.0
wget https://packages.graylog2.org/repo/packages/graylog-6.0-repository_latest.deb
dpkg -i graylog-6.0-repository_latest.deb
apt-get update && apt-get install -y graylog-server

# 5. Configuração de Segurança (Geração de Secrets)
SECRET=$(pwgen -s 96 1)
sed -i "s/password_secret =.*/password_secret = $SECRET/" /etc/graylog/server/server.conf

# Defina sua senha de admin aqui (padrão: admin)
ADMIN_HASH=$(echo -n "admin" | sha256sum | awk '{print $1}')
sed -i "s/root_password_sha2 =.*/root_password_sha2 = $ADMIN_HASH/" /etc/graylog/server/server.conf

# Permitir acesso externo na porta 9000
sed -i 's/#http_bind_address = 127.0.0.1:9000/http_bind_address = 0.0.0.0:9000/' /etc/graylog/server/server.conf

# 6. Inicialização
systemctl daemon-reload
systemctl enable graylog-server
systemctl start graylog-server

echo "--- Instalação concluída! ---"
echo "Acesse: http://$(hostname -I | awk '{print $1}'):9000"
echo "Usuário: admin | Senha: admin"
