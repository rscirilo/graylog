#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog4"
DOWNLOAD_DIR="${BASE_DIR}/downloads"

JAVA_DIR="${BASE_DIR}/java"
TEMURIN_CURRENT="${JAVA_DIR}/current"
TEMURIN_ARCHIVE="${DOWNLOAD_DIR}/temurin17-jre-linux-x64.tar.gz"
PROFILE_FILE_JAVA="/etc/profile.d/temurin17-graylog.sh"

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

LEGACY_MONGO_LIST="/etc/apt/sources.list.d/mongodb-org-4.4.list"
LEGACY_MONGO_KEYRING="/usr/share/keyrings/mongodb-server-4.4.gpg"

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

  mkdir -p "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java,mongodb,run}
  chmod 755 "${BASE_DIR}" "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java,mongodb,run}

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
    libstdc++6

  log "Pré-requisitos instalados com sucesso."
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
  "${MONGO_CURRENT}/bin/mongod" --version | sed -n '1,8p' || true

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

main() {
  precheck
  cleanup_legacy_mongo_apt
  install_base_packages
  install_temurin17
  install_mongodb44_tarball
  log "Etapa do MongoDB 4.4 por tarball concluída."
  log "Ainda nao instalamos OpenSearch nem Graylog."
}

main "$@"
