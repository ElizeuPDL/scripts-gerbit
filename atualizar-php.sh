#!/usr/bin/env bash
# Debian/Ubuntu: diagnóstico, preparação e atualização de PHP via APT.
# Leia --help. Não migra sites/pools nem valida compatibilidade das aplicações.
set -Eeuo pipefail
export LC_ALL=C
MODE=diagnose TARGET=latest ADD_REPO=0 CLI=0 ACK=0
usage() {
cat <<'HELP'
Uso: sudo bash atualizar-php.sh [opções]
  --diagnose             Inventário local (padrão; sem atualizar índices)
  --apply                Atualiza índices, simula e instala pacotes versionados
  --target latest|8.4    latest consulta a última versão estável no php.net
  --add-repo             Autoriza Sury (Debian) / ondrej/php (Ubuntu)
  --activate-cli         Altera /usr/bin/php via update-alternatives após instalar
  --backup-confirmed     Confirma snapshot/backup externo e compatibilidade revisada
  --help
Escopo: Debian 12/13 e Ubuntu 22.04/24.04/26.04, instalação APT nativa.
Não altera sites Apache/Nginx, pools, crons, containers ou painéis de hospedagem.
Instalar nova linha NÃO migra o PHP dos sites. APT pode reiniciar serviços.
Configurações são copiadas, não convertidas entre versões. Não há rollback automático.
HELP
}
die() { echo "ERRO: $*" >&2; exit 1; }
while (($#)); do
 case "$1" in
 --diagnose) MODE=diagnose;; --apply) MODE=apply;;
 --target) (($# >= 2)) || die 'Falta versão'; TARGET=$2; shift;;
 --add-repo) ADD_REPO=1;; --activate-cli) CLI=1;;
 --backup-confirmed) ACK=1;; --help|-h) usage; exit 0;;
 *) die "Opção desconhecida: $1";; esac; shift
done
[[ $TARGET == latest || $TARGET =~ ^[0-9]+\.[0-9]+$ ]] || die 'Versão inválida'
[[ -r /etc/os-release ]] || die 'Sistema sem os-release'
. /etc/os-release
printf 'Sistema: %s | arquitetura: %s\n' "$PRETTY_NAME" "$(uname -m)"
command -v php >/dev/null && { php -v; php --ini; php -m; } || true
case "$ID:${VERSION_ID:-}" in
 debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
 *) die 'Distribuição/versão não suportada. Nenhum pacote alterado.';;
esac
command -v apt-get >/dev/null || die 'APT ausente'
mapfile -t INSTALLED < <(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' | awk '$2=="installed" && ($1 ~ /^php/ || $1 ~ /^libapache2-mod-php/) {sub(/:.*/,"",$1); print $1}')
printf 'Pacotes PHP instalados:\n'; printf '%s\n' "${INSTALLED[@]}"
echo 'Repositórios ativos/configurados:'
# URLs podem conter credenciais: não imprime conteúdo dos arquivos.
find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print
apt-cache policy php php-cli
if command -v systemctl >/dev/null; then
 systemctl list-units --type=service --all --no-pager 'php*-fpm.service' 'apache2.service' 'nginx.service' || true
fi
[[ $MODE == apply ]] || { echo 'Diagnóstico concluído. --apply efetua alterações; consulte --help.'; exit 0; }
((EUID == 0)) || die 'Execute com sudo/root'
((ACK)) || die 'Confirme backup externo e revisão da aplicação com --backup-confirmed'
for panel in /usr/local/cpanel /usr/local/psa /usr/local/directadmin /www/server/panel; do
 [[ ! -e $panel ]] || die "Painel detectado: $panel. Utilize o gerenciador do painel."
done
((${#INSTALLED[@]})) || die 'Nenhum PHP APT encontrado; instalação manual/container exige outro procedimento'
command -v flock >/dev/null || die 'flock ausente'
exec 9>/run/lock/atualizar-php.lock
flock -n 9 || die 'Outra instância em execução'
umask 077
RUN=$(mktemp -d /var/backups/php-upgrade-XXXXXXXX)
exec > >(tee -a "$RUN/execution.log") 2>&1
trap 'echo "FALHA na linha $LINENO. Estado pode ter sido alterado. Consulte o backup/log em $RUN; não há rollback automático."' ERR
echo "Backup e log: $RUN"
dpkg-query -W > "$RUN/packages-before.txt"
apt-mark showhold > "$RUN/holds-before.txt"
update-alternatives --query php > "$RUN/alternatives-before.txt" 2>/dev/null || true
BACKUP_PATHS=(etc/apt)
for path in etc/php etc/apache2 etc/nginx; do [[ ! -e /$path ]] || BACKUP_PATHS+=("$path"); done
tar -C / -czf "$RUN/configuration.tar.gz" "${BACKUP_PATHS[@]}"
[[ -z $(dpkg --audit) ]] || die 'dpkg tem pendências; corrija antes'
[[ $(df -Pk / | awk 'NR==2{print $4}') -ge 1048576 ]] || die 'Exige pelo menos 1 GiB livre em /'
APT=(apt-get -o APT::Update::Error-Mode=any)
"${APT[@]}" update
"${APT[@]}" check
if ((ADD_REPO)); then
 "${APT[@]}" --no-remove -y install ca-certificates curl
 if [[ $ID == debian ]]; then
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
   https://packages.sury.org/debsuryorg-archive-keyring.deb -o "$RUN/keyring.deb"
  "${APT[@]}" --no-remove -y install "$RUN/keyring.deb"
  # Evita duplicar uma configuração Sury existente, mesmo em deb822.
  if ! grep -RqsE '^[[:space:]]*(deb .*|URIs:.*)https://packages\.sury\.org/php' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
   printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/php-upgrade-sury.list
  fi
 else
  "${APT[@]}" --no-remove -y install software-properties-common
  add-apt-repository -y ppa:ondrej/php
 fi
 "${APT[@]}" update
fi
if [[ $TARGET == latest ]]; then
 command -v curl >/dev/null || die 'Instale curl ou informe --target 8.5'
 command -v python3 >/dev/null || die 'Instale python3 ou informe --target 8.5'
 curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  'https://www.php.net/releases/index.php?json&version=8' -o "$RUN/releases.json"
 TARGET=$(python3 - "$RUN/releases.json" <<'PY'
import json,re,sys
v=json.load(open(sys.argv[1]))['version']
if not re.fullmatch(r'\d+\.\d+\.\d+', v):
    raise SystemExit('Resposta não contém uma versão estável')
print('.'.join(v.split('.')[:2]))
PY
 )
fi
echo "Linha de destino: $TARGET (última revisão disponível no APT)"
# Recusa downgrade de qualquer linha instalada.
for p in "${INSTALLED[@]}"; do
 if [[ $p =~ ^(php|libapache2-mod-php)([0-9]+\.[0-9]+) ]]; then
  dpkg --compare-versions "${BASH_REMATCH[2]}" le "$TARGET" || die "Linha instalada superior ao destino: $p"
 fi
done
PACKAGES=("php${TARGET}-cli" "php${TARGET}-common")
for p in "${INSTALLED[@]}"; do
 case "$p" in
 libapache2-mod-php*) die 'mod_php detectado. Migração Apache requer procedimento próprio; nenhum PHP foi instalado.';;
 php[0-9]*-*) suffix=${p#*-}; PACKAGES+=("php${TARGET}-${suffix}");;
 php-*) suffix=${p#php-}; case "$suffix" in pear|common) ;; *) PACKAGES+=("php${TARGET}-${suffix}");; esac;;
 esac
done
mapfile -t PACKAGES < <(printf '%s\n' "${PACKAGES[@]}" | sort -u)
for p in "${PACKAGES[@]}"; do
 candidate=$(apt-cache policy "$p" | awk '/Candidate:/{print $2}')
 [[ -n $candidate && $candidate != '(none)' ]] || die "Sem candidato para $p. Verifique repositório/extensão; não será ignorada."
 [[ $candidate != *'~'* ]] || die "Pré-release recusado: $p $candidate"
done
apt-cache policy "${PACKAGES[@]}" > "$RUN/candidates.txt"
# Bloqueia remoções; APT respeita holds e assinatura dos repositórios.
"${APT[@]}" -s --no-remove install "${PACKAGES[@]}" | tee "$RUN/plan.txt"
echo 'Instalando: pacotes podem iniciar/reiniciar serviços e alterar alternatives automáticas.'
DEBIAN_FRONTEND=noninteractive "${APT[@]}" -y --no-remove \
 -o Dpkg::Options::=--force-confold install "${PACKAGES[@]}"
"/usr/bin/php${TARGET}" -v
"/usr/bin/php${TARGET}" -m > "$RUN/modules-after.txt"
if [[ -x /usr/sbin/php-fpm${TARGET} ]]; then "/usr/sbin/php-fpm${TARGET}" -t; fi
if ((CLI)); then update-alternatives --set php "/usr/bin/php${TARGET}"; fi
"${APT[@]}" check
echo "Instalação validada. Backup/log: $RUN"
echo 'PENDENTE: migrar configurações/pools e sites, validar aplicação, crons/workers e tráfego HTTP.'
echo 'Versões anteriores foram mantidas. Não execute autoremove antes de homologar.'
