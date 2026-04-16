#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Script: install_graylog_compat.sh
# Objetivo: Instalar Graylog 5.x + MongoDB 7.x + OpenSearch 2.x
#           SEM Docker em Debian 13 (Trixie), dados em /srv
#           Senha padrão do admin: @123Mudar
#
# ATENÇÃO: Debian 13 (Trixie) não é suportado oficialmente pelos
#          repos do Graylog, MongoDB e OpenSearch. Usamos repos
#          bookworm (Debian 12) como workaround de lab.
#          MongoDB 7.0 — chave SHA-256, compatível com sqv/Trixie.
# =====================================================================

ADMIN_PASS='@123Mudar'
SERVER_IP="192.168.100.2"
TIMEZONE="America/Fortaleza"

BASE_DIR="/srv"
GRAYLOG_DIR="${BASE_DIR}/graylog"
MONGO_DIR="${BASE_DIR}/mongodb"
OPENSEARCH_DIR="${BASE_DIR}/opensearch"

GRAYLOG_MAJOR="5"

# ─────────────────────────────────────────────────────────────────────
wait_service() {
  local name="$1" seconds="${2:-20}"
  echo "  → Aguardando ${name} inicializar (${seconds}s)..."
  sleep "${seconds}"
}

# ─────────────────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERRO] Execute como root."
  exit 1
fi

echo "================================================================"
echo " Graylog ${GRAYLOG_MAJOR}.x — Instalação lab Debian 13 Trixie"
echo "================================================================"

# ─────────────────────────────────────────────────────────────────────
echo "[1/12] Preparando sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  apt-transport-https pwgen wget python3

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
# openjdk-11 não existe no Trixie; 17 é mínimo recomendado para Graylog 5+
apt-get install -y openjdk-17-jre-headless || \
  apt-get install -y default-jre-headless
java -version

# ─────────────────────────────────────────────────────────────────────
# MONGODB 7.0
# Chave SHA-256 — compatível com o verificador sqv do Debian 13 Trixie
# MongoDB 7.0 é suportado pelo Graylog 5.x e 6.x
# ─────────────────────────────────────────────────────────────────────
echo "[5/12] Instalando MongoDB 7.0"

# Remove repo 6.0 se existir (chave SHA-1 rejeitada pelo Trixie)
rm -f /etc/apt/sources.list.d/mongodb-org-6.list \
      /usr/share/keyrings/mongodb-org-6.gpg \
      /etc/apt/trusted.gpg.d/mongodb-org-6.gpg 2>/dev/null || true

MONGO_GPG="/usr/share/keyrings/mongodb-org-7.gpg"
if [[ ! -f "${MONGO_GPG}" ]]; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
    | gpg --dearmor -o "${MONGO_GPG}"
fi

cat > /etc/apt/sources.list.d/mongodb-org-7.list <<EOF
deb [ arch=amd64,arm64 signed-by=${MONGO_GPG} ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main
EOF

apt-get update -qq
apt-get install -y mongodb-org

# Ajusta dbPath via python3 (evita sed frágil no YAML indentado)
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

# Confirma que MongoDB está escutando
if mongosh --quiet --eval "db.adminCommand({ping:1})" > /dev/null 2>&1; then
  echo "  -> MongoDB OK"
else
  echo "  [AVISO] MongoDB nao respondeu ao ping."
  echo "  Verifique: journalctl -u mongod -n 30 --no-pager"
fi

# ─────────────────────────────────────────────────────────────────────
# OPENSEARCH 2.x
# Repo bookworm — Trixie não tem build oficial
# Segurança desabilitada (lab only)
# ─────────────────────────────────────────────────────────────────────
echo "[6/12] Instalando OpenSearch 2.x"

OS_GPG="/usr/share/keyrings/opensearch.gpg"
if [[ ! -f "${OS_GPG}" ]]; then
  curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp \
    | gpg --dearmor -o "${OS_GPG}"
fi

cat > /etc/apt/sources.list.d/opensearch-2.x.list <<EOF
deb [ signed-by=${OS_GPG} ] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main
EOF

apt-get update -qq
# Variável exigida pelo instalador do OpenSearch 2.12+ para aceitar EULA
OPENSEARCH_INITIAL_ADMIN_PASSWORD="@OpenSearch123!" \
  apt-get install -y opensearch

OPENSEARCH_YML="/etc/opensearch/opensearch.yml"

# Edição segura via python3 (evita problemas de sed com linhas comentadas)
python3 - <<PYEOF
import re

yml = open("${OPENSEARCH_YML}").read()

settings = {
    r'#?\s*cluster\.name:.*':   'cluster.name: graylog',
    r'#?\s*node\.name:.*':      'node.name: node-1',
    r'#?\s*path\.data:.*':      'path.data: ${OPENSEARCH_DIR}/data',
    r'#?\s*path\.logs:.*':      'path.logs: /var/log/opensearch',
    r'#?\s*network\.host:.*':   'network.host: 127.0.0.1',
    r'#?\s*http\.port:.*':      'http.port: 9200',
    r'#?\s*discovery\.type:.*': 'discovery.type: single-node',
}

for pattern, replacement in settings.items():
    if re.search(pattern, yml, re.MULTILINE):
        yml = re.sub(pattern, replacement, yml, flags=re.MULTILINE)
    else:
        yml += f'\n{replacement}'

# Segurança desabilitada (lab only — nunca em produção)
if 'plugins.security.disabled' not in yml:
    yml += '\nplugins.security.disabled: true\n'
else:
    yml = re.sub(
        r'plugins\.security\.disabled:.*',
        'plugins.security.disabled: true',
        yml
    )

open("${OPENSEARCH_YML}", "w").write(yml)
print("  opensearch.yml atualizado.")
PYEOF

chown -R opensearch:opensearch "${OPENSEARCH_DIR}"

# ─────────────────────────────────────────────────────────────────────
echo "[7/12] Ajustando kernel para OpenSearch"
cat > /etc/sysctl.d/99-opensearch.conf <<EOF
vm.max_map_count=262144
EOF
sysctl --system -q

systemctl enable opensearch
systemctl restart opensearch
wait_service "OpenSearch" 35

# Confirma porta 9200
if curl -sf http://127.0.0.1:9200 > /dev/null 2>&1; then
  echo "  -> OpenSearch OK (porta 9200 respondendo)"
else
  echo "  [AVISO] OpenSearch ainda nao responde na porta 9200."
  echo "  Verifique: journalctl -u opensearch -n 40 --no-pager"
fi

# ─────────────────────────────────────────────────────────────────────
# GRAYLOG 5.x
# O .deb do repo usa lsb_release -sc => "trixie" que nao existe.
# Extraimos o .deb, corrigimos trixie->bookworm nos sources.list
# embutidos e copiamos manualmente — sem dpkg -i direto.
# ─────────────────────────────────────────────────────────────────────
echo "[8/12] Instalando Graylog ${GRAYLOG_MAJOR}.x"

GRAYLOG_REPO_DEB="/tmp/graylog-repo.deb"
GRAYLOG_REPO_EXTRACT="/tmp/graylog-repo-extracted"

rm -rf "${GRAYLOG_REPO_EXTRACT}"
wget -qO "${GRAYLOG_REPO_DEB}" \
  "https://packages.graylog2.org/repo/packages/graylog-${GRAYLOG_MAJOR}.x-repository_latest.deb"

dpkg-deb -x "${GRAYLOG_REPO_DEB}" "${GRAYLOG_REPO_EXTRACT}/"

# Corrige "trixie" -> "bookworm" em todos os sources.list extraídos
find "${GRAYLOG_REPO_EXTRACT}" -name "*.list" \
  -exec sed -i 's/trixie/bookworm/g' {} \;

# Copia arquivos de repo para os lugares corretos
find "${GRAYLOG_REPO_EXTRACT}/etc/apt/sources.list.d/" \
     -name "*.list" -exec cp -f {} /etc/apt/sources.list.d/ \; 2>/dev/null || true

find "${GRAYLOG_REPO_EXTRACT}/usr/share/keyrings/" \
     -name "*.gpg" -exec cp -f {} /usr/share/keyrings/ \; 2>/dev/null || true

find "${GRAYLOG_REPO_EXTRACT}/etc/apt/trusted.gpg.d/" \
     -name "*.gpg" -exec cp -f {} /etc/apt/trusted.gpg.d/ \; 2>/dev/null || true

# Garante bookworm em qualquer sources.list do Graylog que foi copiado
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

# Seta chave=valor no server.conf (cobre linhas comentadas e ausentes)
set_conf() {
  local key="$1" value="$2"
  if grep -qE "^#?${key}\s*=" "${GRAYLOG_CONF}"; then
    sed -i "s|^#\?${key}\s*=.*|${key} = ${value}|" "${GRAYLOG_CONF}"
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

# ─────────────────────────────────────────────────────────────────────
# Libera /srv para o processo graylog via systemd override
# (mais seguro que symlink — evita conflito com ProtectPaths do unit)
# ─────────────────────────────────────────────────────────────────────
mkdir -p /etc/systemd/system/graylog-server.service.d
cat > /etc/systemd/system/graylog-server.service.d/override.conf <<EOF
[Service]
ReadWritePaths=${GRAYLOG_DIR}
EOF

chown -R graylog:graylog "${GRAYLOG_DIR}"

# ─────────────────────────────────────────────────────────────────────
echo "[10/12] Habilitando servicos no systemd"
systemctl daemon-reload
systemctl enable mongod opensearch graylog-server

# ─────────────────────────────────────────────────────────────────────
echo "[11/12] Reiniciando servicos"
systemctl restart mongod
wait_service "MongoDB (restart final)" 8

systemctl restart opensearch
wait_service "OpenSearch (restart final)" 35

systemctl restart graylog-server
wait_service "Graylog" 30

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

# ─────────────────────────────────────────────────────────────────────
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
echo "  Config Graylog : ${GRAYLOG_CONF}"
echo
echo "  ATENCAO: ambiente de lab. Altere a senha apos o primeiro login."
echo "================================================================"
