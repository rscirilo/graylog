#!/usr/bin/env bash
set -e

# ============================================================================
# Script de instalação Graylog 4.3 + MongoDB 4.4 + Elasticsearch 7.10.2
# Ambiente-alvo: Debian 13 (Trixie) SEM AVX (IFRN Parnamirim)
# Autor: Rodrigo Cirilo (rscirilo) - https://github.com/rscirilo/graylog
# ============================================================================

# Configurações padrão
ADMIN_PASSWORD_PLAINTEXT="integrador2026"
GRAYLOG_VERSION_REPO_DEB="4.3"
MONGO_VERSION="4.4.30"
ES_VERSION="7.10.2"
MONGO_DEB_DIR="/srv/mongodb-debs"
SERVER_CONF="/etc/graylog/server/server.conf"

echo "==== Graylog 4.3 Installer para Debian 13 (Trixie) ===="
echo "Senha do usuário admin do Graylog será: ${ADMIN_PASSWORD_PLAINTEXT}"
echo

# --------------------------------------------------------------------------
# 0. Checagens iniciais
# --------------------------------------------------------------------------
if [[ $(id -u) -ne 0 ]]; then
  echo "Este script deve ser executado como root. Use: sudo bash install_graylog4.sh"
  exit 1
fi

if ! command -v lsb_release >/dev/null 2>&1; then
  apt-get update
  apt-get install -y lsb-release
fi

DISTRO=$(lsb_release -si 2>/dev/null || echo "Desconhecido")
CODENAME=$(lsb_release -sc 2>/dev/null || echo "desconhecido")

echo "Distribuição detectada: ${DISTRO} (${CODENAME})"
if [[ "${DISTRO}" != "Debian" || "${CODENAME}" != "trixie" ]]; then
  echo "AVISO: este script foi pensado para Debian 13 (trixie). Continuando mesmo assim..."
fi

echo "Atualizando sistema..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "Instalando utilitários básicos..."
apt-get install -y curl wget nano pwgen gnupg apt-transport-https ca-certificates net-tools jq

# --------------------------------------------------------------------------
# 1. MongoDB 4.4 via .deb (sem AVX)
# --------------------------------------------------------------------------
echo
echo "==== 1/4 - Instalando MongoDB ${MONGO_VERSION} (via .deb) ===="

mkdir -p "${MONGO_DEB_DIR}"
cd "${MONGO_DEB_DIR}"

# Baixar pacotes somente se ainda não existirem
test -f libssl1.1_1.1.1n-0+deb11u5_amd64.deb || \
wget -q https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/libssl1.1_1.1.1n-0+deb11u5_amd64.deb

test -f mongodb-org-server_${MONGO_VERSION}_amd64.deb || \
wget -q https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-server_${MONGO_VERSION}_amd64.deb

test -f mongodb-org-mongos_${MONGO_VERSION}_amd64.deb || \
wget -q https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-mongos_${MONGO_VERSION}_amd64.deb

test -f mongodb-org-shell_${MONGO_VERSION}_amd64.deb || \
wget -q https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-shell_${MONGO_VERSION}_amd64.deb

test -f mongodb-org-database-tools-extra_${MONGO_VERSION}_amd64.deb || \
wget -q https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-database-tools-extra_${MONGO_VERSION}_amd64.deb

echo "Instalando pacotes MongoDB..."
dpkg -i libssl1.1_1.1.1n-0+deb11u5_amd64.deb || true
dpkg -i mongodb-org-server_${MONGO_VERSION}_amd64.deb mongodb-org-mongos_${MONGO_VERSION}_amd64.deb \
       mongodb-org-shell_${MONGO_VERSION}_amd64.deb mongodb-org-database-tools-extra_${MONGO_VERSION}_amd64.deb || \
       apt-get install -f -y

systemctl daemon-reload
systemctl enable --now mongod
sleep 5

echo "Verificando MongoDB..."
mongo --eval "db.adminCommand({serverStatus:1}).version" || {
  echo "ERRO: MongoDB não subiu corretamente. Verifique 'journalctl -eu mongod'."
  exit 1
}

# --------------------------------------------------------------------------
# 2. Elasticsearch 7.10.2
# --------------------------------------------------------------------------
echo
echo "==== 2/4 - Instalando Elasticsearch ${ES_VERSION} ===="

if [ ! -f /usr/share/keyrings/elasticsearch-keyring.gpg ]; then
  wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
fi

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" \
  > /etc/apt/sources.list.d/elasticsearch-7.x.list

apt-get update
apt-get install -y "elasticsearch=${ES_VERSION}"

# Configuração básica do Elasticsearch
ES_YML="/etc/elasticsearch/elasticsearch.yml"
cp "${ES_YML}" "${ES_YML}.bak.$(date +%s)" || true

cat > "${ES_YML}" <<EOF
cluster.name: graylog
node.name: integrador2026
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

network.host: 0.0.0.0
http.port: 9200

discovery.type: single-node
EOF

systemctl daemon-reload
systemctl enable --now elasticsearch
echo "Aguardando Elasticsearch subir..."
sleep 20

if ! curl -s http://localhost:9200 >/dev/null 2>&1; then
  echo "ERRO: Elasticsearch não respondeu em http://localhost:9200"
  exit 1
fi

# --------------------------------------------------------------------------
# 3. Graylog 4.3
# --------------------------------------------------------------------------
echo
echo "==== 3/4 - Instalando Graylog 4.3 ===="

# Repositório Graylog 4.3
wget -qO /tmp/graylog-4.3-repository_latest.deb https://packages.graylog2.org/repo/packages/graylog-4.3-repository_latest.deb
dpkg -i /tmp/graylog-4.3-repository_latest.deb || true

# Força repo confiável (SHA1)
echo "deb [trusted=yes] https://packages.graylog2.org/repo/debian/ stable ${GRAYLOG_VERSION_REPO_DEB}" \
  > /etc/apt/sources.list.d/graylog.list

apt-get update
apt-get install -y graylog-server

# --------------------------------------------------------------------------
# 4. Configuração do Graylog
# --------------------------------------------------------------------------
echo
echo "==== 4/4 - Configurando Graylog ===="

if [ ! -f "${SERVER_CONF}" ]; then
  echo "ERRO: Arquivo ${SERVER_CONF} não encontrado."
  exit 1
fi

cp "${SERVER_CONF}" "${SERVER_CONF}.bak.$(date +%s)"

# Gerar password_secret
PASSWORD_SECRET=$(pwgen -N 1 -s 96)
echo "password_secret gerado."

# Gerar hash SHA256 da senha do admin
ADMIN_HASH=$(echo -n "${ADMIN_PASSWORD_PLAINTEXT}" | sha256sum | awk '{print $1}')
echo "Hash da senha admin gerado."

# Ajustar server.conf
sed -i "s/^password_secret =.*/password_secret = ${PASSWORD_SECRET}/" "${SERVER_CONF}"
sed -i "s/^root_password_sha2 =.*/root_password_sha2 = ${ADMIN_HASH}/" "${SERVER_CONF}"

# Ajustar MongoDB
if grep -q "^mongodb_uri" "${SERVER_CONF}"; then
  sed -i "s|^mongodb_uri =.*|mongodb_uri = mongodb://localhost/graylog|" "${SERVER_CONF}"
else
  echo "mongodb_uri = mongodb://localhost/graylog" >> "${SERVER_CONF}"
fi

# Ajustar Elasticsearch
if grep -q "^elasticsearch_hosts" "${SERVER_CONF}"; then
  sed -i "s|^elasticsearch_hosts =.*|elasticsearch_hosts = http://localhost:9200|" "${SERVER_CONF}"
else
  echo "elasticsearch_hosts = http://localhost:9200" >> "${SERVER_CONF}"
fi

# http_bind_address: ouvir em todas as interfaces na porta 9000
if grep -q "^http_bind_address" "${SERVER_CONF}"; then
  sed -i "s|^http_bind_address =.*|http_bind_address = 0.0.0.0:9000|" "${SERVER_CONF}"
else
  echo "http_bind_address = 0.0.0.0:9000" >> "${SERVER_CONF}"
fi

# http_publish_uri: tenta descobrir IP automaticamente
IP_SERVER=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "${IP_SERVER}" ] && IP_SERVER="127.0.0.1"

if grep -q "^http_publish_uri" "${SERVER_CONF}"; then
  sed -i "s|^http_publish_uri =.*|http_publish_uri = http://${IP_SERVER}:9000/|" "${SERVER_CONF}"
else
  echo "http_publish_uri = http://${IP_SERVER}:9000/" >> "${SERVER_CONF}"
fi

# Journal: reduzir para 1 GB
if grep -q "^message_journal_max_size" "${SERVER_CONF}"; then
  sed -i "s|^message_journal_max_size =.*|message_journal_max_size = 1gb|" "${SERVER_CONF}"
else
  echo "message_journal_max_size = 1gb" >> "${SERVER_CONF}"
fi

# --------------------------------------------------------------------------
# 5. Iniciar Graylog
# --------------------------------------------------------------------------
echo
echo "Iniciando serviço graylog-server..."
systemctl daemon-reload
systemctl enable --now graylog-server

echo "Aguardando Graylog inicializar (30s)..."
sleep 30

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/api/system/lbstatus || echo "000")
echo "Status da API do Graylog: HTTP ${HTTP_CODE}"

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ATENÇÃO: Graylog não retornou 200 ainda. Verifique logs com:"
  echo "  journalctl -eu graylog-server --no-pager | tail -40"
  exit 1
fi

echo
echo "=================================================================="
echo " Graylog 4.3 instalado com sucesso!"
echo
echo " URL de acesso web:  http://${IP_SERVER}:9000/"
echo " Usuário:            admin"
echo " Senha:              ${ADMIN_PASSWORD_PLAINTEXT}"
echo "=================================================================="
