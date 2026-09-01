#!/usr/bin/env bash
set -euo pipefail

ZBX_HOSTNAME="aoking"
ZBX_PSK_IDENTITY="${ZBX_HOSTNAME}_psk"
ZBX_PSK_FILE="/etc/zabbix/zabbix_${ZBX_HOSTNAME}.psk"
ZBX_CONF="/etc/zabbix/zabbix_proxy.conf"
ZBX_VERSION="7.0"
RHEL_RELEASE="$(. /etc/os-release; echo "${VERSION_ID:-}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC} %s\n" "$*"; exit 1; }

case "${RHEL_RELEASE%%.*}" in
  8|9) : ;;
  *)
    err "Versao Red Hat nao suportada: '${RHEL_RELEASE:-desconhecida}'. Suporte: RHEL/Rocky/Alma/CentOS 8 e 9"
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  err "Execute como root: sudo bash $0"
fi

echo "==> Parando e desabilitando zabbix-proxy..."
systemctl disable --now zabbix-proxy 2>/dev/null || true

echo "==> Removendo pacotes do proxy..."
dnf remove -y zabbix-proxy-sqlite3 2>/dev/null || true

echo "==> Removendo config, PSK e banco do proxy..."
[ -f "$ZBX_CONF" ] && rm -f "$ZBX_CONF" && log "Removido ${ZBX_CONF}"
[ -f "$ZBX_PSK_FILE" ] && rm -f "$ZBX_PSK_FILE" && log "Removido ${ZBX_PSK_FILE}"
rm -f /var/lib/zabbix/zabbix_proxy.db
rm -rf /var/log/zabbix

case "${ZBX_HOSTNAME}" in
  *"*"*|*"?"*|*"["*)
    warn "Hostname tem caractere curinga - nao removendo o diretorio /var/lib/zabbix automaticamente"
    ;;
  *)
    [ -d /var/lib/zabbix ] && rm -rf "/var/lib/zabbix"
    ;;
esac

echo "==> Reaberto firewall (removendo regras liberadas pelo setup)..."
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --remove-service=snmp 2>/dev/null || true
  firewall-cmd --permanent --remove-port=10051/tcp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

echo ""
printf "${GREEN}============================================================${NC}\n"
printf "${GREEN}  PROXY REMOVIDO DA MAQUINA                          ${NC}\n"
printf "${GREEN}============================================================${NC}\n"
echo ""
printf "${YELLOW}ATENCAO - passo manual no servidor:${NC}\n"
echo "O proxy '${ZBX_HOSTNAME}' ainda existe no banco do Zabbix server." 
echo "Remova-o em:  Administration -> Proxies -> selecione '${ZBX_HOSTNAME}' -> Delete"
echo "Se houver hosts atribuidos a esse proxy, desatribua antes (Monitored by: no proxy)."
echo ""
echo "O pacote zabbix-release (repo) foi preservado: ele NAO atrapalha o Zabbix server."
echo "Para remove-lo tambem, depois:  dnf remove -y zabbix-release"
echo ""
echo "Se fez backup da config antes do setup, restaure com:"
echo "  ls /etc/zabbix/zabbix_proxy.conf.bak.*"