#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog5"
DOWNLOAD_DIR="${BASE_DIR}/downloads"

JAVA_DIR="${BASE_DIR}/java"
TEMURIN_CURRENT="${JAVA_DIR}/current"
TEMURIN_ARCHIVE="${DOWNLOAD_DIR}/temurin17-jre-linux-x64.tar.gz"
PROFILE_FILE_JAVA="/etc/profile.d/temurin17-graylog5.sh"

MONGO_VERSION="6.0.8"
MONGO_PLATFORM="ubuntu2204"
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
PROFILE_FILE_MONGO="/etc/profile.d/mongodb60-graylog5.sh"
MONGO_SERVICE_FILE="/etc/systemd/system/mongod-graylog-avx.service"

OPENSEARCH_VERSION="2.5.0"
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
OPENSEARCH_SERVICE_FILE="/etc/systemd/system/opensearch-graylog-avx.service"
OPENSEARCH_SYSCTL_FILE="/etc/sysctl.d/99-graylog5-opensearch.conf"

GRAYLOG_VERSION="5.0.1"
GRAYLOG_FILE="graylog-${GRAYLOG_VERSION}.tgz"
GRAYLOG_URL="https://downloads.graylog.org/releases/graylog/${GRAYLOG_FILE}"
GRAYLOG_ARCHIVE="${DOWNLOAD_DIR}/${GRAYLOG_FILE}"
GRAYLOG_BASE_DIR="${BASE_DIR}/graylog"
GRAYLOG_HOME="${GRAYLOG_BASE_DIR}/${GRAYLOG_VERSION}"
GRAYLOG_CURRENT="${GRAYLOG_BASE_DIR}/current"
GRAYLOG_DATA_ROOT="${BASE_DIR}/data/graylog"
GRAYLOG_DATA_DIR="${GRAYLOG_DATA_ROOT}/data"
GRAYLOG_JOURNAL_DIR="${GRAYLOG_DATA_ROOT}/journal"
GRAYLOG_LOG_DIR="${BASE_DIR}/log/graylog"
GRAYLOG_NODE_ID_FILE="${GRAYLOG_DATA_ROOT}/node-id"
GRAYLOG_CONF_FILE="${GRAYLOG_HOME}/graylog.conf"
GRAYLOG_SERVICE_FILE="/etc/systemd/system/graylog-avx.service"
GRAYLOG_BIND_ADDR="0.0.0.0:9000"
GRAYLOG_HTTP_LOCAL="http://127.0.0.1:9000"
GRAYLOG_HTTP_EXTERNAL=""
GRAYLOG_PASSWORD_SECRET=""
GRAYLOG_ADMIN_PASSWORD=""
GRAYLOG_ADMIN_PASSWORD_SHA2=""
GRAYLOG_JAVA_OPTS="-Xms512m -Xmx512m"

SERVER_IP=""

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

  if ! grep -qiE '(^|[[:space:]])avx([[:space:]]|$)' /proc/cpuinfo; then
    die "CPU sem AVX detectada. Este script AVX exige suporte a AVX."
  fi

  log "CPU com AVX confirmada."

  mkdir -p "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java,mongodb,opensearch,graylog,run}
  chmod 755 "${BASE_DIR}" "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java,mongodb,opensearch,graylog,run}

  log "Pré-checagem concluída com sucesso."
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

  GRAYLOG_HTTP_EXTERNAL="http://${SERVER_IP}:9000/"
}

install_temurin17() {
  log "Removendo metapacotes default-jre para evitar conflito..."
  DEBIAN_FRONTEND=noninteractive apt-get remove -y default-jre default-jre-headless || true

  log "Consultando API da Adoptium para JRE 17..."
  TEMURIN_URL="$(python3 - <<'PY'
import json, urllib.request
url = "https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&heap_size=normal&image_type=jre&jvm_impl=hotspot&os=linux&project=jdk&vendor=eclipse"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=60) as r:
    data = json.load(r)
print(data[0]["binary"]["package"]["link"])
PY
)"

  [[ -n "${TEMURIN_URL}" ]] || die "Nao foi possivel obter a URL do Temurin 17."

  log "Baixando Temurin 17..."
  wget -O "${TEMURIN_ARCHIVE}" "${TEMURIN_URL}"

  log "Limpando instalacao anterior do Temurin..."
  find "${JAVA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true

  log "Extraindo Temurin 17..."
  tar -xzf "${TEMURIN_ARCHIVE}" -C "${JAVA_DIR}"

  EXTRACTED_DIR="$(tar -tzf "${TEMURIN_ARCHIVE}" | sed -n '1p' | cut -d/ -f1)"
  [[ -n "${EXTRACTED_DIR}" ]] || die "Nao foi possivel identificar o diretorio interno do tar.gz."

  ln -sfn "${JAVA_DIR}/${EXTRACTED_DIR}" "${TEMURIN_CURRENT}"

  [[ -x "${TEMURIN_CURRENT}/bin/java" ]] || die "Java nao encontrado em ${TEMURIN_CURRENT}/bin/java"

  cat > "${PROFILE_FILE_JAVA}" <<EOF
export JAVA_HOME="${TEMURIN_CURRENT}"
export PATH="${TEMURIN_CURRENT}/bin:\$PATH"
EOF
  chmod 644 "${PROFILE_FILE_JAVA}"

  mkdir -p /usr/local/bin
  ln -sfn "${TEMURIN_CURRENT}/bin/java" /usr/local/bin/java
  hash -r 2>/dev/null || true

  log "Validando Java..."
  "${TEMURIN_CURRENT}/bin/java" -version
}

install_mongodb60_tarball() {
  log "Preparando diretorios do MongoDB em /srv..."
  mkdir -p "${MONGO_BASE_DIR}" "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}" "${MONGO_RUN_DIR}" "${MONGO_ETC_DIR}"

  if ! id -u mongodb >/dev/null 2>&1; then
    log "Criando usuario mongodb..."
    useradd --system --home-dir "${MONGO_BASE_DIR}" --shell /usr/sbin/nologin mongodb
  fi

  log "Baixando MongoDB ${MONGO_VERSION} por tarball..."
  wget -O "${MONGO_ARCHIVE}" "${MONGO_URL}"

  log "Limpando instalacao anterior do MongoDB..."
  rm -rf "${MONGO_HOME}"
  mkdir -p "${MONGO_HOME}"

  log "Extraindo MongoDB..."
  tar -xzf "${MONGO_ARCHIVE}" -C "${MONGO_HOME}" --strip-components=1

  [[ -x "${MONGO_HOME}/bin/mongod" ]] || die "mongod nao encontrado em ${MONGO_HOME}/bin/mongod"

  ln -sfn "${MONGO_HOME}" "${MONGO_CURRENT}"

  cat > "${PROFILE_FILE_MONGO}" <<EOF
export MONGODB_HOME="${MONGO_CURRENT}"
export PATH="${MONGO_CURRENT}/bin:\$PATH"
EOF
  chmod 644 "${PROFILE_FILE_MONGO}"

  ln -sfn "${MONGO_CURRENT}/bin/mongod" /usr/local/bin/mongod
  if [[ -x "${MONGO_CURRENT}/bin/mongosh" ]]; then
    ln -sfn "${MONGO_CURRENT}/bin/mongosh" /usr/local/bin/mongosh
  fi

  chown -R mongodb:mongodb "${MONGO_BASE_DIR}" "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}" "${MONGO_RUN_DIR}" "${MONGO_ETC_DIR}"
  chmod 755 "${MONGO_BASE_DIR}" "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}" "${MONGO_RUN_DIR}" "${MONGO_ETC_DIR}"

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

  cat > "${MONGO_SERVICE_FILE}" <<EOF
[Unit]
Description=MongoDB 6.0 Graylog AVX Tarball
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

  systemctl daemon-reload
  systemctl enable mongod-graylog-avx
  systemctl restart mongod-graylog-avx

  log "Validando status do MongoDB..."
  systemctl --no-pager --full status mongod-graylog-avx | sed -n '1,20p' || true

  log "Validando porta 27017..."
  ss -ltnp | grep 27017 || true
}

configure_opensearch_kernel() {
  log "Aplicando ajuste de kernel para OpenSearch..."
  cat > "${OPENSEARCH_SYSCTL_FILE}" <<EOF
vm.max_map_count = 262144
EOF
  sysctl --system >/dev/null
}

install_opensearch25_tarball() {
  log "Preparando diretorios do OpenSearch..."
  mkdir -p "${OPENSEARCH_BASE_DIR}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_LOG_DIR}" "${OPENSEARCH_RUN_DIR}" "${OPENSEARCH_TMP_DIR}"

  if ! id -u opensearch >/dev/null 2>&1; then
    log "Criando usuario opensearch..."
    useradd --system --home-dir "${OPENSEARCH_BASE_DIR}" --shell /usr/sbin/nologin opensearch
  fi

  log "Baixando OpenSearch ${OPENSEARCH_VERSION} por tarball..."
  wget -O "${OPENSEARCH_ARCHIVE}" "${OPENSEARCH_URL}"

  log "Limpando instalacao anterior do OpenSearch..."
  rm -rf "${OPENSEARCH_HOME}"
  mkdir -p "${OPENSEARCH_HOME}"

  log "Extraindo OpenSearch..."
  tar -xzf "${OPENSEARCH_ARCHIVE}" -C "${OPENSEARCH_HOME}" --strip-components=1

  [[ -x "${OPENSEARCH_HOME}/bin/opensearch" ]] || die "opensearch nao encontrado em ${OPENSEARCH_HOME}/bin/opensearch"

  ln -sfn "${OPENSEARCH_HOME}" "${OPENSEARCH_CURRENT}"

  mkdir -p "${OPENSEARCH_JVM_DIR}"
  cat > "${OPENSEARCH_HEAP_FILE}" <<EOF
-Xms512m
-Xmx512m
EOF

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

  chown -R opensearch:opensearch "${OPENSEARCH_BASE_DIR}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_LOG_DIR}" "${OPENSEARCH_RUN_DIR}" "${OPENSEARCH_TMP_DIR}"
  chmod 755 "${OPENSEARCH_BASE_DIR}" "${OPENSEARCH_DATA_DIR}" "${OPENSEARCH_LOG_DIR}" "${OPENSEARCH_RUN_DIR}" "${OPENSEARCH_TMP_DIR}"

  cat > "${OPENSEARCH_SERVICE_FILE}" <<EOF
[Unit]
Description=OpenSearch 2.5 Graylog AVX Tarball
After=network.target mongod-graylog-avx.service
Wants=mongod-graylog-avx.service

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

  systemctl daemon-reload
  systemctl enable opensearch-graylog-avx
  systemctl restart opensearch-graylog-avx

  log "Aguardando OpenSearch responder..."
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:9200 >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! curl -fsS http://127.0.0.1:9200 >/dev/null 2>&1; then
    journalctl -u opensearch-graylog-avx -n 60 --no-pager || true
    die "OpenSearch nao respondeu em http://127.0.0.1:9200"
  fi

  log "Validando status do OpenSearch..."
  systemctl --no-pager --full status opensearch-graylog-avx | sed -n '1,25p' || true

  log "Validando porta 9200..."
  ss -ltnp | grep 9200 || true

  log "Validando HTTP do OpenSearch..."
  curl -fsS http://127.0.0.1:9200 | sed -n '1,20p'
}

prepare_graylog_secrets() {
  log "Preparando segredos do Graylog..."

  GRAYLOG_PASSWORD_SECRET="${GRAYLOG_PASSWORD_SECRET:-$(openssl rand -hex 48)}"

  if [[ -n "${GRAYLOG_ADMIN_PASSWORD:-}" ]]; then
    log "Usando senha enviada em GRAYLOG_ADMIN_PASSWORD."
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

install_graylog50_tarball() {
  log "Preparando diretorios do Graylog..."
  mkdir -p "${GRAYLOG_BASE_DIR}" "${GRAYLOG_DATA_ROOT}" "${GRAYLOG_DATA_DIR}" "${GRAYLOG_JOURNAL_DIR}" "${GRAYLOG_LOG_DIR}"

  if ! id -u graylog >/dev/null 2>&1; then
    log "Criando usuario graylog..."
    useradd --system --home-dir "${GRAYLOG_BASE_DIR}" --shell /usr/sbin/nologin graylog
  fi

  log "Baixando Graylog ${GRAYLOG_VERSION} por tarball..."
  wget -O "${GRAYLOG_ARCHIVE}" "${GRAYLOG_URL}"

  log "Limpando instalacao anterior do Graylog..."
  rm -rf "${GRAYLOG_HOME}"
  mkdir -p "${GRAYLOG_HOME}"

  log "Extraindo Graylog..."
  tar -xzf "${GRAYLOG_ARCHIVE}" -C "${GRAYLOG_HOME}" --strip-components=1

  [[ -f "${GRAYLOG_HOME}/graylog.jar" ]] || die "graylog.jar nao encontrado em ${GRAYLOG_HOME}"

  ln -sfn "${GRAYLOG_HOME}" "${GRAYLOG_CURRENT}"

  prepare_graylog_secrets

  cat > "${GRAYLOG_CONF_FILE}" <<EOF
is_master = true
node_id_file = ${GRAYLOG_NODE_ID_FILE}
password_secret = ${GRAYLOG_PASSWORD_SECRET}
root_username = admin
root_password_sha2 = ${GRAYLOG_ADMIN_PASSWORD_SHA2}
root_timezone = America/Fortaleza
bin_dir = ${GRAYLOG_CURRENT}/bin
data_dir = ${GRAYLOG_DATA_DIR}
plugin_dir = ${GRAYLOG_CURRENT}/plugin
http_bind_address = ${GRAYLOG_BIND_ADDR}
http_publish_uri = ${GRAYLOG_HTTP_EXTERNAL}
http_external_uri = ${GRAYLOG_HTTP_EXTERNAL}
elasticsearch_hosts = http://127.0.0.1:9200
mongodb_uri = mongodb://127.0.0.1:27017/graylog
message_journal_dir = ${GRAYLOG_JOURNAL_DIR}
lb_recognition_period_seconds = 3
EOF

  touch "${GRAYLOG_NODE_ID_FILE}"
  chown -R graylog:graylog "${GRAYLOG_BASE_DIR}" "${GRAYLOG_DATA_ROOT}" "${GRAYLOG_LOG_DIR}"
  chmod 755 "${GRAYLOG_BASE_DIR}" "${GRAYLOG_DATA_ROOT}" "${GRAYLOG_DATA_DIR}" "${GRAYLOG_JOURNAL_DIR}" "${GRAYLOG_LOG_DIR}"

  cat > "${GRAYLOG_SERVICE_FILE}" <<EOF
[Unit]
Description=Graylog 5.0 AVX Tarball
After=network.target mongod-graylog-avx.service opensearch-graylog-avx.service
Wants=mongod-graylog-avx.service opensearch-graylog-avx.service

[Service]
Type=simple
User=graylog
Group=graylog
WorkingDirectory=${GRAYLOG_CURRENT}
Environment=JAVA_HOME=${TEMURIN_CURRENT}
ExecStart=${TEMURIN_CURRENT}/bin/java ${GRAYLOG_JAVA_OPTS} -jar ${GRAYLOG_CURRENT}/graylog.jar server -f ${GRAYLOG_CONF_FILE}
SuccessExitStatus=143
LimitNOFILE=65536
TimeoutStartSec=180
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable graylog-avx
  systemctl restart graylog-avx

  log "Aguardando Graylog responder..."
  for i in $(seq 1 90); do
    if curl -fsS ${GRAYLOG_HTTP_LOCAL}/api/system/lbstatus >/dev/null 2>&1; then
      break
    fi
    if curl -fsS ${GRAYLOG_HTTP_LOCAL}/ >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  log "Validando status do Graylog..."
  systemctl --no-pager --full status graylog-avx | sed -n '1,25p' || true

  log "Validando porta 9000..."
  ss -ltnp | grep 9000 || true

  log "Tentando validar HTTP do Graylog..."
  curl -fsS ${GRAYLOG_HTTP_LOCAL}/api/system/lbstatus || curl -I ${GRAYLOG_HTTP_LOCAL}/ || true

  log "Credenciais iniciais do Graylog:"
  echo "URL    : ${GRAYLOG_HTTP_EXTERNAL}"
  echo "Usuario: admin"
  echo "Senha  : ${GRAYLOG_ADMIN_PASSWORD}"
}

main() {
  precheck
  detect_server_ip
  install_base_packages
  install_temurin17
  install_mongodb60_tarball
  configure_opensearch_kernel
  install_opensearch25_tarball
  install_graylog50_tarball
  log "Etapa AVX concluida."
}

main "$@"
