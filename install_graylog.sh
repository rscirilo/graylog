#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# install_graylog_compat.sh
# Autor: Rodrigo Cirilo
#
# Graylog 5.x + MongoDB 4.4 (tarball) + OpenSearch 2.19.1 (tarball)
# Debian 13 Trixie | SEM Docker | SEM AVX | dados em /srv
#
# Uso: bash install_graylog_compat.sh
#
# Variaveis configuraveis:
#   ADMIN_PASS  - senha do usuario admin do Graylog
#   SERVER_IP   - IP da VM (usado na interface web)
#   TIMEZONE    - fuso horario
#
# Compatibilidade:
#   Graylog 5.x  -> MongoDB 4.4 - 6.x  -> OK
#   Graylog 5.x  -> OpenSearch 1.x/2.x -> OK
#   MongoDB 4.4  -> sem AVX             -> OK (SIGILL resolvido)
#   Trixie t64   -> libcurl4t64, libssl3t64, libldap2 -> OK
# =====================================================================

# --- VARIAVEIS CONFIGURAVEIS -----------------------------------------
ADMIN_PASS='@123Mudar'
SERVER_IP="192.168.100.2"
TIMEZONE="America/Fortaleza"

# --- VARIAVEIS INTERNAS ----------------------------------------------
BASE_DIR="/srv"
GRAYLOG_DIR="${BASE_DIR}/graylog"
MONGO_DIR="${BASE_DIR}/mongodb"
OPENSEARCH_DIR="${BASE_DIR}/opensearch"

GRAYLOG_MAJOR="5"
MONGO_VERSION="4.4.29"
OS_VERSION="2.19.1"

MONGO_INSTALL_DIR="/opt/mongodb"
OS_INSTALL_DIR="/opt/opensearch"

# ---------------------------------------------------------------------
wait_service() {
  local name="$1" seconds="${2:-20}"
  echo "  -> Aguardando ${name} inicializar (${seconds}s)..."
  sleep "${seconds}"
}

check_port() {
  local name="$1" port="$2"
  if ss -tlnp | grep -q ":${port}"; then
    echo "  -> ${name} OK (porta ${port} em escuta)"
  else
    echo "  [AVISO] ${name} nao responde na porta ${port}."
    echo "          Verifique: journalctl -u ${name} -n 50 --no-pager"
  fi
}

# ---------------------------------------------------------------------
[[ "${EUID}" -ne 0 ]] && { echo "[ERRO] Execute como root."; exit 1; }

AVX_STATUS="$(grep -m1 -oE 'avx2?|sse4_2' /proc/cpuinfo | head -1 || true)"
echo "================================================================"
echo " Graylog ${GRAYLOG_MAJOR}.x + MongoDB ${MONGO_VERSION} + OpenSearch ${OS_VERSION}"
echo " Debian 13 Trixie | SEM Docker | SEM AVX"
echo " CPU flags: ${AVX_STATUS:-nenhuma detectada (sem AVX -- usando tarballs)}"
echo "================================================================"

# =====================================================================
echo ""
echo "[1/13] Preparando sistema"
# =====================================================================
export DEBIAN_FRONTEND=noninteractive

# Remove repos problematicos ANTES do primeiro apt update:
#   mongodb-org  5.0+ exige AVX -> SIGILL em VM sem AVX
#   opensearch   apt  usa SHA-1 -> rejeitado no Trixie
#   mongodb-org  6/7  usa SHA-1 -> rejeitado no Trixie
rm -f \
  /etc/apt/sources.list.d/mongodb-org-*.list \
  /etc/apt/sources.list.d/opensearch-2.x.list \
  /etc/apt/sources.list.d/graylog*.list \
  /usr/share/keyrings/mongodb-*.gpg \
  /usr/share/keyrings/opensearch.gpg \
  /usr/share/keyrings/graylog*.gpg \
  /etc/apt/trusted.gpg.d/mongodb-org-*.gpg \
  /etc/apt/trusted.gpg.d/opensearch.gpg 2>/dev/null || true

# Remove mongodb-org de tentativa anterior
if dpkg -l 2>/dev/null | grep -q mongodb-org; then
  echo "  -> Removendo mongodb-org anterior (exige AVX, incompativel)..."
  systemctl stop mongod 2>/dev/null || true
  apt-get remove --purge -y \
    mongodb-org mongodb-org-server mongodb-org-mongos \
    mongodb-org-tools mongodb-mongosh 2>/dev/null || true
  apt-get autoremove -y -qq
fi

apt-get update -qq

# Nomes corretos para Debian 13 Trixie:
#   libcurl4      -> libcurl4t64   (transicao 64-bit time_t)
#   libssl3       -> libssl3t64
#   libldap-2.x-0 -> libldap2
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  apt-transport-https pwgen wget python3 iproute2 \
  libcurl4t64 libssl3t64 libldap2 \
  libgssapi-krb5-2 libwrap0 libsasl2-2 liblzma5

# =====================================================================
echo ""
echo "[2/13] Ajustando timezone"
# =====================================================================
timedatectl set-timezone "${TIMEZONE}" || true
echo "  -> Timezone: ${TIMEZONE}"

# =====================================================================
echo ""
echo "[3/13] Criando estrutura em /srv"
# =====================================================================
mkdir -p "${GRAYLOG_DIR}"/{etc,data,logs,journal}
mkdir -p "${MONGO_DIR}"/{data,logs}
mkdir -p "${OPENSEARCH_DIR}/data"
echo "  -> Diretorios criados em ${BASE_DIR}"

# =====================================================================
echo ""
echo "[4/13] Instalando Java 17"
# =====================================================================
# openjdk-11 nao existe no Trixie; Java 17 e o minimo para Graylog 5+
apt-get install -y openjdk-17-jre-headless || \
  apt-get install -y default-jre-headless
java -version 2>&1 | head -1

# =====================================================================
echo ""
echo "[5/13] Instalando MongoDB ${MONGO_VERSION} via tarball (sem AVX)"
# =====================================================================
# MongoDB 4.4 = ultima versao sem exigencia de AVX
# Tarball debian10 (buster) roda em Trixie sem problema de libc
MONGO_TARBALL="mongodb-linux-x86_64-debian10-${MONGO_VERSION}.tgz"
MONGO_URL="https://fastdl.mongodb.org/linux/${MONGO_TARBALL}"

echo "  -> Baixando MongoDB ${MONGO_VERSION} (~80MB)..."
wget -q --show-progress -O "/tmp/${MONGO_TARBALL}" "${MONGO_URL}"

rm -rf "${MONGO_INSTALL_DIR}"
mkdir -p "${MONGO_INSTALL_DIR}"
tar -xzf "/tmp/${MONGO_TARBALL}" -C "${MONGO_INSTALL_DIR}" --strip-components=1
rm -f "/tmp/${MONGO_TARBALL}"

if ! id mongodb &>/dev/null; then
  useradd -r -s /sbin/nologin -d "${MONGO_INSTALL_DIR}" mongodb
fi

# Links simbolicos para /usr/local/bin
ln -sf "${MONGO_INSTALL_DIR}/bin/mongod" /usr/local/bin/mongod
ln -sf "${MONGO_INSTALL_DIR}/bin/mongos" /usr/local/bin/mongos

chown -R mongodb:mongodb "${MONGO_DIR}" "${MONGO_INSTALL_DIR}"

# Configuracao MongoDB (formato YAML)
cat > /etc/mongod.conf <<EOF
systemLog:
  destination: file
  logAppend: true
  path: ${MONGO_DIR}/logs/mongod.log

storage:
  dbPath: ${MONGO_DIR}/data
  journal:
    enabled: true

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

net:
  port: 27017
  bindIp: 127.0.0.1
EOF

# Unit systemd para MongoDB instalado via tarball
cat > /etc/systemd/system/mongod.service <<EOF
[Unit]
Description=MongoDB ${MONGO_VERSION} (tarball, sem AVX)
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=mongodb
Group=mongodb
ExecStart=/usr/local/bin/mongod --config /etc/mongod.conf --fork
ExecStop=/usr/local/bin/mongod --config /etc/mongod.conf --shutdown
PIDFile=${MONGO_DIR}/data/mongod.pid
LimitNOFILE=64000
LimitNPROC=64000
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mongod
systemctl restart mongod
wait_service "MongoDB" 12
check_port "MongoDB" "27017"

# =====================================================================
echo ""
echo "[6/13] Instalando OpenSearch ${OS_VERSION} via tarball"
# =====================================================================
# Tarball inclui JDK proprio -- nao depende do Java do sistema
# Seguranca desabilitada: ambiente de lab only
OS_TARBALL="opensearch-${OS_VERSION}-linux-x64.tar.gz"
OS_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/${OS_TARBALL}"
OS_DATA_DIR="${OPENSEARCH_DIR}/data"
OS_LOG_DIR="/var/log/opensearch"

echo "  -> Baixando OpenSearch ${OS_VERSION} (~600MB, aguarde)..."
wget -q --show-progress -O "/tmp/${OS_TARBALL}" "${OS_URL}"

rm -rf "${OS_INSTALL_DIR}"
mkdir -p "${OS_INSTALL_DIR}"
tar -xzf "/tmp/${OS_TARBALL}" -C "${OS_INSTALL_DIR}" --strip-components=1
rm -f "/tmp/${OS_TARBALL}"

if ! id opensearch &>/dev/null; then
  useradd -r -s /sbin/nologin -d "${OS_INSTALL_DIR}" opensearch
fi

mkdir -p "${OS_DATA_DIR}" "${OS_LOG_DIR}"
chown -R opensearch:opensearch \
  "${OS_INSTALL_DIR}" "${OS_DATA_DIR}" "${OS_LOG_DIR}"

OPENSEARCH_YML="${OS_INSTALL_DIR}/config/opensearch.yml"

python3 - <<PYEOF
import re

yml = open("${OPENSEARCH_YML}").read()

settings = {
    r'#?\\s*cluster\\.name:.*':   'cluster.name: graylog',
    r'#?\\s*node\\.name:.*':      'node.name: node-1',
    r'#?\\s*path\\.data:.*':      'path.data: ${OS_DATA_DIR}',
    r'#?\\s*path\\.logs:.*':      'path.logs: ${OS_LOG_DIR}',
    r'#?\\s*network\\.host:.*':   'network.host: 127.0.0.1',
    r'#?\\s*http\\.port:.*':      'http.port: 9200',
    r'#?\\s*discovery\\.type:.*': 'discovery.type: single-node',
}

for pattern, replacement in settings.items():
    if re.search(pattern, yml, re.MULTILINE):
        yml = re.sub(pattern, replacement, yml, flags=re.MULTILINE)
    else:
        yml += f'\\n{replacement}\\n'

# Desabilita seguranca -- lab only, nunca em producao
extras = {
    'plugins.security.disabled': 'true',
    'plugins.security.ssl.http.enabled': 'false',
    'plugins.security.ssl.transport.enforce_hostname_verification': 'false',
}
for key, val in extras.items():
    if key not in yml:
        yml += f'\\n{key}: {val}\\n'
    else:
        yml = re.sub(rf'{re.escape(key)}:.*', f'{key}: {val}', yml)

open("${OPENSEARCH_YML}", "w").write(yml)
print("  opensearch.yml atualizado.")
PYEOF

# Unit systemd para OpenSearch instalado via tarball
cat > /etc/systemd/system/opensearch.service <<EOF
[Unit]
Description=OpenSearch ${OS_VERSION} (tarball)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
RuntimeDirectory=opensearch
WorkingDirectory=${OS_INSTALL_DIR}
Environment=OPENSEARCH_HOME=${OS_INSTALL_DIR}
Environment=OPENSEARCH_PATH_CONF=${OS_INSTALL_DIR}/config
Environment=OPENSEARCH_JAVA_HOME=${OS_INSTALL_DIR}/jdk
ExecStart=${OS_INSTALL_DIR}/bin/opensearch
User=opensearch
Group=opensearch
LimitNOFILE=65536
LimitNPROC=4096
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# =====================================================================
echo ""
echo "[7/13] Ajustando kernel para OpenSearch"
# =====================================================================
cat > /etc/sysctl.d/99-opensearch.conf <<EOF
vm.max_map_count=262144
EOF
sysctl --system -q
echo "  -> vm.max_map_count=262144 aplicado"

systemctl daemon-reload
systemctl enable opensearch
systemctl restart opensearch
wait_service "OpenSearch" 45

if curl -sf http://127.0.0.1:9200 > /dev/null 2>&1; then
  echo "  -> OpenSearch OK (porta 9200 respondendo)"
else
  echo "  [AVISO] OpenSearch ainda nao responde na porta 9200."
  echo "          Verifique: journalctl -u opensearch -n 50 --no-pager"
fi

# =====================================================================
echo ""
echo "[8/13] Instalando Graylog ${GRAYLOG_MAJOR}.x"
# =====================================================================
# Graylog 5.x: suporta MongoDB 4.4-6.x e OpenSearch 1.x/2.x
# .deb configura repo com "stable" -- nao usa lsb_release -sc

rm -f /tmp/graylog-repo.deb \
      /etc/apt/sources.list.d/graylog*.list \
      /usr/share/keyrings/graylog*.gpg \
      /etc/apt/trusted.gpg.d/graylog*.gpg 2>/dev/null || true

echo "  -> Baixando repo Graylog ${GRAYLOG_MAJOR}.x..."
wget -qO /tmp/graylog-repo.deb \
  "https://packages.graylog2.org/repo/packages/graylog-${GRAYLOG_MAJOR}.x-repository_latest.deb"

dpkg -i /tmp/graylog-repo.deb

# Garante bookworm caso o .deb tenha inserido trixie
for f in /etc/apt/sources.list.d/graylog*.list; do
  [[ -f "${f}" ]] && sed -i 's/trixie/bookworm/g' "${f}"
done

apt-get update -qq
apt-get install -y graylog-server

# =====================================================================
echo ""
echo "[9/13] Configurando Graylog"
# =====================================================================
GRAYLOG_CONF="/etc/graylog/server/server.conf"

PASSWORD_SECRET="$(pwgen -N 1 -s 96)"
ROOT_SHA2="$(printf '%s' "${ADMIN_PASS}" | sha256sum | awk '{print $1}')"

set_conf() {
  local key="$1" value="$2"
  if grep -qE "^#?\s*${key}\s*=" "${GRAYLOG_CONF}"; then
    sed -i "s|^#\?\s*${key}\s*=.*|${key} = ${value}|" "${GRAYLOG_CONF}"
  else
    echo "${key} = ${value}" >> "${GRAYLOG_CONF}"
  fi
}

set_conf "password_secret"     "${PASSWORD_SECRET}"
set_conf "root_password_sha2"  "${ROOT_SHA2}"
set_conf "http_bind_address"   "0.0.0.0:9000"
set_conf "http_publish_uri"    "http://${SERVER_IP}:9000/"
set_conf "elasticsearch_hosts" "http://127.0.0.1:9200"
set_conf "message_journal_dir" "${GRAYLOG_DIR}/journal"

echo "  -> server.conf atualizado"
echo "  -> password_secret gerado (96 chars)"
echo "  -> root_password_sha2 definido"

mkdir -p /etc/systemd/system/graylog-server.service.d
cat > /etc/systemd/system/graylog-server.service.d/override.conf <<EOF
[Service]
ReadWritePaths=${GRAYLOG_DIR}
EOF

chown -R graylog:graylog "${GRAYLOG_DIR}"

# =====================================================================
echo ""
echo "[10/13] Habilitando servicos no boot"
# =====================================================================
systemctl daemon-reload
systemctl enable mongod opensearch graylog-server
echo "  -> mongod, opensearch, graylog-server habilitados"

# =====================================================================
echo ""
echo "[11/13] Reiniciando servicos na ordem correta"
# =====================================================================
systemctl restart mongod
wait_service "MongoDB (restart final)" 10

systemctl restart opensearch
wait_service "OpenSearch (restart final)" 45

systemctl restart graylog-server
wait_service "Graylog" 40

# =====================================================================
echo ""
echo "[12/13] Validando portas"
# =====================================================================
check_port "MongoDB"    "27017"
check_port "OpenSearch" "9200"

if curl -sf "http://127.0.0.1:9000/api" > /dev/null 2>&1; then
  echo "  -> Graylog API OK (porta 9000)"
else
  echo "  [AVISO] Graylog ainda nao responde na porta 9000."
  echo "          Aguarde 30s e tente: curl -s http://127.0.0.1:9000/api"
  echo "          Verifique: journalctl -u graylog-server -n 50 --no-pager"
fi

# =====================================================================
echo ""
echo "[13/13] Status dos servicos"
# =====================================================================
for svc in mongod opensearch graylog-server; do
  echo "--- ${svc} ---"
  systemctl --no-pager status "${svc}" --lines=5 || true
  echo ""
done

echo "================================================================"
echo " Instalacao concluida -- Graylog ${GRAYLOG_MAJOR}.x (sem Docker)"
echo " Autor: Rodrigo Cirilo"
echo ""
echo "  Interface web    : http://${SERVER_IP}:9000"
echo "  Usuario          : admin"
echo "  Senha            : ${ADMIN_PASS}"
echo ""
echo "  Logs em tempo real:"
echo "    journalctl -u graylog-server -f"
echo "    journalctl -u opensearch -f"
echo "    journalctl -u mongod -f"
echo ""
echo "  Arquivos de configuracao:"
echo "    Graylog   : ${GRAYLOG_CONF}"
echo "    OpenSearch: ${OS_INSTALL_DIR}/config/opensearch.yml"
echo "    MongoDB   : /etc/mongod.conf"
echo ""
echo "  Diretorios de dados:"
echo "    Graylog   : ${GRAYLOG_DIR}"
echo "    OpenSearch: ${OS_DATA_DIR}"
echo "    MongoDB   : ${MONGO_DIR}/data"
echo ""
echo "  ATENCAO: ambiente de lab."
echo "  Altere a senha admin apos o primeiro login."
echo "================================================================"
