#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog4"
DOWNLOAD_DIR="${BASE_DIR}/downloads"
JAVA_DIR="${BASE_DIR}/java"
TEMURIN_CURRENT="${JAVA_DIR}/current"
TEMURIN_ARCHIVE="${DOWNLOAD_DIR}/temurin17-jre-linux-x64.tar.gz"
PROFILE_FILE="/etc/profile.d/temurin17-graylog.sh"

MONGO_KEYRING="/usr/share/keyrings/mongodb-server-4.4.gpg"
MONGO_LIST="/etc/apt/sources.list.d/mongodb-org-4.4.list"
MONGO_REPO="deb [ arch=amd64 signed-by=${MONGO_KEYRING} ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/4.4 main"

MONGO_DATA_DIR="${BASE_DIR}/data/mongodb"
MONGO_LOG_DIR="${BASE_DIR}/log/mongodb"
MONGO_LOG_FILE="${MONGO_LOG_DIR}/mongod.log"

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

  mkdir -p "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java}
  chmod 755 "${BASE_DIR}" "${BASE_DIR}"/{data,journal,log,tmp,config,downloads,java}

  log "Sistema operacional confirmado: ${PRETTY_NAME:-Debian}"
  df -h /srv || true
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
    findutils

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

  log "Criando profile JAVA_HOME em ${PROFILE_FILE}..."
  cat > "${PROFILE_FILE}" <<EOF
export JAVA_HOME="${TEMURIN_CURRENT}"
export PATH="${TEMURIN_CURRENT}/bin:\$PATH"
EOF
  chmod 644 "${PROFILE_FILE}"

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

install_mongodb44() {
  log "Preparando diretorios do MongoDB em /srv..."
  mkdir -p "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}"

  log "Instalando chave do repositório MongoDB 4.4..."
  curl -fsSL https://pgp.mongodb.com/server-4.4.asc | gpg --dearmor -o "${MONGO_KEYRING}"

  log "Criando lista do repositório MongoDB 4.4..."
  echo "${MONGO_REPO}" > "${MONGO_LIST}"

  log "Atualizando índice de pacotes com o repositório MongoDB..."
  apt-get update

  log "Instalando MongoDB 4.4..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org

  log "Ajustando permissoes dos diretorios do MongoDB..."
  chown -R mongodb:mongodb "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}"
  chmod 755 "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}"

  log "Gravando configuracao do mongod para usar /srv..."
  cat > /etc/mongod.conf <<EOF
storage:
  dbPath: ${MONGO_DATA_DIR}
  journal:
    enabled: true

systemLog:
  destination: file
  logAppend: true
  path: ${MONGO_LOG_FILE}

net:
  port: 27017
  bindIp: 127.0.0.1

processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF

  log "Recarregando systemd..."
  systemctl daemon-reload

  log "Habilitando e iniciando mongod..."
  systemctl enable mongod
  systemctl restart mongod

  log "Validando status do mongod..."
  systemctl --no-pager --full status mongod | sed -n '1,20p' || true

  log "Validando se a porta 27017 esta em escuta..."
  ss -ltnp | grep 27017 || true

  log "MongoDB 4.4 instalado e configurado em /srv."
}

main() {
  precheck
  install_base_packages
  install_temurin17
  install_mongodb44
  log "Etapa do MongoDB 4.4 concluída com sucesso."
  log "Ainda nao instalamos OpenSearch nem Graylog."
}

main "$@"
