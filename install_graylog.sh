#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Script: install_graylog_compat.sh
# Objetivo: Instalar Graylog 5.x + MongoDB 6.x + OpenSearch 2.x
#           SEM Docker em Debian 13 (Trixie), dados em /srv
#           Senha padrão do admin: @123Mudar
#
# ATENÇÃO: Debian 13 (Trixie) não é suportado oficialmente pelos
#          repos do Graylog, MongoDB e OpenSearch. Usamos repos
#          bookworm (Debian 12) como workaround de lab.
# =====================================================================

ADMIN_PASS='@123Mudar'
SERVER_IP="192.168.100.2"
TIMEZONE="America/Fortaleza"

BASE_DIR="/srv"
GRAYLOG_DIR="${BASE_DIR}/graylog"
MONGO_DIR="${BASE_DIR}/mongodb"
OPENSEARCH_DIR="${BASE_DIR}/opensearch"

# Versão do Graylog a instalar (mude para 6 se quiser testar 6.x)
GRAYLOG_MAJOR="5"

# Aguarda N segundos com mensagem
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
  apt-transport-https pwgen wget

# ─────────────────────────────────────────────────────────────────────
echo "[2/12] Ajustando timezone"
timedatectl set-timezone "${TIMEZONE}" || true

# ─────────────────────────────────────────────────────────────────────
echo "[3/12] Criando estrutura em /srv"
mkdir -p "${GRAYLOG_DIR}"/{etc,data,logs,journal}
mkdir -p "${MONGO_DIR}/data"
mkdir -p "${OPENSEARCH_DIR}/data"

# ─────────────────────────────────────────────────────────────────────
echo "[4/12] Instalando Java (OpenJDK 17 — compatível com Graylog 5/6)"
# openjdk-11 não existe no Trixie; 17 é o mínimo recomendado para Graylog 5+
apt-get install -y openjdk-17-jre-headless || \
  apt-get install -y default-jre-headless
java -version

# ─────────────────────────────────────────────────────────────────────
# MONGODB 6.x — repo fixado em bookworm (Trixie não tem build oficial)
# ─────────────────────────────────────────────────────────────────────
echo "[5/12] Instalando MongoDB 6.x"

MONGO_GPG="/usr/share/keyrings/mongodb-org-6.gpg"
if [[ ! -f "${MONGO_GPG}" ]]; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc \
    | gpg --dearmor -o "${MONGO_GPG}"
fi

cat > /etc/apt/sources.list.d/mongodb-org-6.list <<EOF
deb [ arch=amd64,arm64 signed-by=${MONGO_GPG} ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/6.0 main
EOF

apt-get update -qq
apt-get install -y mongodb-org

# Ajusta dbPath no mongod.conf (YAML com indentação 2 espaços)
MONGOD_CONF="/etc/mongod.conf"
# Garante que path.data tem exatamente o formato esperado
python3 - <<PYEOF
import re, sys
with open("${MONGOD_CONF}", "r") as f:
    content = f.read()
# Substitui dbPath independente de espaçamento
content = re.sub(r'(\s+dbPath:\s*).*', r'\g<1>${MONGO_DIR}/data', content)
with open("${MONGOD_CONF}", "w") as f:
    f.write(content)
print("  mongod.conf: dbPath atualizado para ${MONGO_DIR}/data")
PYEOF

chown -R mongodb:mongodb "${MONGO_DIR}"
systemctl enable mongod
systemctl restart mongod
wait_service "MongoDB" 10

# ─────────────────────────────────────────────────────────────────────
# OPENSEARCH 2.x — repo bookworm (sem suporte oficial para Trixie)
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

# Variável necessária para aceitar a EULA automaticamente
OPENSEARCH_INITIAL_ADMIN_PASSWORD="@OpenSearch123!" \
  apt-get install -y opensearch 2>/dev/null || {
    echo "[AVISO] Repo apt do OpenSearch falhou. Tentando via tarball..."
    _install_opensearch_tarball
  }

OPENSEARCH_YML="/etc/opensearch/opensearch.yml"

# Usa python3 para edições seguras no YAML (evita sed frágil)
python3 - <<PYEOF
import re
yml = open("${OPENSEARCH_YML}").read()
replacements = {
    r'#?\s*cluster\.name:.*':     'cluster.name: graylog',
    r'#?\s*node\.name:.*':        'node.name: node-1',
    r'#?\s*path\.data:.*':        'path.data: ${OPENSEARCH_DIR}/data',
    r'#?\s*path\.logs:.*':        'path.logs: /var/log/opensearch',
    r'#?\s*network\.host:.*':     'network.host: 127.0.0.1',
    r'#?\s*http\.port:.*':        'http.port: 9200',
    r'#?\s*discovery\.type:.*':   'discovery.type: single-node',
}
for pattern, replacement in replacements.items():
    if re.search(pattern, yml, re.MULTILINE):
        yml = re.sub(pattern, replacement, yml, flags=re.MULTILINE)
    else:
        yml += f'\n{replacement}'
# Desabilita segurança (lab only)
if 'plugins.security.disabled' not in yml:
    yml += '\nplugins.security.disabled: true'
else:
    yml = re.sub(r'plugins\.security\.disabled:.*',
                 'plugins.security.disabled: true', yml)
open("${OPENSEARCH_YML}", "w").write(yml)
print("  opensearch.yml atualizado.")
PYEOF

chown -R opensearch:opensearch "${OPENSEARCH_DIR}"

echo "[7/12] Ajustando kernel para OpenSearch"
cat > /etc/sysctl.d/99-opensearch.conf <<EOF
vm.max_map_count=262144
EOF
sysctl --system -q

systemctl enable opensearch
systemctl restart opensearch
wait_service "OpenSearch" 30

# Confirma que OpenSearch está respondendo
if curl -sf http://127.0.0.1:9200 > /dev/null 2>&1; then
  echo "  → OpenSearch OK (porta 9200 respondendo)"
else
  echo "  [AVISO] OpenSearch ainda não responde na porta 9200."
  echo "  Verifique: journalctl -u opensearch -n 40"
fi

# ─────────────────────────────────────────────────────────────────────
# GRAYLOG
# ─────────────────────────────────────────────────────────────────────
echo "[8/12] Instalando Graylog ${GRAYLOG_MAJOR}.x"

# O .deb do repo usa $(lsb_release -sc) para montar a URL.
# No Trixie isso geraria "trixie" que não existe → forçamos bookworm.
GRAYLOG_REPO_URL="https://packages.graylog2.org/repo/packages/graylog-${GRAYLOG_MAJOR}.x-repository_latest.deb"
wget -qO /tmp/graylog-repo.deb "${GRAYLOG_REPO_URL}"

# Extrai o .deb, corrige a sources.list para bookworm antes de instalar
dpkg-deb -x /tmp/graylog-repo.deb /tmp/graylog-repo-extracted/
# Substitui trixie por bookworm dentro do sources.list embutido
find /tmp/graylog-repo-extracted/ -name "*.list" \
  -exec sed -i 's/trixie/bookworm/g' {} \;
find /tmp/graylog-repo-extracted/ -name "*.list" \
  -exec sed -i 's/$(lsb_release -sc)/bookworm/g' {} \; 2>/dev/null || true

# Copia os arquivos de repo manualmente (sem instalar o .deb)
cp -f /tmp/graylog-repo-extracted/etc/apt/sources.list.d/*.list \
      /etc/apt/sources.list.d/ 2>/dev/null || true
cp -f /tmp/graylog-repo-extracted/usr/share/keyrings/*.gpg \
      /usr/share/keyrings/ 2>/dev/null || true
cp -f /tmp/graylog-repo-extracted/etc/apt/trusted.gpg.d/*.gpg \
      /etc/apt/trusted.gpg.d/ 2>/dev/null || true

# Garante que o sources.list aponta para bookworm
for f in /etc/apt/sources.list.d/graylog*.list; do
  sed -i 's/trixie/bookworm/g' "${f}" 2>/dev/null || true
done

apt-get update -qq
apt-get install -y graylog-server

# ─────────────────────────────────────────────────────────────────────
echo "[9/12] Configurando Graylog"
GRAYLOG_CONF="/etc/graylog/server/server.conf"

PASSWORD_SECRET="$(pwgen -N 1 -s 96)"
ROOT_SHA2="$(printf '%s' "${ADMIN_PASS}" | sha256sum | awk '{print $1}')"

# Função auxiliar para setar chave=valor no server.conf
set_conf() {
  local key="$1" value="$2"
  if grep -qE "^#?${key}\s*=" "${GRAYLOG_CONF}"; then
    sed -i "s|^#\?${key}\s*=.*|${key} = ${value}|" "${GRAYLOG_CONF}"
  else
    echo "${key} = ${value}" >> "${GRAYLOG_CONF}"
  fi
}

set_conf "password_secret"       "${PASSWORD_SECRET}"
set_conf "root_password_sha2"    "${ROOT_SHA2}"
set_conf "http_bind_address"     "0.0.0.0:9000"
set_conf "http_publish_uri"      "http://${SERVER_IP}:9000/"
set_conf "elasticsearch_hosts"   "http://127.0.0.1:9200"

# Journal em /srv/graylog/journal
set_conf "message_journal_dir"   "${GRAYLOG_DIR}/journal"

# ─────────────────────────────────────────────────────────────────────
# Dados em /srv/graylog/data via override do systemd
# (mais seguro que symlink, evita problemas com ProtectPaths do unit)
# ─────────────────────────────────────────────────────────────────────
mkdir -p /etc/systemd/system/graylog-server.service.d
cat > /etc/systemd/system/graylog-server.service.d/override.conf <<EOF
[Service]
ReadWritePaths=${GRAYLOG_DIR}
EOF

chown -R graylog:graylog "${GRAYLOG_DIR}"

# ─────────────────────────────────────────────────────────────────────
echo "[10/12] Habilitando serviços"
systemctl daemon-reload
systemctl enable mongod opensearch graylog-server

# ─────────────────────────────────────────────────────────────────────
echo "[11/12] Reiniciando serviços"
systemctl restart mongod
wait_service "MongoDB (2ª reinicialização)" 8

systemctl restart opensearch
wait_service "OpenSearch (2ª reinicialização)" 35

systemctl restart graylog-server
wait_service "Graylog" 30

# ─────────────────────────────────────────────────────────────────────
echo "[12/12] Status dos serviços"
for svc in mongod opensearch graylog-server; do
  echo "--- ${svc} ---"
  systemctl --no-pager status "${svc}" --lines=5 || true
done

# Testa porta 9000
if curl -sf "http://127.0.0.1:9000/api" > /dev/null 2>&1; then
  echo "  → Graylog API OK"
else
  echo "  [AVISO] Graylog ainda não responde na porta 9000."
  echo "  Verifique: journalctl -u graylog-server -n 50 --no-pager"
fi

echo
echo "================================================================"
echo " Instalação concluída (Graylog ${GRAYLOG_MAJOR}.x, sem Docker)"
echo
echo "  Interface  : http://${SERVER_IP}:9000"
echo "  Usuário    : admin"
echo "  Senha      : ${ADMIN_PASS}"
echo
echo "  Logs:    journalctl -u graylog-server -f"
echo "  Config:  ${GRAYLOG_CONF}"
echo
echo "  ATENÇÃO: ambiente de lab. Altere a senha após o primeiro login."
echo "================================================================"
