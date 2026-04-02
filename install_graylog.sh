#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog4"

log() {
  echo -e "[INFO] $*"
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

  mkdir -p "${BASE_DIR}"/{data,journal,log,tmp,config,downloads}
  chmod 755 "${BASE_DIR}" "${BASE_DIR}"/{data,journal,log,tmp,config,downloads}

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
    net-tools

  log "Pré-requisitos instalados com sucesso."
}

install_java17() {
  log "Removendo default-jre para evitar ficar preso ao Java 21..."
  DEBIAN_FRONTEND=noninteractive apt-get remove -y default-jre default-jre-headless || true

  log "Instalando OpenJDK 17..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jre-headless

  if command -v update-alternatives >/dev/null 2>&1; then
    JAVA17_BIN="$(readlink -f /usr/bin/java || true)"
    log "Java atual apontando para: ${JAVA17_BIN}"
  fi

  log "Verificando Java instalado..."
  java -version || true
}

main() {
  precheck
  install_base_packages
  install_java17
  log "Etapa do Java 17 concluída."
  log "Ainda nao instalamos MongoDB, OpenSearch nem Graylog."
}

main "$@"
