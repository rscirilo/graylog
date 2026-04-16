#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Script: install_graylog_compat.sh
# Graylog 6.x + MongoDB 8.0 + OpenSearch 2.x
# Debian 13 Trixie — SEM Docker — dados em /srv
# Senha admin: @123Mudar
#
# MongoDB 8.0: único com repo nativo para Trixie (chave SHA-256)
# Graylog 6.x: requer MongoDB 6.0+ (8.0 suportado)
# =====================================================================

ADMIN_PASS='@123Mudar'
SERVER_IP="192.168.100.2"
TIMEZONE="America/Fortaleza"

BASE_DIR="/srv"
GRAYLOG_DIR="${BASE_DIR}/graylog"
MONGO_DIR="${BASE_DIR}/mongodb"
OPENSEARCH_DIR="${BASE_DIR}/opensearch"

GRAYLOG_MAJOR="6"

# ─────────────────────────────────────────────────────────────────────
wait_service() {
  local name="$1" seconds="${2:-20}"
  echo "  -> Aguardando ${name} inicializar (${seconds}s)..."
  sleep "${seconds}"
}

check_service() {
  local name="$1" port="$2"
  if ss -tlnp | grep -q ":${port}"; then
    echo "  -> ${name} OK (porta ${port} em escuta)"
  else
    echo "  [AVISO] ${name} nao responde na porta ${port}."
    echo "  Verifique: journalctl -u ${name,,} -n 40 --no-pager"
  fi
}

# ─────────────────────────────────────────────────────────────────────
[[ "${EUID}" -ne 0 ]] && { echo "[ERRO] Execute como root."; exit 1; }

echo "================================================================"
echo " Graylog ${GRAYLOG_MAJOR}.x — Instalacao lab Debian 13 Trixie"
echo " MongoDB 8.0 + OpenSearch 2.x (sem Docker)"
echo "================================================================"

# ─────────────────────────────────────────────────────────────────────
echo "[1/12] Preparando sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  apt-transport-https pwgen wget python3 iproute2

# ─────────────────────────────────────────────────────────────────────
echo "[2/12] Ajustando timezone"
timedatectl set-timezone "${TIMEZONE}" || true

# ─────────────────────────────────────────────────────────────────────
echo "[3/12] Criando estrutura em /srv"
mkdir -p "${GRAYLOG_DIR}"/{etc,data,logs,journal}
mkdir -p "${MONGO_DIR}/data"
mkdir -p "${OPENSEARCH_DIR}/data"

# ─────────────────────────────────────────────────────────────────────
echo "[4/12] Instalando Java 17"
apt-get install -y openjdk-17-jre-headless || \
  apt-get install -y default-jre-headless
java -version 2>&1 | head -1

# ─────────────────────────────────────────────────────────────────────
# MONGODB 8.0 — repo nativo para Trixie, chave SHA-256
# Unica versao do MongoDB com suporte oficial ao Debian 13
# ─────────────────────────────────────────────────────────────────────
echo "[5/12] Instalando MongoDB 8.0"

# Remove qualquer repo MongoDB anterior (SHA-1 rejeitado no Trixie)
rm -f \
  /etc/apt/sources.list.d/mongodb-org-6.list \
  /etc/apt/sources.list.d/mongodb-org-7.list \
  /etc/apt/sources.list.d/mongodb-org-8.0.list \
  /usr/share/keyrings/mongodb-org-6.gpg \
  /usr/share/keyrings/mongodb-org-7.gpg \
  /usr/share/keyrings/mongodb-server-8.0.gpg \
  /etc/apt/trusted.gpg.d/mongodb-org-*.gpg 2>/dev/null || true

MONGO_GPG="/usr/share/keyrings/mongodb-server-8.0.gpg"
curl -fsSL https://pgp.mongodb.com/server-8.0.asc \
  | gpg --dearmor -o "${MONGO_GPG}"

# IMPORTANTE: bookworm — trixie nao existe nos dists do repo MongoDB
cat > /etc/apt/sources.list.d/mongodb-org-8.0.list <<EOF
deb [ arch=amd64,arm64 signed-by=${MONGO_GPG} ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main
EOF

apt-get update -qq
apt-get install -y mongodb-org

python3 - <<PYEOF
import re
conf = open("/etc/mongod.conf").read()
conf = re.sub(r'(\s+dbPath:\s*).*', r'\g<1>${MONGO_DIR}/data', conf)
open("/etc/mongod.conf", "w").write(conf)
print("  mongod.conf: dbPath -> ${MONGO_DIR}/data")
PYEOF

chown -R mongodb:mongodb "${MONGO_DIR}"
systemctl enable mongod
systemctl restart mongod
wait_service "MongoDB" 10
check_service "mongod" "27017""

# ─────────────────────────────────────────────────────────────────────
# OPENSEARCH 2.19.1 — instalação via tarball (sem apt, sem GPG)
# Tarball inclui JDK próprio — não depende do Java do sistema
# Segurança desabilitada (lab only)
# ─────────────────────────────────────────────────────────────────────
echo "[6/12] Instalando OpenSearch 2.19.1 via tarball"

OS_VERSION="2.19.1"
OS_TARBALL="opensearch-${OS_VERSION}-linux-x64.tar.gz"
OS_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/${OS_TARBALL}"
OS_INSTALL_DIR="/opt/opensearch"
OS_DATA_DIR="${OPENSEARCH_DIR}/data"
OS_LOG_DIR="/var/log/opensearch"

# Remove repo apt antigo se existir
rm -f /etc/apt/sources.list.d/opensearch-2.x.list \
      /usr/share/keyrings/opensearch.gpg 2>/dev/null || true

# Baixa tarball
echo "  -> Baixando OpenSearch ${OS_VERSION}..."
wget -qO "/tmp/${OS_TARBALL}" "${OS_URL}"

# Extrai para /opt/opensearch
rm -rf "${OS_INSTALL_DIR}"
mkdir -p "${OS_INSTALL_DIR}"
tar -xzf "/tmp/${OS_TARBALL}" -C "${OS_INSTALL_DIR}" --strip-components=1
rm -f "/tmp/${OS_TARBALL}"

# Cria usuário dedicado se não existir
if ! id opensearch &>/dev/null; then
  useradd -r -s /sbin/nologin -d "${OS_INSTALL_DIR}" opensearch
fi

# Cria diretórios de dados e logs
mkdir -p "${OS_DATA_DIR}" "${OS_LOG_DIR}"
chown -R opensearch:opensearch \
  "${OS_INSTALL_DIR}" \
  "${OS_DATA_DIR}" \
  "${OS_LOG_DIR}"

# Configura opensearch.yml
OPENSEARCH_YML="${OS_INSTALL_DIR}/config/opensearch.yml"

python3 - <<PYEOF
import re

yml = open("${OPENSEARCH_YML}").read()

settings = {
    r'#?\s*cluster\.name:.*':   'cluster.name: graylog',
    r'#?\s*node\.name:.*':      'node.name: node-1',
    r'#?\s*path\.data:.*':      'path.data: ${OS_DATA_DIR}',
    r'#?\s*path\.logs:.*':      'path.logs: ${OS_LOG_DIR}',
    r'#?\s*network\.host:.*':   'network.host: 127.0.0.1',
    r'#?\s*http\.port:.*':      'http.port: 9200',
    r'#?\s*discovery\.type:.*': 'discovery.type: single-node',
}

for pattern, replacement in settings.items():
    if re.search(pattern, yml, re.MULTILINE):
        yml = re.sub(pattern, replacement, yml, flags=re.MULTILINE)
    else:
        yml += f'\n{replacement}\n'

# Desabilita segurança — lab only
for key in ['plugins.security.disabled',
            'plugins.security.ssl.http.enabled',
            'plugins.security.ssl.transport.enforce_hostname_verification']:
    if key not in yml:
        yml += f'\n{key}: {"true" if "disabled" in key else "false"}\n'

open("${OPENSEARCH_YML}", "w").write(yml)
print("  opensearch.yml atualizado.")
PYEOF

# Cria unit systemd para o tarball (não vem com o pacote apt)
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
StandardError=inherit
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────
# GRAYLOG 6.x
# O .deb do repo usa lsb_release -sc = "trixie" que pode nao existir.
# Extraimos, corrigimos trixie->bookworm e copiamos manualmente.
# ─────────────────────────────────────────────────────────────────────
echo "[8/12] Instalando Graylog ${GRAYLOG_MAJOR}.x"

GRAYLOG_REPO_DEB="/tmp/graylog-repo.deb"
GRAYLOG_REPO_EXTRACT="/tmp/graylog-repo-extracted"

rm -rf "${GRAYLOG_REPO_EXTRACT}"
wget -qO "${GRAYLOG_REPO_DEB}" \
  "https://packages.graylog2.org/repo/packages/graylog-${GRAYLOG_MAJOR}.x-repository_latest.deb"

dpkg-deb -x "${GRAYLOG_REPO_DEB}" "${GRAYLOG_REPO_EXTRACT}/"

# Corrige "trixie" -> "bookworm" nos sources.list embutidos
find "${GRAYLOG_REPO_EXTRACT}" -name "*.list" \
  -exec sed -i 's/trixie/bookworm/g' {} \;

# Copia arquivos de repo para os lugares corretos
find "${GRAYLOG_REPO_EXTRACT}" -path "*/sources.list.d/*.list" \
  -exec cp -f {} /etc/apt/sources.list.d/ \; 2>/dev/null || true
find "${GRAYLOG_REPO_EXTRACT}" -path "*/keyrings/*.gpg" \
  -exec cp -f {} /usr/share/keyrings/ \; 2>/dev/null || true
find "${GRAYLOG_REPO_EXTRACT}" -path "*/trusted.gpg.d/*.gpg" \
  -exec cp -f {} /etc/apt/trusted.gpg.d/ \; 2>/dev/null || true

# Garante bookworm em qualquer sources.list do Graylog copiado
for f in /etc/apt/sources.list.d/graylog*.list; do
  [[ -f "${f}" ]] && sed -i 's/trixie/bookworm/g' "${f}"
done

apt-get update -qq
apt-get install -y graylog-server

# ─────────────────────────────────────────────────────────────────────
echo "[9/12] Configurando Graylog"
GRAYLOG_CONF="/etc/graylog/server/server.conf"

PASSWORD_SECRET="$(pwgen -N 1 -s 96)"
ROOT_SHA2="$(printf '%s' "${ADMIN_PASS}" | sha256sum | awk '{print $1}')"

# Seta chave=valor no server.conf (cobre comentadas e ausentes)
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

# Libera /srv via systemd override (mais seguro que symlink)
mkdir -p /etc/systemd/system/graylog-server.service.d
cat > /etc/systemd/system/graylog-server.service.d/override.conf <<EOF
[Service]
ReadWritePaths=${GRAYLOG_DIR}
EOF

chown -R graylog:graylog "${GRAYLOG_DIR}"

# ─────────────────────────────────────────────────────────────────────
echo "[10/12] Habilitando servicos"
systemctl daemon-reload
systemctl enable mongod opensearch graylog-server

# ─────────────────────────────────────────────────────────────────────
echo "[11/12] Reiniciando servicos na ordem correta"
systemctl restart mongod
wait_service "MongoDB (restart final)" 8

systemctl restart opensearch
wait_service "OpenSearch (restart final)" 40

systemctl restart graylog-server
wait_service "Graylog" 35

# ─────────────────────────────────────────────────────────────────────
echo "[12/12] Status dos servicos"
for svc in mongod opensearch graylog-server; do
  echo "--- ${svc} ---"
  systemctl --no-pager status "${svc}" --lines=5 || true
done

# Testa porta 9000 (Graylog API)
if curl -sf "http://127.0.0.1:9000/api" > /dev/null 2>&1; then
  echo "  -> Graylog API OK"
else
  echo "  [AVISO] Graylog ainda nao responde na porta 9000."
  echo "  Verifique: journalctl -u graylog-server -n 50 --no-pager"
fi

echo
echo "================================================================"
echo " Instalacao concluida — Graylog ${GRAYLOG_MAJOR}.x (sem Docker)"
echo
echo "  Interface  : http://${SERVER_IP}:9000"
echo "  Usuario    : admin"
echo "  Senha      : ${ADMIN_PASS}"
echo
echo "  Logs Graylog   : journalctl -u graylog-server -f"
echo "  Logs OpenSearch: journalctl -u opensearch -f"
echo "  Logs MongoDB   : journalctl -u mongod -f"
echo "  Config         : ${GRAYLOG_CONF}"
echo
echo "  ATENCAO: lab only. Altere a senha apos o primeiro login."
echo "================================================================"
