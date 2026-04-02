#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/graylog4"

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

  if grep -qiE '(^|[[:space:]])avx([[:space:]]|$)' /proc/cpuinfo; then
    die "AVX detectado nesta VM. Use o script da versao COM AVX."
  fi

  if [[ ! -d /srv ]]; then
    die "Diretorio /srv nao encontrado."
  fi

  log "Sistema operacional confirmado: ${PRETTY_NAME:-Debian}"
  log "CPU sem AVX confirmada."
  log "Preparando estrutura base em ${BASE_DIR}..."

  mkdir -p "${BASE_DIR}"/{data,journal,log,tmp,config,downloads}
  chmod 755 "${BASE_DIR}"
  chmod 755 "${BASE_DIR}"/{data,journal,log,tmp,config,downloads}

  log "Estrutura criada com sucesso:"
  log " - ${BASE_DIR}/data"
  log " - ${BASE_DIR}/journal"
  log " - ${BASE_DIR}/log"
  log " - ${BASE_DIR}/tmp"
  log " - ${BASE_DIR}/config"
  log " - ${BASE_DIR}/downloads"

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
    lsb-release

  log "Pré-requisitos instalados com sucesso."
}

main() {
  precheck
  install_base_packages
  log "Etapa 2 concluída."
  log "Nenhum repositório do Graylog/MongoDB/OpenSearch foi adicionado ainda."
}

main "$@"
