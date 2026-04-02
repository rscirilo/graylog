#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog4"
DOWNLOAD_DIR="${BASE_DIR}/downloads"

JAVA_DIR="${BASE_DIR}/java"
TEMURIN_CURRENT="${JAVA_DIR}/current"
TEMURIN_ARCHIVE="${DOWNLOAD_DIR}/temurin17-jre-linux-x64.tar.gz"
PROFILE_FILE_JAVA="/etc/profile.d/temurin17-graylog.sh"

OPENSSL11_DEB="libssl1.1_1.1.1w-0+deb11u5_amd64.deb"
OPENSSL11_URL="https://security.debian.org/debian-security/pool/updates/main/o/openssl/${OPENSSL11_DEB}"
OPENSSL11_FILE="${DOWNLOAD_DIR}/${OPENSSL11_DEB}"

MONGO_VERSION="4.4.29"
MONGO_PLATFORM="ubuntu2004"
MONGO_FILE="mongodb-linux-x86_64-${MONGO_PLATFORM}-${MONGO_VERSION}.tgz"
MONGO_URL="https://fastdl.mongodb.org/linux/${MONGO_FILE}"
MONGO_ARCHIVE="${DOWNLOAD_DIR}/${MONGO_FILE}"
MONGO_BASE_DIR="${BASE_DIR}/mongodb"
MONGO_HOME="${MONGO_BASE_DIR}/${MONGO_VERSION}"
MONGO_CURRENT="${MONGO_BASE_DIR}/current"
MONGO_DATA_DIR="${BASE_DIR}/data/mongodb"
MONGO_LOG_DIR="${BASE_DIR}/log/mongodb"
MONGO_RUN_DIR="${BASE_DIR}/run/mongodb"
MONGO_ETC_DIR="${BASE_DIR}/config/mongodb"
MONGO_LOG_FILE="${MONGO_LOG_DIR}/mongod.log"
MONGO_PID_FILE="${MONGO_RUN_DIR}/mongod.pid"
MONGO_CONF_FILE="${MONGO_ETC_DIR}/mongod.conf"
PROFILE_FILE_MONGO="/etc/profile.d/mongodb44-graylog.sh"
MONGO_SERVICE_FILE="/etc/systemd/system/mongod-graylog.service"

OPENSEARCH_VERSION="1.3.14"
OPENSEARCH_FILE="opensearch-${OPENSEARCH_VERSION}-linux-x64.tar.gz"
OPENSEARCH_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}/${OPENSEARCH_FILE}"
OPENSEARCH_ARCHIVE="${DOWNLOAD_DIR}/${OPENSEARCH_FILE}"
OPENSEARCH_BASE_DIR="${BASE_DIR}/opensearch"
OPENSEARCH_HOME="${OPENSEARCH_BASE_DIR}/${OPENSEARCH_VERSION}"
OPENSEARCH_CURRENT="${OPENSEARCH_BASE_DIR}/current"
OPENSEARCH_DATA_DIR="${BASE_DIR}/data/opensearch"
OPENSEARCH_LOG_DIR="${BASE_DIR}/log/opensearch"
OPENSEARCH_RUN_DIR="${BASE_DIR}/run/opensearch"
OPENSEARCH_TMP_DIR="${BASE_DIR}/tmp/opensearch"
OPENSEARCH_CONF_DIR="${OPENSEARCH_CURRENT}/config"
OPENSEARCH_YML="${OPENSEARCH_CONF_DIR}/opensearch.yml"
OPENSEARCH_JVM_DIR="${OPENSEARCH_CONF_DIR}/jvm.options.d"
OPENSEARCH_HEAP_FILE="${OPENSEARCH_JVM_DIR}/heap.options"
OPENSEARCH_SERVICE_FILE="/etc/systemd/system/opensearch-graylog.service"
OPENSEARCH_SYSCTL_FILE="/etc/sysctl.d/99-graylog-opensearch.conf"

GRAYLOG_REPO_DEB="graylog-4.3-repository_latest.deb"
GRAYLOG_REPO_URL="https://packages.graylog2.org/repo/packages/${GRAYLOG_REPO_DEB}"
GRAYLOG_REPO_FILE="${DOWNLOAD_DIR}/${GRAYLOG_REPO_DEB}"
GRAYLOG_CONF_DIR="/etc/graylog/server"
GRAYLOG_CONF_FILE="${GRAYLOG_CONF_DIR}/server.conf"
GRAYLOG_DATA_DIR="${BASE_DIR}/data/graylog"
GRAYLOG_JOURNAL_DIR="${GRAYLOG_DATA_DIR}/journal"
GRAYLOG_NODE_ID_FILE="${GRAYLOG_DATA_DIR}/node-id"
GRAYLOG_LOG_DIR="${BASE_DIR}/log/graylog"
GRAYLOG_PLUGIN_DIR="/usr/share/graylog-server/plugin"
GRAYLOG_BIND_ADDR="0.0.0.0:9000"
GRAYLOG_API_LOCAL="http://127.0.0.1:9000"
GRAYLOG_SERVICE_NAME="graylog-server"

LEGACY_MONGO_LIST="/etc/apt/sources.list.d/mongodb-org-4.4.list"
LEGACY_MONGO_KEYRING="/usr/share/keyrings/mongodb-server-4.4.gpg"

SERVER_IP=""
GRAYLOG_PASSWORD_SECRET=""
GRAYLOG_ADMIN_PASSWORD=""
GRAYLOG_ADMIN_PASSWORD_SHA2=""

log() {
  echo -e "[INFO] $*"
}

warn() {
  echo -e "[WARN] $*"
}

die() {
  echo -e "[ERRO] $*" >&2
  exit 1
}

precheck() {
  log "Iniciando pré-checagem do ambiente..."

  if [[ "${EUID}" -ne 0 ]]; then
    die "Execute este script como root."
  fi

  if [[ ! -f /etc/os-release ]]; then
    die "Arquivo /etc/os-release nao encontrado."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "debian" ]]; then
    die "Este script foi feito apenas para Debian."
  fi

  if [[ "${VERSION_ID:-}" != "13" && "${VERSION_CODENAME:-}" != "trixie" ]]; then
    die "Esperado Debian 13 (Trixie). Encontrado: ${PRETTY_NAME:-desconhecido}"
  fi

  if [[ ! -d /srv ]]; then
    die "Diretorio /srv nao encontrado."
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      log "Arquitetura x64 confirmada."
      ;;
    *)
      die "Este script foi preparado para Linux x64. Arquitetura atual: $(uname -m)"
      ;;
  esac

  if grep -qiE '(^|[[:space:]])avx([[:space:]]|$)' /proc/cpuinfo; then
    warn "AVX detectado. Este script ainda funciona, mas foi pensado para o cenario sem-AVX."
  else
    log "CPU sem AVX confirmada."
  fi

  mkdir -p "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java,mongodb,opensearch,run}
  chmod 755 "${BASE_DIR}" "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java,mongodb,opensearch,run}

  log "Sistema operacional confirmado: ${PRETTY_NAME:-Debian}"
  df -h /srv || true
  log "Pré-checagem concluída com sucesso."
}

cleanup_legacy_mongo_apt() {
  log "Removendo configuracao antiga do MongoDB via apt, se existir..."

  if [[ -f "${LEGACY_MONGO_LIST}" ]]; then
    rm -f "${LEGACY_MONGO_LIST}"
    log "Arquivo removido: ${LEGACY_MONGO_LIST}"
  fi

  if [[ -f "${LEGACY_MONGO_KEYRING}" ]]; then
    rm -f "${LEGACY_MONGO_KEYRING}"
    log "Arquivo removido: ${LEGACY_MONGO_KEYRING}"
  fi
}

install_base_packages() {
  log "Atualizando índice de pacotes..."
  apt-get update

  log "Instalando pré-requisitos básicos..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    wget \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https \
    procps \
    net-tools \
    python3 \
    tar \
    sed \
    coreutils \
    findutils \
    xz-utils \
    libcurl4 \
    liblzma5 \
    libc6 \
    libgcc-s1 \
    libstdc++6 \
    util-linux \
    openssl \
    pwgen \
    uuid-runtime

  log "Pré-requisitos instalados com sucesso."
}

detect_server_ip() {
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="127.0.0.1"
    warn "Nao foi possivel detectar IP principal. Usando ${SERVER_IP}."
  else
    log "IP principal detectado: ${SERVER_IP}"
  fi
}

install_temurin17() {
  log "Removendo metapacotes default-jre para evitar conflito de expectativa..."
  DEBIAN_FRONTEND=noninteractive apt-get remove -y default-jre default-jre-headless || true

  log "Consultando a API da Adoptium para descobrir o JRE 17 mais recente..."
  TEMURIN_URL="$(python3 - <<'PY'
import json, urllib.request
url = "https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&heap_size=normal&image_type=jre&jvm_impl=hotspot&os=linux&project=jdk&vendor=eclipse"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=60) as r:
    data = json.load(r)
print(data[0]["binary"]["package"]["link"])
PY
)"

  if [[ -z "${TEMURIN_URL}" ]]; then
    die "Nao foi possivel obter a URL do Temurin 17."
  fi

  log "Baixando Temurin 17 para ${TEMURIN_ARCHIVE}..."
  wget -O "${TEMURIN_ARCHIVE}" "${TEMURIN_URL}"

  log "Limpando instalacao anterior do Temurin em ${JAVA_DIR}..."
  find "${JAVA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true

  log "Extraindo Temurin 17..."
  tar -xzf "${TEMURIN_ARCHIVE}" -C "${JAVA_DIR}"

  EXTRACTED_DIR="$(tar -tzf "${TEMURIN_ARCHIVE}" | sed -n '1p' | cut -d/ -f1)"
  [[ -n "${EXTRACTED_DIR}" ]] || die "Nao foi possivel identificar o diretorio interno do arquivo tar.gz."

  ln -sfn "${JAVA_DIR}/${EXTRACTED_DIR}" "${TEMURIN_CURRENT}"

  if [[ ! -x "${TEMURIN_CURRENT}/bin/java" ]]; then
    die "Java do Temurin nao encontrado em ${TEMURIN_CURRENT}/bin/java"
  fi

  log "Criando profile JAVA_HOME em ${PROFILE_FILE_JAVA}..."
  cat > "${PROFILE_FILE_JAVA}" <<EOF
export JAVA_HOME="${TEMURIN_CURRENT}"
export PATH="${TEMURIN_CURRENT}/bin:\$PATH"
EOF
  chmod 644 "${PROFILE_FILE_JAVA}"

  log "Apontando /usr/local/bin/java para o Temurin 17..."
  mkdir -p /usr/local/bin
  ln -sfn "${TEMURIN_CURRENT}/bin/java" /usr/local/bin/java
  hash -r 2>/dev/null || true

  log "Verificando Java do Temurin..."
  "${TEMURIN_CURRENT}/bin/java" -version

  log "Verificando java padrao do shell..."
  /usr/local/bin/java -version

  log "Caminho final do java:"
  readlink -f /usr/local/bin/java || true
}

install_openssl11_compat() {
  log "Verificando compatibilidade OpenSSL 1.1 para MongoDB 4.4..."

  if ldconfig -p | grep -q 'libssl.so.1.1' && ldconfig -p | grep -q 'libcrypto.so.1.1'; then
    log "OpenSSL 1.1 ja esta presente no sistema."
    return 0
  fi

  log "Baixando ${OPENSSL11_DEB}..."
  wget -O "${OPENSSL11_FILE}" "${OPENSSL11_URL}"

  log "Instalando ${OPENSSL11_DEB}..."
  dpkg -i "${OPENSSL11_FILE}"

  log "Atualizando cache de bibliotecas..."
  ldconfig

  if ! ldconfig -p | grep -q 'libssl.so.1.1'; then
    die "libssl.so.1.1 nao foi registrada corretamente."
  fi

  if ! ldconfig -p | grep -q 'libcrypto.so.1.1'; then
    die "libcrypto.so.1.1 nao foi registrada corretamente."
  fi

  log "Compatibilidade OpenSSL 1.1 pronta."
}

install_mongodb44_tarball() {
  log "Preparando diretorios do MongoDB em /srv..."
  mkdir -p "${MONGO_BASE_DIR}" "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}" "${MONGO_RUN_DIR}" "${MONGO_ETC_DIR}"

  if ! id -u mongodb >/dev/null 2>&1; then
    log "Criando usuario de sistema mongodb..."
    useradd --system --home-dir "${MONGO_BASE_DIR}" --shell /usr/sbin/nologin mongodb
  fi

  log "Baixando MongoDB ${MONGO_VERSION} por tarball..."
  wget -O "${MONGO_ARCHIVE}" "${MONGO_URL}"

  log "Limpando instalacao anterior do MongoDB em ${MONGO_HOME}..."
  rm -rf "${MONGO_HOME}"
  mkdir -p "${MONGO_HOME}"

  log "Extraindo MongoDB em ${MONGO_HOME}..."
  tar -xzf "${MONGO_ARCHIVE}" -C "${MONGO_HOME}" --strip-components=1

  if [[ ! -x "${MONGO_HOME}/bin/mongod" ]]; then
    die "Binario mongod nao encontrado em ${MONGO_HOME}/bin/mongod"
  fi

  log "Criando link simbolico atual do MongoDB..."
  ln -sfn "${MONGO_HOME}" "${MONGO_CURRENT}"

  log "Criando profile PATH do MongoDB em ${PROFILE_FILE_MONGO}..."
  cat > "${PROFILE_FILE_MONGO}" <<EOF
export MONGODB_HOME="${MONGO_CURRENT}"
export PATH="${MONGO_CURRENT}/bin:\$PATH"
EOF
  chmod 644 "${PROFILE_FILE_MONGO}"

  log "Apontando /usr/local/bin/mongod e /usr/local/bin/mongo..."
  ln -sfn "${MONGO_CURRENT}/bin/mongod" /usr/local/bin/mongod
  if [[ -x "${MONGO_CURRENT}/bin/mongo" ]]; then
    ln -sfn "${MONGO_CURRENT}/bin/mongo" /usr/local/bin/mongo
  fi

  log "Ajustando permissoes dos diretorios do MongoDB..."
  chown -R mongodb:mongodb "${MONGO_BASE_DIR}" "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}" "${MONGO_RUN_DIR}" "${MONGO_ETC_DIR}"
  chmod 755 "${MONGO_BASE_DIR}" "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}" "${MONGO_RUN_DIR}" "${MONGO_ETC_DIR}"

  log "Gravando configuracao do mongod em ${MONGO_CONF_FILE}..."
  cat > "${MONGO_CONF_FILE}" <<EOF
storage:
  dbPath: ${MONGO_DATA_DIR}
  journal:
    enabled: true

systemLog:
  destination: file
  path: ${MONGO_LOG_FILE}
  logAppend: true

net:
  port: 27017
  bindIp: 127.0.0.1

processManagement:
  fork: false
  pidFilePath: ${MONGO_PID_FILE}
  timeZoneInfo: /usr/share/zoneinfo
EOF

  log "Criando service systemd ${MONGO_SERVICE_FILE}..."
  cat > "${MONGO_SERVICE_FILE}" <<EOF
[Unit]
Description=MongoDB 4.4 Graylog Tarball
After=network.target

[Service]
User=mongodb
Group=mongodb
Environment="HOME=${MONGO_BASE_DIR}"
ExecStart=${MONGO_CURRENT}/bin/mongod --config ${MONGO_CONF_FILE}
PIDFile=${MONGO_PID_FILE}
LimitNOFILE=64000
LimitNPROC=64000
TasksMax=infinity
TimeoutStartSec=120
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  log "Mostrando versao do mongod..."
  "${MONGO_CURRENT}/bin/mongod" --version | sed -n '1,12p' || true

  log "Checando bibliotecas do mongod..."
  ldd "${MONGO_CURRENT}/bin/mongod" | tee "${MONGO_LOG_DIR}/ldd-mongod.txt"

  if grep -q "not found" "${MONGO_LOG_DIR}/ldd-mongod.txt"; then
    die "O binario do MongoDB possui bibliotecas ausentes. Veja ${MONGO_LOG_DIR}/ldd-mongod.txt"
  fi

  log "Recarregando systemd..."
  systemctl daemon-reload

  log "Habilitando e iniciando mongod-graylog..."
  systemctl enable mongod-graylog
  systemctl restart mongod-graylog

  log "Validando status do mongod-graylog..."
  systemctl --no-pager --full status mongod-graylog | sed -n '1,20p' || true

  log "Validando se a porta 27017 esta em escuta..."
  ss -ltnp | grep 27017 || true

  log "MongoDB ${MONGO_VERSION} instalado por tarball em /srv."
}

configure_opensearch_kernel() {
  log "Aplicando ajuste de kernel para OpenSearch..."
  cat > "${OPENSEARCH_SYSCTL_FILE}" <<EOF
vm.max_map_count = 262144
EOF
  sysctl --system >/dev/null
  log "Kernel ajustado para OpenSearch."
}

install_opensearch13_tarball() {
  log "Preparando diretorios do OpenSearch em /srv..."
  mkdir -p "${OPENSEARCH_BASE_DIR}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_LOG_DIR}" "${OPENSEARCH_RUN_DIR}" "${OPENSEARCH_TMP_DIR}"

  if ! id -u opensearch >/dev/null 2>&1; then
    log "Criando usuario de sistema opensearch..."
    useradd --system --home-dir "${OPENSEARCH_BASE_DIR}" --shell /usr/sbin/nologin opensearch
  fi

  log "Baixando OpenSearch ${OPENSEARCH_VERSION} por tarball..."
  wget -O "${OPENSEARCH_ARCHIVE}" "${OPENSEARCH_URL}"

  log "Limpando instalacao anterior do OpenSearch em ${OPENSEARCH_HOME}..."
  rm -rf "${OPENSEARCH_HOME}"
  mkdir -p "${OPENSEARCH_HOME}"

  log "Extraindo OpenSearch em ${OPENSEARCH_HOME}..."
  tar -xzf "${OPENSEARCH_ARCHIVE}" -C "${OPENSEARCH_HOME}" --strip-components=1

  if [[ ! -x "${OPENSEARCH_HOME}/bin/opensearch" ]]; then
    die "Binario opensearch nao encontrado em ${OPENSEARCH_HOME}/bin/opensearch"
  fi

  log "Criando link simbolico atual do OpenSearch..."
  ln -sfn "${OPENSEARCH_HOME}" "${OPENSEARCH_CURRENT}"

  log "Criando override de heap do OpenSearch..."
  mkdir -p "${OPENSEARCH_JVM_DIR}"
  cat > "${OPENSEARCH_HEAP_FILE}" <<EOF
-Xms512m
-Xmx512m
EOF

  log "Gravando configuracao do OpenSearch em ${OPENSEARCH_YML}..."
  cat > "${OPENSEARCH_YML}" <<EOF
cluster.name: graylog
node.name: graylog-node-1
path.data: ${OPENSEARCH_DATA_DIR}
path.logs: ${OPENSEARCH_LOG_DIR}
network.host: 127.0.0.1
http.port: 9200
transport.host: 127.0.0.1
discovery.type: single-node
plugins.security.disabled: true
bootstrap.memory_lock: false
action.auto_create_index: false
EOF

  log "Ajustando permissoes do OpenSearch..."
  chown -R opensearch:opensearch "${OPENSEARCH_BASE_DIR}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_LOG_DIR}" "${OPENSEARCH_RUN_DIR}" "${OPENSEARCH_TMP_DIR}"
  chmod 755 "${OPENSEARCH_BASE_DIR}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_LOG_DIR}" "${OPENSEARCH_RUN_DIR}" "${OPENSEARCH_TMP_DIR}"

  log "Criando service systemd ${OPENSEARCH_SERVICE_FILE}..."
  cat > "${OPENSEARCH_SERVICE_FILE}" <<EOF
[Unit]
Description=OpenSearch 1.3 Graylog Tarball
After=network.target mongod-graylog.service
Wants=mongod-graylog.service

[Service]
Type=simple
User=opensearch
Group=opensearch
WorkingDirectory=${OPENSEARCH_CURRENT}
Environment=JAVA_HOME=${TEMURIN_CURRENT}
Environment=OPENSEARCH_JAVA_HOME=${TEMURIN_CURRENT}
Environment=OPENSEARCH_HOME=${OPENSEARCH_CURRENT}
Environment=OPENSEARCH_PATH_CONF=${OPENSEARCH_CONF_DIR}
Environment=OPENSEARCH_TMPDIR=${OPENSEARCH_TMP_DIR}
Environment=DISABLE_INSTALL_DEMO_CONFIG=true
Environment=DISABLE_SECURITY_PLUGIN=true
ExecStart=${OPENSEARCH_CURRENT}/bin/opensearch
LimitNOFILE=65535
LimitNPROC=4096
TimeoutStartSec=180
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  log "Mostrando versao do OpenSearch..."
  "${OPENSEARCH_CURRENT}/bin/opensearch" --version || true

  log "Recarregando systemd..."
  systemctl daemon-reload

  log "Habilitando e iniciando opensearch-graylog..."
  systemctl enable opensearch-graylog
  systemctl restart opensearch-graylog

  log "Aguardando OpenSearch responder na porta 9200..."
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:9200 >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! curl -fsS http://127.0.0.1:9200 >/dev/null 2>&1; then
    journalctl -u opensearch-graylog -n 60 --no-pager || true
    die "OpenSearch nao respondeu em http://127.0.0.1:9200"
  fi

  log "Validando status do opensearch-graylog..."
  systemctl --no-pager --full status opensearch-graylog | sed -n '1,25p' || true

  log "Validando se a porta 9200 esta em escuta..."
  ss -ltnp | grep 9200 || true

  log "Validando HTTP do OpenSearch..."
  curl -fsS http://127.0.0.1:9200 | sed -n '1,20p'

  log "OpenSearch ${OPENSEARCH_VERSION} instalado por tarball em /srv."
}

prepare_graylog_secrets() {
  log "Preparando segredos do Graylog..."

  GRAYLOG_PASSWORD_SECRET="${GRAYLOG_PASSWORD_SECRET:-$(openssl rand -hex 48)}"

  if [[ -n "${GRAYLOG_ADMIN_PASSWORD:-}" ]]; then
    log "Usando senha de admin recebida por variavel de ambiente GRAYLOG_ADMIN_PASSWORD."
  else
    GRAYLOG_ADMIN_PASSWORD="$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(20)))
PY
)"
    log "Senha de admin gerada automaticamente."
  fi

  GRAYLOG_ADMIN_PASSWORD_SHA2="$(printf '%s' "${GRAYLOG_ADMIN_PASSWORD}" | sha256sum | awk '{print $1}')"

  [[ -n "${GRAYLOG_PASSWORD_SECRET}" ]] || die "Falha ao gerar password_secret."
  [[ -n "${GRAYLOG_ADMIN_PASSWORD_SHA2}" ]] || die "Falha ao gerar root_password_sha2."
}

install_graylog43() {
  log "Baixando repositorio do Graylog 4.3..."
  wget -O "${GRAYLOG_REPO_FILE}" "${GRAYLOG_REPO_URL}"

  log "Instalando pacote de repositorio do Graylog..."
  dpkg -i "${GRAYLOG_REPO_FILE}"

  log "Atualizando índice de pacotes após adicionar repositório do Graylog..."
  apt-get update

  log "Instalando graylog-server e plugins de integracao..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y graylog-server graylog-integrations-plugins

  mkdir -p "${GRAYLOG_DATA_DIR}" "${GRAYLOG_JOURNAL_DIR}" "${GRAYLOG_LOG_DIR}"

  if id -u graylog >/dev/null 2>&1; then
    chown -R graylog:graylog "${GRAYLOG_DATA_DIR}" "${GRAYLOG_LOG_DIR}"
  fi

  if [[ -f "${GRAYLOG_CONF_FILE}" && ! -f "${GRAYLOG_CONF_FILE}.orig" ]]; then
    cp -a "${GRAYLOG_CONF_FILE}" "${GRAYLOG_CONF_FILE}.orig"
  fi

  prepare_graylog_secrets

  log "Gravando configuracao do Graylog em ${GRAYLOG_CONF_FILE}..."
  cat > "${GRAYLOG_CONF_FILE}" <<EOF
is_master = true
node_id_file = ${GRAYLOG_NODE_ID_FILE}
password_secret = ${GRAYLOG_PASSWORD_SECRET}
root_username = admin
root_password_sha2 = ${GRAYLOG_ADMIN_PASSWORD_SHA2}
root_timezone = America/Fortaleza
bin_dir = /usr/share/graylog-server/bin
data_dir = ${GRAYLOG_DATA_DIR}
plugin_dir = ${GRAYLOG_PLUGIN_DIR}
http_bind_address = ${GRAYLOG_BIND_ADDR}
http_publish_uri = http://${SERVER_IP}:9000/
http_external_uri = http://${SERVER_IP}:9000/
elasticsearch_hosts = http://127.0.0.1:9200
mongodb_uri = mongodb://127.0.0.1:27017/graylog
message_journal_dir = ${GRAYLOG_JOURNAL_DIR}
lb_recognition_period_seconds = 3
EOF

  if id -u graylog >/dev/null 2>&1; then
    touch "${GRAYLOG_NODE_ID_FILE}"
    chown -R graylog:graylog "${GRAYLOG_DATA_DIR}" "${GRAYLOG_LOG_DIR}"
    chmod 755 "${GRAYLOG_DATA_DIR}" "${GRAYLOG_JOURNAL_DIR}" "${GRAYLOG_LOG_DIR}"
  fi

  log "Recarregando systemd..."
  systemctl daemon-reload

  log "Habilitando e iniciando graylog-server..."
  systemctl enable "${GRAYLOG_SERVICE_NAME}"
  systemctl restart "${GRAYLOG_SERVICE_NAME}"

  log "Aguardando Graylog responder na porta 9000..."
  for i in $(seq 1 90); do
    if curl -fsS "${GRAYLOG_API_LOCAL}/api/system/lbstatus" >/dev/null 2>&1; then
      break
    fi
    if curl -fsS "${GRAYLOG_API_LOCAL}/" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  log "Validando status do graylog-server..."
  systemctl --no-pager --full status "${GRAYLOG_SERVICE_NAME}" | sed -n '1,25p' || true

  log "Validando se a porta 9000 esta em escuta..."
  ss -ltnp | grep 9000 || true

  log "Tentando validar HTTP do Graylog..."
  curl -fsS "${GRAYLOG_API_LOCAL}/api/system/lbstatus" || curl -I "${GRAYLOG_API_LOCAL}/" || true

  log "Credenciais iniciais do Graylog:"
  echo "URL    : http://${SERVER_IP}:9000/"
  echo "Usuario: admin"
  echo "Senha  : ${GRAYLOG_ADMIN_PASSWORD}"
}

main() {
  precheck
  detect_server_ip
  cleanup_legacy_mongo_apt
  install_base_packages
  install_temurin17
  install_openssl11_compat
  install_mongodb44_tarball
  configure_opensearch_kernel
  install_opensearch13_tarball
  install_graylog43
  log "Etapa do Graylog 4.3 concluída."
}

main "$@"
