#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog4"
DOWNLOAD_DIR="${BASE_DIR}/downloads"
JAVA_DIR="${BASE_DIR}/java"
TEMURIN_CURRENT="${JAVA_DIR}/current"
TEMURIN_ARCHIVE="${DOWNLOAD_DIR}/temurin17-jre-linux-x64.tar.gz"
TEMURIN_API="https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&heap_size=normal&image_type=jre&jvm_impl=hotspot&os=linux&project=jdk&vendor=eclipse"
PROFILE_FILE="/etc/profile.d/temurin17-graylog.sh"

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
    warn "AVX detectado. Este passo de Java continua valido, mas a VM nao e do perfil sem-AVX."
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

main() {
  precheck
  install_base_packages
  install_temurin17
  log "Etapa do Temurin 17 concluída com sucesso."
  log "Ainda nao instalamos MongoDB, OpenSearch nem Graylog."
}

main "$@"
