#!/usr/bin/env bash
set -euo pipefail

ZBX_SERVER="192.168.0.124"
ZBX_SERVER_PORT="10051"
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
  8) RHEL_VER="8" ;;
  9) RHEL_VER="9" ;;
  *)
    err "Versao Red Hat nao suportada pelo Zabbix ${ZBX_VERSION}: '${RHEL_RELEASE:-desconhecida}'. Suporte: RHEL/Rocky/Alma/CentOS 8 e 9"
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  err "Execute como root: sudo bash $0"
fi

echo "==> Verificando conectividade com a Zabbix Cloud..."
if ! timeout 5 bash -c ">/dev/tcp/${ZBX_SERVER}/${ZBX_SERVER_PORT}" 2>/dev/null; then
  warn "Nao foi possivel alcançar ${ZBX_SERVER}:${ZBX_SERVER_PORT} daqui. Verifique firewall de saida."
fi

echo "==> Instalando repositório Zabbix ${ZBX_VERSION} para EL${RHEL_VER}..."
RPM_URL="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/rhel/${RHEL_VER}/x86_64/zabbix-release-latest-${ZBX_VERSION}-1.el${RHEL_VER}.noarch.rpm"
if ! rpm -q zabbix-release >/dev/null 2>&1; then
  rpm -Uvh "$RPM_URL" || err "Falha ao baixar/instalar zabbix-release"
fi

echo "==> Instalando zabbix-proxy-sqlite3 e snmp tools..."
dnf install -y zabbix-proxy-sqlite3 net-snmp net-snmp-utils openssl

echo "==> Gerando/configurando PSK..."
if [ ! -s "$ZBX_PSK_FILE" ]; then
  mkdir -p /etc/zabbix
  openssl rand -hex 32 > "$ZBX_PSK_FILE"
fi
ZBX_PSK="$(cat "$ZBX_PSK_FILE")"
chown zabbix:zabbix "$ZBX_PSK_FILE"
chmod 640 "$ZBX_PSK_FILE"

echo "==> Ajustando SELinux se necessario..."
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  setsebool -P zabbix_can_network=1 2>/dev/null || true
fi

# Garantir diretório de logs padrão do zabbix
mkdir -p /var/log/zabbix
chown -R zabbix:zabbix /var/log/zabbix

echo "==> Escrevendo ${ZBX_CONF}..."
[ -f "$ZBX_CONF" ] && cp "$ZBX_CONF" "${ZBX_CONF}.bak.$(date +%s)"

cat > "$ZBX_CONF" <<EOF
Server=${ZBX_SERVER}:${ZBX_SERVER_PORT}
Hostname=${ZBX_HOSTNAME}
ProxyMode=0
PidFile=/run/zabbix/zabbix_proxy.pid
DBName=/var/lib/zabbix/zabbix_proxy.db
LogType=file
LogFile=/var/log/zabbix/zabbix_proxy.log
StartSNMPPollers=4
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=${ZBX_PSK_IDENTITY}
TLSPSKFile=${ZBX_PSK_FILE}
EOF

if [ "${RHEL_VER}" = "9" ]; then
  echo "==> Recarregando policies do SELinux..."
  restorecon -Rv /var/log/zabbix /var/lib/zabbix /etc/zabbix 2>/dev/null || true
fi

echo "==> Ajustando permissões do banco SQLite..."
mkdir -p /var/lib/zabbix
chown -R zabbix:zabbix /var/lib/zabbix

echo "==> Ajustando firewall (opcional, se firewalld ativo)..."
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=snmp 2>/dev/null || true
  firewall-cmd --permanent --add-port=10051/tcp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

echo "==> Iniciando serviço..."
systemctl daemon-reload
systemctl enable --now zabbix-proxy || err "Falha ao iniciar zabbix-proxy"
systemctl restart zabbix-proxy
sleep 3
systemctl is-active zabbix-proxy >/dev/null || err "zabbix-proxy nao esta ativo"

echo ""
printf "${GREEN}============================================================${NC}\n"
printf "${GREEN}  COPIE OS VALORES ABAIXO PARA A ZABBIX CLOUD GUI           ${NC}\n"
printf "${GREEN}============================================================${NC}\n"
echo "No frontend Cloud:  Administration -> Proxies -> Create proxy"
echo "  Proxy name          : ${ZBX_HOSTNAME}"
echo "  Proxy mode          : Active"
echo "  TLS encryption      : PSK"
echo "  PSK identity        : ${ZBX_PSK_IDENTITY}"
echo "  PSK key             : ${ZBX_PSK}"
echo ""
printf "${YELLOW}A PSK key e unica por hostname (arquivo: ${ZBX_PSK_FILE}). Cadastre-a na Cloud (devem ser identicas).${NC}\n"
echo ""
echo "Logs:  journalctl -u zabbix-proxy -f"
echo "Validar coleta SNMP:  snmpwalk -v2c -c <comunidade> <ip_router/sw> .1.3.6.1"