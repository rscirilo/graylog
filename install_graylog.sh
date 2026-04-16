#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Script: install_graylog_compat.sh
# Objetivo: Instalar Graylog + MongoDB + OpenSearch SEM Docker
#           em Debian 13 (Trixie), com dados em /srv
#           e senha padrão do admin: @123Mudar
# Autor: Rodrigo Cirilo (layout de passos adaptado)
# =====================================================================

ADMIN_PASS='@123Mudar'
SERVER_IP="192.168.100.2"      # ajuste se quiser, é só para mensagem final
TIMEZONE="America/Fortaleza"

# Diretórios de dados
BASE_DIR="/srv"
GRAYLOG_DIR="${BASE_DIR}/graylog"
MONGO_DIR="${BASE_DIR}/mongodb"
OPENSEARCH_DIR="${BASE_DIR}/opensearch"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Execute como root."
  exit 1
fi

echo "[1/12] Preparando sistema"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y ca-certificates curl gnupg lsb-release apt-transport-https pwgen

echo "[2/12] Ajustando timezone"
timedatectl set-timezone "${TIMEZONE}" || true

echo "[3/12] Criando estrutura em /srv"
mkdir -p "${GRAYLOG_DIR}"/{etc,data,logs}
mkdir -p "${MONGO_DIR}"/data
mkdir -p "${OPENSEARCH_DIR}"/data

echo "[4/12] Instalando Java (OpenJDK)"
apt install -y openjdk-11-jre-headless

# =====================================================================
# MongoDB - versão compatível (exemplo: 6.x)
# =====================================================================
echo "[5/12] Instalando MongoDB"

# Repo MongoDB (ajuste se a versão mudar na doc oficial)
if ! test -f /etc/apt/trusted.gpg.d/mongodb-org-6.gpg; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/mongodb-org-6.gpg
fi

cat >/etc/apt/sources.list.d/mongodb-org-6.list <<EOF
deb [ arch=amd64,arm64 signed-by=/etc/apt/trusted.gpg.d/mongodb-org-6.gpg ] https://repo.mongodb.org/apt/debian $(lsb_release -sc)/mongodb-org/6.0 main
EOF

apt update
apt install -y mongodb-org

# Ajusta dbPath -> /srv/mongodb/data
sed -i 's|^  dbPath:.*|  dbPath: /srv/mongodb/data|' /etc/mongod.conf
chown -R mongodb:mongodb "${MONGO_DIR}"

systemctl enable mongod
systemctl restart mongod

# =====================================================================
# OpenSearch (modo compat) - single node
# =====================================================================
echo "[6/12] Instalando OpenSearch"

if ! test -f /etc/apt/trusted.gpg.d/opensearch.gpg; then
  curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/opensearch.gpg
fi

cat >/etc/apt/sources.list.d/opensearch-2.x.list <<EOF
deb [ signed-by=/etc/apt/trusted.gpg.d/opensearch.gpg ] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main
EOF

apt update
apt install -y opensearch

# Configuração mínima para single-node, sem segurança interna
OPENSEARCH_YML="/etc/opensearch/opensearch.yml"

sed -i 's|^#\?cluster.name:.*|cluster.name: graylog|' "${OPENSEARCH_YML}"
sed -i 's|^#\?node.name:.*|node.name: node-1|' "${OPENSEARCH_YML}"
sed -i 's|^#\?path.data:.*|path.data: /srv/opensearch/data|' "${OPENSEARCH_YML}"
sed -i 's|^#\?path.logs:.*|path.logs: /var/log/opensearch|' "${OPENSEARCH_YML}"

# Single-node, desabilita segurança interna para uso em lab (NÃO use assim em produção)
grep -q '^discovery.type:' "${OPENSEARCH_YML}" \
  && sed -i 's|^discovery.type:.*|discovery.type: single-node|' "${OPENSEARCH_YML}" \
  || echo "discovery.type: single-node" >> "${OPENSEARCH_YML}"

grep -q '^plugins.security.disabled:' "${OPENSEARCH_YML}" \
  && sed -i 's|^plugins.security.disabled:.*|plugins.security.disabled: true|' "${OPENSEARCH_YML}" \
  || echo "plugins.security.disabled: true" >> "${OPENSEARCH_YML}"

chown -R opensearch:opensearch "${OPENSEARCH_DIR}"

# vm.max_map_count para OpenSearch
echo "[7/12] Ajustando vm.max_map_count para OpenSearch"
cat >/etc/sysctl.d/99-opensearch.conf <<EOF
vm.max_map_count=262144
EOF
sysctl --system

systemctl enable opensearch
systemctl restart opensearch

# =====================================================================
# Graylog
# =====================================================================
echo "[8/12] Instalando Graylog"

# Repo Graylog (5.x como base compat; ajuste conforme doc oficial)
if ! test -f /etc/apt/trusted.gpg.d/graylog.gpg; then
  curl -fsSL https://packages.graylog2.org/repo/packages/graylog-5.x-repository_latest.deb -o /tmp/graylog-repo.deb
  dpkg -i /tmp/graylog-repo.deb
fi

apt update
apt install -y graylog-server

# Gera password_secret e root_password_sha2
echo "[9/12] Configurando Graylog (password_secret e root_password_sha2)"
GRAYLOG_CONF="/etc/graylog/server/server.conf"

# password_secret: string grande e aleatória
if ! grep -q '^password_secret = ' "${GRAYLOG_CONF}"; then
  PASSWORD_SECRET="$(pwgen -N 1 -s 96)"
  echo "password_secret = ${PASSWORD_SECRET}" >> "${GRAYLOG_CONF}"
else
  PASSWORD_SECRET="$(pwgen -N 1 -s 96)"
  sed -i "s|^password_secret = .*|password_secret = ${PASSWORD_SECRET}|" "${GRAYLOG_CONF}"
fi

# root_password_sha2 com base em ADMIN_PASS
ROOT_SHA2="$(printf '%s' "${ADMIN_PASS}" | sha256sum | awk '{print $1}')"
if ! grep -q '^root_password_sha2 = ' "${GRAYLOG_CONF}"; then
  echo "root_password_sha2 = ${ROOT_SHA2}" >> "${GRAYLOG_CONF}"
else
  sed -i "s|^root_password_sha2 = .*|root_password_sha2 = ${ROOT_SHA2}|" "${GRAYLOG_CONF}"
fi

# Ajusta bind address e OpenSearch
sed -i "s|^#\?http_bind_address = .*|http_bind_address = 0.0.0.0:9000|" "${GRAYLOG_CONF}"

# Ajusta output para usar OpenSearch
# Exemplos baseados na doc de "self-managed OpenSearch" (ajuste se a sintaxe mudar) [web:611]
if ! grep -q '^elasticsearch_hosts = ' "${GRAYLOG_CONF}"; then
  echo "elasticsearch_hosts = http://127.0.0.1:9200" >> "${GRAYLOG_CONF}"
else
  sed -i 's|^elasticsearch_hosts = .*|elasticsearch_hosts = http://127.0.0.1:9200|' "${GRAYLOG_CONF}"
fi

# Cria link de dados para /srv se quiser usar como storage Graylog (opcional)
# Aqui deixo só como exemplo: você pode montar /var/lib/graylog-server -> /srv/graylog/data
if [[ ! -d /var/lib/graylog-server.bak && -d /var/lib/graylog-server ]]; then
  mv /var/lib/graylog-server /var/lib/graylog-server.bak
fi
if [[ ! -L /var/lib/graylog-server ]]; then
  ln -s "${GRAYLOG_DIR}/data" /var/lib/graylog-server
fi

chown -R graylog:graylog "${GRAYLOG_DIR}"

echo "[10/12] Habilitando serviços no systemd"
systemctl daemon-reload
systemctl enable mongod
systemctl enable opensearch
systemctl enable graylog-server

echo "[11/12] Reiniciando serviços"
systemctl restart mongod
systemctl restart opensearch
systemctl restart graylog-server

echo "[12/12] Status dos serviços"
systemctl --no-pager status mongod --lines=3 || true
systemctl --no-pager status opensearch --lines=3 || true
systemctl --no-pager status graylog-server --lines=3 || true

echo
echo "============================================================"
echo "Instalacao concluida do Graylog (modo compat, sem Docker)."
echo
echo "Graylog   : http://${SERVER_IP}:9000"
echo
echo "Credenciais iniciais:"
echo "Graylog   : admin / ${ADMIN_PASS}"
echo
echo "ATENCAO: altere a senha do usuario admin apos o primeiro login."
echo "============================================================"
echo
