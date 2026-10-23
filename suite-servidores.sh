#!/usr/bin/env bash
# Suíte Gerbit v3.3: assistente interativo de manutenção.
set -Eeuo pipefail
export LC_ALL=C
# APT com índices isolados quando uma recuperação for necessária.
# Não desativa assinaturas, validade, certificados nem altera sources.list.
apt-get() {
 local -a options=()
 [[ -z ${GERBIT_APT_LISTS:-} ]] || options=(-o "Dir::State::lists=$GERBIT_APT_LISTS")
 command apt-get "${options[@]}" "$@"
}
apt-cache() {
 local -a options=()
 [[ -z ${GERBIT_APT_LISTS:-} ]] || options=(-o "Dir::State::lists=$GERBIT_APT_LISTS")
 command apt-cache "${options[@]}" "$@"
}
apt_refresh() {
 apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 \
  -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true \
  -o Acquire::PDiffs=false update
}
apt_recover_indexes() {
 local parent=/var/lib/apt
 echo 'Será feita nova coleta de índices, sem usar os índices locais anteriores.'
 echo 'Os repositórios e as verificações de segurança serão preservados.'
 sequence_confirm 'Tentar recuperar os índices APT agora?' || return 1
 [[ -d $parent && ! -L $parent ]] || return 1
 GERBIT_APT_LISTS=$(mktemp -d "$parent/gerbit-lists-XXXXXXXX")
 chmod 755 "$GERBIT_APT_LISTS"
 install -d -m 700 "$GERBIT_APT_LISTS/partial"
 echo "Índices desta execução: $GERBIT_APT_LISTS"
 apt_refresh
}
apt_run() {
 local log rc
 log=$(mktemp /var/tmp/gerbit-apt-error-XXXXXXXX.log)
 chmod 600 "$log"
 if apt-get "$@" 2>&1 | tee "$log"; then rm -f "$log"; return 0; else rc=$?; fi
 if grep -Eq '404|Failed to fetch|Unable to fetch some archives' "$log"; then
  echo "Falha de download do APT. Detalhes: $log"
  if apt_recover_indexes; then
   echo 'Índices recarregados. O APT calculará novamente os candidatos e o plano.'
   echo 'A nova tentativa será única; confira os pacotes antes de confirmar.'
   apt-get "$@"
   return $?
  fi
 fi
 echo 'Operação interrompida; não foram ignorados erros de repositório ou autenticação.'
 echo "Confira $log, data/hora, acesso à rede, proxy/cache e disponibilidade do repositório."
 echo 'Repositórios encerrados/arquivados exigem revisão; não são convertidos automaticamente.'
 return "$rc"
}
apt_eol_notice() {
 local os_id os_version
 os_id=$(. /etc/os-release; echo "$ID")
 os_version=$(. /etc/os-release; echo "$VERSION_ID")
 if [[ $os_id == debian && $os_version == 11 ]]; then
  echo 'ATENÇÃO: Debian11 encerrou LTS oficial em 31/08/2026.'
  echo 'Recuperar o APT não fornece novas correções de segurança para uma release encerrada.'
  echo 'PHP7.4 depende de fornecedor ELTS ou migração validada para uma release suportada.'
 fi
}

main() {
 local mode=${1:---diagnose}
 (($# == 0)) || shift
 if [[ $mode == --php ]]; then php_stage "$@"; return; fi
 local backup=0 console=0
 while (($#)); do
  case "$1" in
   --backup-confirmed) backup=1;; --console-confirmed) console=1;;
   *) echo "Opção desconhecida: $1" >&2; return 1;;
  esac
  shift
 done
 case "$mode" in
 --help|-h)
 cat <<'HELP'
Suíte de manutenção (APT nativo; execute com sudo):
 Sem argumentos: correção prioritária PHP2Shell nas linhas instaladas.
 --security   Auditoria e atualização das duas CVEs PHP2Shell de 21/10/2026
 --wizard     Abre o menu manual de ferramentas
 --sequence   Modernização de sistema e PHP com progresso salvo
 --diagnose   Inventário local; não atualiza índices nem instala nada
 --packages --backup-confirmed
              Atualiza pacotes da versão atual, com plano e confirmação interativa
 --distro --backup-confirmed --console-confirmed
              Ubuntu LTS: atualiza pacotes e abre do-release-upgrade interativo
              Uma LTS por execução; nunca força versão de desenvolvimento
 --php [opções do atualizar-php.sh]
              Etapa PHP integrada; use --php --help
 --help
Pacotes: Ubuntu 20.04/22.04/24.04/26.04; Debian 11/12/13.
Upgrade de distribuição: somente Ubuntu LTS. Debian exige plano por release.
Não atualiza aplicações, bancos via ferramentas próprias, containers ou firmware.
Não reinicia automaticamente nem retoma operações automaticamente após reboot.
Pergunta sobre backup externo ou prosseguimento sem ele; /etc não é backup dos dados.
HELP
 return;;
 --diagnose|--packages|--distro) ;;
 *) echo 'Modo desconhecido; use --help' >&2; return 1;;
 esac
 [[ -r /etc/os-release ]] || { echo 'os-release ausente'; return 1; }
 . /etc/os-release
 echo "Sistema: $PRETTY_NAME | arquitetura: $(uname -m)"
 uname -r
 df -h / /boot /var
 if command -v dpkg >/dev/null; then
  dpkg --audit
  apt-mark showhold
 fi
 if command -v systemctl >/dev/null; then
  systemctl --failed --no-pager || true
  systemctl list-units --type=service --state=running --no-pager || true
 fi
 command -v php >/dev/null && php -v || true
 [[ ! -e /run/reboot-required ]] || echo 'REINICIALIZAÇÃO PENDENTE'
 [[ $mode != --diagnose ]] || return 0
 ((EUID == 0)) || { echo 'Execute com sudo'; return 1; }
 ((backup)) || backup_question || return 10
 [[ -t 0 ]] || { echo 'Execute em terminal interativo, preferencialmente dentro de tmux/screen.'; return 1; }
 case "$ID:${VERSION_ID:-}" in
 ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:11|debian:12|debian:13) ;;
 *) echo 'Distribuição/versão sem fluxo validado. Bloqueado.'; return 1;;
 esac
 if [[ $mode == --distro ]]; then
  [[ $ID == ubuntu ]] || { echo 'Upgrade Debian: exige revisão das notas da release e dos repositórios. Bloqueado; --packages disponível.'; return 1; }
  ((console)) || { echo 'Confirme acesso ao console da VM/provedor com --console-confirmed'; return 1; }
  [[ ! -e /run/reboot-required ]] || { echo 'Reinicie e valide os serviços antes de trocar a distribuição.'; return 20; }
 fi
 local panel
 for panel in /usr/local/cpanel /usr/local/psa /usr/local/directadmin /www/server/panel /etc/pve /etc/proxmox-backup; do
  [[ ! -e $panel ]] || { echo "Ambiente com procedimento próprio: $panel. Bloqueado."; return 1; }
 done
 [[ -z $(dpkg --audit) ]] || { echo 'dpkg incompleto; corrija antes.'; return 1; }
 [[ -z $(apt-mark showhold) ]] || { echo 'Há pacotes retidos. Revise antes de prosseguir.'; return 1; }
 [[ $(df -Pk / | awk 'NR==2{print $4}') -ge 5242880 ]] || { echo 'Exige no mínimo 5 GiB livres em /; o upgrade pode exigir mais.'; return 1; }
 if command -v systemctl >/dev/null; then
  local health
  health=$(systemctl is-system-running 2>/dev/null || true)
  if [[ $health == degraded ]]; then
   systemctl --failed --no-pager
   echo 'Estes serviços já estão com falha. Isso não comprova que podem ser ignorados.'
   local decision
   read -r -p 'Digite ACEITAR FALHAS para prosseguir apesar delas, ou Enter para cancelar: ' decision
   [[ $decision == 'ACEITAR FALHAS' ]] || return 10
   echo 'DECISÃO: operador aceitou as falhas exibidas para esta execução.'
  elif [[ $health != running ]]; then
   echo "Estado systemd impeditivo: $health"; return 1
  fi
 fi
 exec 8>/run/lock/gerbit-suite.lock
 flock -n 8 || { echo 'Outra suíte está executando'; return 1; }
 umask 077
 local run
 run=$(mktemp -d /var/backups/gerbit-suite-XXXXXXXX)
 echo "Inventário e configurações: $run (contém dados sensíveis; acesso root)"
 exec > >(tee -a "$run/execution.log") 2>&1
 trap 'echo "Etapa falhou na linha $LINENO. Consulte /var/backups/gerbit-suite-* e /var/log/apt. Não há rollback automático."' ERR
 section 'ETAPA — Cópia local das configurações e inventário'
 tar -C / -czf "$run/etc.tar.gz" etc
 dpkg-query -W > "$run/packages-before.txt"
 apt-mark showmanual > "$run/manual-before.txt"
 lsblk -f > "$run/storage-before.txt"
 local -a apt=(apt-get -o APT::Update::Error-Mode=any)
 section 'ETAPA — Atualização dos índices dos repositórios'
 apt_refresh
 "${apt[@]}" check
 # Sem -y: o operador revisa remoções e responde perguntas de configuração.
 section 'ETAPA — Simulação da atualização de pacotes'
 "${apt[@]}" -s dist-upgrade | tee "$run/package-plan.txt"
 echo 'A operação pode substituir pacotes, remover dependências e reiniciar serviços.'
 local answer
 read -r -p 'Executar o plano? [s/N]: ' answer
 [[ $answer == s || $answer == S ]] || { echo 'Cancelado antes da atualização de pacotes.'; return 10; }
 section 'ETAPA — Execução da atualização de pacotes'
 apt_run dist-upgrade
 "${apt[@]}" check
 [[ -z $(dpkg --audit) ]] || { echo 'Há pendências dpkg após atualização'; return 1; }
 if [[ -e /run/reboot-required ]]; then
  echo 'Reinicie com sudo reboot, confira aplicações e execute a etapa novamente. PHP não será migrado agora.'
  return 20
 fi
 if [[ $mode == --packages ]]; then
  echo 'Pacotes atualizados. Valide serviços/aplicações; nenhuma aplicação foi homologada automaticamente.'
  return 0
 fi
 apt_run --no-remove install update-manager-core
 [[ ! -e /run/reboot-required ]] || { echo 'Reinicie antes do upgrade da distribuição'; return 20; }
 [[ -z $(apt list --upgradable 2>/dev/null | tail -n +2) ]] || { echo 'Ainda há pacotes atualizáveis, possivelmente faseados. Resolva antes do upgrade.'; return 1; }
 local cfg=/etc/update-manager/release-upgrades
 [[ -f $cfg ]] || { echo 'Configuração do release upgrader ausente'; return 1; }
 cp -a "$cfg" "$run/release-upgrades.before"
 if grep -qE '^[[:space:]]*Prompt=' "$cfg"; then
  sed -i -E 's/^[[:space:]]*Prompt=.*/Prompt=lts/' "$cfg"
 else
  printf '\nPrompt=lts\n' >> "$cfg"
 fi
 echo 'Abrindo o atualizador oficial para a próxima LTS disponível.'
 echo 'PPAs podem ser desativados. Não reative repositórios de releases antigas.'
 echo 'Responda às perguntas do atualizador. Não avance outra LTS sem validar aplicações.'
 section 'ETAPA — Atualizador da distribuição Ubuntu'
 do-release-upgrade
 echo 'Confira /var/log/dist-upgrade. Reinicie se solicitado; valide rede, SSH, bancos e aplicações.'
 echo 'A etapa PHP é separada: sudo bash suite-servidores.sh --php --diagnose'
}
php_stage() (
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
((ACK)) || { backup_question || exit 10; }
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
section 'ETAPA — Atualização dos índices APT para PHP'
apt_refresh
"${APT[@]}" check
if ((ADD_REPO)); then
 apt_run --no-remove -y install ca-certificates curl
 if [[ $ID == debian ]]; then
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
   https://packages.sury.org/debsuryorg-archive-keyring.deb -o "$RUN/keyring.deb"
  apt_run --no-remove -y install "$RUN/keyring.deb"
  # Evita duplicar uma configuração Sury existente, mesmo em deb822.
  if ! grep -RqsE '^[[:space:]]*(deb .*|URIs:.*)https://packages\.sury\.org/php' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
   printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/php-upgrade-sury.list
  fi
 else
  apt_run --no-remove -y install software-properties-common
  add-apt-repository -y ppa:ondrej/php
 fi
 section 'ETAPA — Atualização dos índices APT para PHP'
apt_refresh
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
 php[0-9]*-*) suffix=${p#*-}; if [[ $suffix == json ]] && dpkg --compare-versions "$TARGET" ge 8.0; then continue; fi; PACKAGES+=("php${TARGET}-${suffix}");;
 php-*) suffix=${p#php-}; case "$suffix" in pear|common) ;; *) PACKAGES+=("php${TARGET}-${suffix}");; esac;;
 esac
done
mapfile -t PACKAGES < <(printf '%s\n' "${PACKAGES[@]}" | sort -u)
for p in "${PACKAGES[@]}"; do
 candidate=$(apt-cache policy "$p" | awk '/Candidate:/{print $2}')
 [[ -n $candidate && $candidate != '(none)' ]] || die "Sem candidato para $p. Verifique repositório/extensão; não será ignorada."
 [[ ! $candidate =~ (alpha|beta|RC|rc)[0-9] ]] || die "Pré-release recusado: $p $candidate"
done
apt-cache policy "${PACKAGES[@]}" > "$RUN/candidates.txt"
# Bloqueia remoções; APT respeita holds e assinatura dos repositórios.
section 'ETAPA — Simulação da instalação do PHP'
"${APT[@]}" -s --no-remove install "${PACKAGES[@]}" | tee "$RUN/plan.txt"
section 'ETAPA — Instalação dos pacotes PHP'
echo 'Instalando: pacotes podem iniciar/reiniciar serviços e alterar alternatives automáticas.'
DEBIAN_FRONTEND=noninteractive apt_run -y --no-remove \
 -o Dpkg::Options::=--force-confold install "${PACKAGES[@]}"
"/usr/bin/php${TARGET}" -v
"/usr/bin/php${TARGET}" -m > "$RUN/modules-after.txt"
if [[ -x /usr/sbin/php-fpm${TARGET} ]]; then "/usr/sbin/php-fpm${TARGET}" -t; fi
if ((CLI)); then update-alternatives --set php "/usr/bin/php${TARGET}"; fi
"${APT[@]}" check
echo "Instalação validada. Backup/log: $RUN"
echo 'PENDENTE: migrar configurações/pools e sites, validar aplicação, crons/workers e tráfego HTTP.'
echo 'Versões anteriores foram mantidas. Não execute autoremove antes de homologar.'

)

backup_question() {
 local answer
 section 'DECISÃO — Backup externo ou snapshot'
 echo 'Backup externo/snapshot deste servidor:'
 echo '  1) Tenho backup recuperável e revisei o impacto nas aplicações'
 echo '  2) Prosseguir SEM backup externo (somente cópia local de configurações)'
 echo '  0) Cancelar [padrão]'
 read -r -p 'Escolha: ' answer
 case "$answer" in
  1) echo 'DECISÃO: operador declarou backup externo disponível.'; return 0;;
  2)
   echo 'A cópia de /etc não recupera bancos, arquivos, boot ou a VM inteira.'
   read -r -p 'Digite SEM BACKUP para assumir essa decisão: ' answer
   [[ $answer == 'SEM BACKUP' ]] || return 1
   echo 'DECISÃO: operador autorizou prosseguir sem backup externo.'; return 0;;
  *) echo 'Etapa cancelada.'; return 1;;
 esac
}
section() {
 printf '\n\n────────────────────────────────────────────────────────────\n'
 printf '  %s\n' "$1"
 printf '────────────────────────────────────────────────────────────\n\n'
}
screen_header() {
 # Limpa apenas o terminal; preserva o histórico textual no log.
 if [[ -t 0 && ${TERM:-dumb} != dumb && -w /dev/tty ]]; then
  printf '\033[2J\033[H' > /dev/tty
 fi
 printf '\nGERBIT — ASSISTENTE DE MANUTENÇÃO v3.3\n%s\n\n' "$1"
}
pause_screen() {
 local pause_answer
 printf '\n'
 read -r -p 'Pressione Enter para voltar ao menu...' pause_answer || return 0
}
interactive_wizard() {
 ((EUID == 0)) || { echo 'Execute: sudo bash suite-servidores.sh'; return 1; }
 [[ -t 0 ]] || { echo 'O assistente requer um terminal interativo'; return 1; }
 local self choice rc target answer action_title started last_action='Nenhuma ação executada nesta sessão.'
 self=$(readlink -f "${BASH_SOURCE[0]}")
 umask 077
 local session
 session=$(mktemp /var/log/gerbit-assistente-XXXXXXXX.log)
 exec > >(tee -a "$session") 2>&1
 echo 'GERBIT — ASSISTENTE DE MANUTENÇÃO v3.3'
 echo "Log da sessão: $session"
 echo 'Cada ação pede confirmação. Enter mantém a opção de cancelar/não.'
 echo 'Depois de um reboot, execute este mesmo arquivo novamente.'
 echo 'Aplicações e bancos exigem revisão de compatibilidade; não há rollback automático.'
 while true; do
  screen_header 'Menu principal — escolha uma opção'
  printf 'Última ação: %s\nLog: %s\n\n' "$last_action" "$session"
  printf '%s\n' \
   '1) Diagnóstico geral e versões dos sistemas' \
   '2) Atualizar pacotes da distribuição atual' \
   '3) Atualizar Ubuntu para a próxima LTS (interativo)' \
   '4) Diagnosticar PHP' \
   '5) Instalar/atualizar PHP e extensões' \
   '6) Investigar serviços com falha e obter orientações' \
   '7) Verificar pendências do APT/dpkg e oferecer correções' \
   '8) Reiniciar o servidor' \
   '9) Sequência guiada — sistema e PHP' \
   '0) Sair [padrão]'
  read -r -p 'Escolha: ' choice || break
  echo "DECISÃO: opção ${choice:-0}"
  rc=0
  case "$choice" in
   1) action_title='Diagnóstico geral';;
   2) action_title='Atualização dos pacotes';;
   3) action_title='Atualização da distribuição Ubuntu';;
   4) action_title='Diagnóstico do PHP';;
   5) action_title='Atualização do PHP';;
   6) action_title='Investigação dos serviços';;
   7) action_title='Verificação e correção do APT';;
   8) action_title='Reinicialização do servidor';;
   9) action_title='Sequência guiada';;
   0|'') echo "Encerrado. Log: $session"; return 0;;
   *) echo 'Opção inválida'; pause_screen; continue;;
  esac
  screen_header "$action_title"
  started=$(date '+%H:%M:%S')
  section "INÍCIO DA AÇÃO $choice — $action_title — $started"
  case "$choice" in
   1)
    if bash "$self" --diagnose; then :; else rc=$?; fi
    if command -v dpkg-query >/dev/null; then
     dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\t${Version}\n' \
      'unifi*' 'zabbix*' 'mariadb*' 'mysql*' 'grafana*' 'mongodb*' 'php*' 2>/dev/null | awk '$1=="installed"' || true
    fi;;
   2) if bash "$self" --packages; then :; else rc=$?; fi;;
   3)
    echo 'A troca da distribuição pode mudar PHP/bancos e desativar repositórios terceiros.'
    echo 'Verifique as aplicações instaladas. A suíte não certifica a compatibilidade delas.'
    read -r -p 'Revisou a compatibilidade e tem acesso ao console da VM/provedor? [s/N]: ' answer
    if [[ $answer == s || $answer == S ]]; then
     if bash "$self" --distro --console-confirmed; then :; else rc=$?; fi
    fi;;
   4) if bash "$self" --php --diagnose; then :; else rc=$?; fi;;
   5)
    echo 'Instala os pacotes de PHP. Sites/pools, crons e workers não são migrados automaticamente.'
    echo 'Confirme a compatibilidade da aplicação antes de escolher uma nova linha.'
    read -r -p 'Linha PHP (ex.: 8.4; Enter = latest estável do php.net): ' target
    target=${target:-latest}
    local -a flags=(--php --apply --target "$target")
    read -r -p 'Autorizar repositório Sury/ondrej, de terceiros? [s/N]: ' answer
    [[ $answer != s && $answer != S ]] || flags+=(--add-repo)
    read -r -p 'Ativar também como PHP padrão do terminal? [s/N]: ' answer
    [[ $answer != s && $answer != S ]] || flags+=(--activate-cli)
    if bash "$self" "${flags[@]}"; then :; else rc=$?; fi;;
   6)
    systemctl --failed --no-pager || true
    local -a failed=()
    mapfile -t failed < <(systemctl --failed --no-legend --plain --type=service | awk '{print $1}')
    local unit
    for unit in "${failed[@]}"; do
     [[ $unit =~ ^[a-zA-Z0-9_.@:-]+\.service$ ]] || continue
     systemctl status "$unit" --no-pager -l || true
     journalctl -u "$unit" -n 25 --no-pager || true
    done
    echo 'Orientações: logrotate + Access denied no MariaDB exige corrigir a credencial usada no postrotate.'
    echo 'Não redefina root automaticamente; fwupd deve ser testado pelo próprio serviço.'
    echo 'A atualização de pacotes permite aceitar explicitamente falhas preexistentes.'
    echo 'Não apagamos o estado de falha nem desativamos serviços para mascarar problemas.';;
   7)
    if bash "$self" --repair; then :; else rc=$?; fi;;
   8)
    read -r -p 'Reiniciar agora? A sessão será encerrada. [s/N]: ' answer
    if [[ $answer == s || $answer == S ]]; then
     echo 'DECISÃO: reinicialização autorizada. Reabra a suíte após conectar novamente.'
     systemctl reboot
     return
    fi;;
   9) if bash "$self" --sequence; then :; else rc=$?; fi;;
   0|'') echo "Encerrado. Log: $session"; return 0;;
   *) echo 'Opção inválida';;
  esac
  section "FIM DA AÇÃO $choice — $action_title — $(date '+%H:%M:%S')"
  if ((rc == 10)); then
   last_action="$action_title — cancelada pelo operador"
   echo 'Etapa cancelada.'
  elif ((rc == 20)); then
   last_action="$action_title — requer reinicialização"
   echo 'Etapa interrompida: reboot necessário. Use a opção 8 quando estiver pronto.'
  elif ((rc != 0)); then
   last_action="$action_title — interrompida (código $rc)"
   echo "Etapa interrompida (código $rc). Consulte o erro acima e o log; nenhuma correção foi presumida."
  else
   last_action="$action_title — encerrada sem erro reportado"
   echo 'Etapa encerrada. Confira as mensagens acima: cancelamentos também podem retornar sem erro.'
  fi
  printf '\nResumo: %s\nLog completo: %s\n' "$last_action" "$session"
  pause_screen
 done
}
repair_stage() {
 ((EUID == 0)) || return 1
 [[ -t 0 ]] || return 1
 command -v apt-get >/dev/null || return 1
 echo 'Pendências dpkg:'
 dpkg --audit
 echo 'Pacotes retidos (não serão liberados automaticamente):'
 apt-mark showhold
 apt-get check || true
 local answer
 echo 'Opções: 1) Configurar pacotes pendentes; 2) Simular e oferecer correção de dependências; Enter) cancelar'
 read -r -p 'Escolha: ' answer
 case "$answer" in
  1)
   backup_question || return 0
   echo 'dpkg pode executar scripts dos pacotes e reiniciar serviços.'
   read -r -p 'Executar dpkg --configure -a? [s/N]: ' answer
   [[ $answer != s && $answer != S ]] || dpkg --configure -a;;
  2)
   apt-get -s --fix-broken install
   backup_question || return 0
   read -r -p 'Executar correção de dependências? [s/N]: ' answer
   [[ $answer != s && $answer != S ]] || apt-get --fix-broken install;;
 esac
}
sequence_confirm() {
 local reply
 printf '\n'
 read -r -p "$1 [s/N]: " reply || return 1
 [[ $reply == s || $reply == S ]]
}
sequence_save() {
 # Arquivo de dados, nunca executado com source/eval.
 local tmp
 tmp=$(mktemp "$SEQ_DIR/state-XXXXXXXX")
 printf '%s\n' "$SEQ_PHP" "$SEQ_OS" "$SEQ_PHASE" "$SEQ_BOOT" > "$tmp"
 chmod 600 "$tmp"
 mv -f "$tmp" "$SEQ_DIR/progress"
}
sequence_reboot() {
 SEQ_BOOT=$(cat /proc/sys/kernel/random/boot_id)
 sequence_save
 section 'REINICIALIZAÇÃO NECESSÁRIA — Progresso salvo'
 echo 'Depois de reconectar, execute: sudo bash suite-servidores.sh'
 echo 'A sequência reconhecerá o progresso e escolherá a próxima etapa.'
 echo 'Nenhuma tarefa será executada automaticamente durante o boot.'
 if sequence_confirm 'Reiniciar agora?'; then
  systemctl reboot
 fi
}
sequence_flow() {
 ((EUID == 0)) || { echo 'Execute: sudo bash suite-servidores.sh'; return 1; }
 [[ -t 0 ]] || { echo 'A sequência exige terminal interativo'; return 1; }
 local self session reply rc before current boot_now
 self=$(readlink -f "${BASH_SOURCE[0]}")
 umask 077
 local SEQ_DIR=/var/lib/gerbit-suite
 [[ ! -L $SEQ_DIR ]] || { echo 'Diretório de progresso não pode ser link'; return 1; }
 install -d -m 700 -o root -g root "$SEQ_DIR"
 exec 7>"$SEQ_DIR/sequence.lock"
 flock -n 7 || { echo 'Outra sequência já está aberta'; return 1; }
 session=$(mktemp /var/log/gerbit-sequencia-XXXXXXXX.log)
 exec > >(tee -a "$session") 2>&1
 screen_header 'Sequência guiada — Sistema e PHP'
 echo "Log desta execução: $session"
 echo 'A próxima etapa será escolhida pelo assistente; você confirma as mudanças.'
 echo 'Aplicações e sites exigem homologação; atualização de pacotes não prova compatibilidade.'
 local SEQ_PHP=latest SEQ_OS=26.04 SEQ_PHASE=system SEQ_BOOT=-
 if [[ -f $SEQ_DIR/progress && ! -L $SEQ_DIR/progress ]]; then
  local -a saved=()
  mapfile -t saved < "$SEQ_DIR/progress"
  if ((${#saved[@]} != 4)) ||
   [[ ! ${saved[0]} =~ ^(latest|[0-9]+\.[0-9]+)$ ]] ||
   [[ ! ${saved[1]} =~ ^(22\.04|24\.04|26\.04)$ ]] ||
   [[ ! ${saved[2]} =~ ^(system|packages|php|done)$ ]] ||
   [[ ! ${saved[3]} =~ ^(-|[a-f0-9-]+)$ ]]; then
   echo 'Progresso inválido. Não será executado.'; return 1
  fi
  printf '\nProgresso anterior: PHP %s | Ubuntu alvo %s | etapa %s\n' "${saved[0]}" "${saved[1]}" "${saved[2]}"
  if [[ ${saved[2]} != done ]] && sequence_confirm 'Retomar esta sequência?'; then
   SEQ_PHP=${saved[0]}; SEQ_OS=${saved[1]}; SEQ_PHASE=${saved[2]}; SEQ_BOOT=${saved[3]}
  else
   sequence_confirm 'Iniciar uma nova sequência e substituir o progresso anterior?' || return 0
  fi
 fi
 if [[ $SEQ_PHASE == system && $SEQ_BOOT == - ]]; then
  section 'OBJETIVO — Escolha apenas as versões de destino'
  read -r -p 'Linha PHP desejada (Enter = latest estável): ' reply
  SEQ_PHP=${reply:-latest}
  [[ $SEQ_PHP =~ ^(latest|[0-9]+\.[0-9]+)$ ]] || { echo 'Linha inválida'; return 1; }
  read -r -p 'Ubuntu de destino: 22.04 / 24.04 / 26.04 (Enter = 26.04): ' reply
  SEQ_OS=${reply:-26.04}
  [[ $SEQ_OS =~ ^(22\.04|24\.04|26\.04)$ ]] || { echo 'Destino inválido'; return 1; }
 fi
 boot_now=$(cat /proc/sys/kernel/random/boot_id)
 if [[ $SEQ_BOOT != - && $SEQ_BOOT == "$boot_now" ]]; then
  echo 'A reinicialização pendente ainda não ocorreu.'
  sequence_reboot; return 20
 fi
 SEQ_BOOT=-
 sequence_save
 section 'ETAPA AUTOMÁTICA — Diagnóstico inicial'
 if bash "$self" --diagnose; then :; else
  echo 'Diagnóstico interrompido; nenhuma atualização iniciada.'; return 1
 fi
 while true; do
  . /etc/os-release
  case "$ID:${VERSION_ID:-}" in
   ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:11|debian:12|debian:13) ;;
   *) echo 'Sistema sem procedimento implementado. Progresso preservado.'; return 1;;
  esac
  case "$SEQ_PHASE" in
   system)
    if [[ $ID == ubuntu ]] && dpkg --compare-versions "$VERSION_ID" lt "$SEQ_OS"; then
     section "PRÓXIMA ETAPA — Atualizar Ubuntu $VERSION_ID para a próxima LTS"
     echo "Objetivo: Ubuntu $SEQ_OS e PHP $SEQ_PHP. Não serão puladas versões LTS."
     echo 'Repositórios terceiros, PHP, bancos e aplicações podem precisar de migração.'
     echo 'O sistema usará o atualizador oficial; a disponibilidade do próximo salto é definida por ele.'
     sequence_confirm 'Revisou o impacto nas aplicações, tem console e autoriza este salto LTS?' || return 0
     before=$VERSION_ID
     if bash "$self" --distro --console-confirmed; then rc=0; else rc=$?; fi
     if ((rc == 20)); then sequence_reboot; return 20; fi
     if ((rc == 10)); then echo 'Etapa cancelada. Progresso preservado.'; return 0; fi
     if ((rc != 0)); then echo 'Upgrade interrompido. Corrija o erro exibido; depois reabra a sequência.'; return "$rc"; fi
     . /etc/os-release
     if [[ $VERSION_ID == "$before" ]]; then
      echo 'O atualizador não confirmou mudança de release. O PHP não será instalado agora.'
      echo 'Consulte a saída do atualizador e /var/log/dist-upgrade. Progresso preservado.'; return 1
     fi
     sequence_reboot; return 20
    fi
    if [[ $ID == debian && $VERSION_ID == 11 ]]; then
     echo 'Debian 11 exige migração de release com roteiro próprio, ainda não implementado nesta suíte.'
     echo 'Não trocaremos automaticamente os repositórios Debian.'; return 1
    fi
    SEQ_PHASE=packages; sequence_save;;
   packages)
    section 'PRÓXIMA ETAPA — Atualizar pacotes da distribuição atual'
    if bash "$self" --packages; then rc=0; else rc=$?; fi
    if ((rc == 10)); then echo 'Atualização cancelada. PHP não será iniciado.'; return 0; fi
    if ((rc == 20)); then sequence_reboot; return 20; fi
    if ((rc != 0)); then
     echo 'Atualização interrompida. O assistente pode verificar pendências do APT/dpkg.'
     if sequence_confirm 'Abrir diagnóstico e opções de correção do APT agora?'; then
      if bash "$self" --repair; then
       sequence_confirm 'Tentar novamente a atualização dos pacotes?' && continue
      fi
     fi
     return "$rc"
    fi
    SEQ_PHASE=php; sequence_save;;
   php)
    if [[ -e /run/reboot-required ]]; then sequence_reboot; return 20; fi
    section "PRÓXIMA ETAPA — Instalar/atualizar PHP $SEQ_PHP"
    echo 'A instalação não troca automaticamente o PHP dos sites, pools, crons e workers.'
    sequence_confirm 'Autoriza instalar os pacotes PHP após revisar a compatibilidade das aplicações?' || return 0
    local -a flags=(--php --apply --target "$SEQ_PHP")
    if sequence_confirm 'Autorizar repositório de terceiros Sury/ondrej se necessário?'; then flags+=(--add-repo); fi
    if sequence_confirm 'Ativar o PHP de destino também no terminal?'; then flags+=(--activate-cli); fi
    if bash "$self" "${flags[@]}"; then rc=0; else rc=$?; fi
    if ((rc == 10)); then echo 'Instalação cancelada. Progresso preservado.'; return 0; fi
    if ((rc != 0)); then
     echo 'O PHP encontrou um impedimento. Veja a mensagem e o log; não faremos outra troca de OS às cegas.'
     echo 'A versão antiga do Linux foi tratada antes desta etapa. Extensões ausentes exigem análise específica.'
     return "$rc"
    fi
    SEQ_PHASE=done; sequence_save;;
   done)
    section 'FIM DA SEQUÊNCIA — Etapas de pacotes e PHP encerradas sem erro'
    echo 'Pendente: homologar aplicações e migrar o PHP dos sites/pools quando necessário.'
    echo "Log: $session"
    echo 'Uma nova execução perguntará se deseja iniciar outra sequência.'
    return 0;;
  esac
 done
}

# Fontes dos limites, consultadas em 23/10/2026:
# https://www.php.net/archive/2026.php#2026-10-21-5
# https://ubuntu.com/security/notices/USN-8948-1
# https://ubuntu.com/security/notices/USN-8948-2
# https://security-tracker.debian.org/tracker/CVE-2026-109618
# https://security-tracker.debian.org/tracker/CVE-2026-109619
# Estes limites tratam somente CVE-2026-109618 e CVE-2026-109619.
security_version_fixed() {
 local line=$1 version=$2 os=$3 release=$4 upstream minimum=''
 SEC_REASON='Correção não comprovada pelos limites conhecidos'
 [[ $version != '(none)' && -n $version ]] || return 1
 upstream=${version#*:}; upstream=${upstream%%-*}
 case "$line" in 8.2) minimum=8.2.35;; 8.3) minimum=8.3.36;; 8.4) minimum=8.4.27;; 8.5) minimum=8.5.12;; esac
 if [[ -n $minimum ]] && dpkg --compare-versions "$upstream" ge "$minimum"; then
  SEC_REASON="Atende mínimo upstream $minimum"; return 0
 fi
 # Não confundir a versão upstream antiga com ausência de patch do fornecedor.
 if [[ $os == ubuntu && $version == *ubuntu* && $version != *sury* ]]; then
  case "$release:$line:$version" in
   20.04:7.4:7.4.3-4ubuntu2.*) minimum=7.4.3-4ubuntu2.29+esm5;;
   22.04:8.1:8.1.2-1ubuntu2.*) minimum=8.1.2-1ubuntu2.28;;
   24.04:8.3:8.3.6-0ubuntu0.24.04.*) minimum=8.3.6-0ubuntu0.24.04.13;;
   26.04:8.5:8.5.4-0ubuntu1.*) minimum=8.5.4-0ubuntu1.5;;
   *) minimum='';;
  esac
  if [[ -n $minimum ]] && dpkg --compare-versions "$version" ge "$minimum"; then
   SEC_REASON="Atende backport Ubuntu $minimum (USN-8948)"; return 0
  fi
 fi
 return 1
}
security_inventory() {
 mapfile -t SEC_PACKAGES < <(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' | awk '$2=="installed" && ($1 ~ /^php[0-9]+\.[0-9]+-/ || $1 ~ /^libapache2-mod-php[0-9]+\.[0-9]+/) {print $1}')
 SEC_RUNTIMES=()
 local p n
 for p in "${SEC_PACKAGES[@]}"; do
  n=${p%%:*}
  if [[ $n =~ ^php[0-9]+\.[0-9]+-(cli|fpm|cgi|phpdbg)$ || $n =~ ^libapache2-mod-php[0-9]+\.[0-9]+$ ]]; then SEC_RUNTIMES+=("$p"); fi
 done
}
security_report() {
 local p n line version status
 SEC_UNRESOLVED=0
 section 'AUDITORIA — Pacotes de execução PHP instalados'
 for p in "${SEC_RUNTIMES[@]}"; do
  n=${p%%:*}
  [[ $n =~ (php)([0-9]+\.[0-9]+) ]] || continue
  line=${BASH_REMATCH[2]}
  version=$(dpkg-query -W -f='${Version}' "$p")
  if security_version_fixed "$line" "$version" "$ID" "$VERSION_ID"; then status='ATENDE AO LIMITE'; else status='PENDENTE'; SEC_UNRESOLVED=$((SEC_UNRESOLVED+1)); fi
  printf '%s\n  Versão: %s\n  Resultado: %s — %s\n\n' "$p" "$version" "$status" "$SEC_REASON"
 done
 echo 'Resultado baseado na versão do pacote e nos avisos citados; não é teste de exploração.'
 echo 'Builds personalizados, containers, outros hosts e workers independentes não são cobertos.'
}
security_disable_upload_progress() {
 local run=$1 root=/etc/php dir file backup tmp version sapi conflict
 SEC_UPLOAD_STATUS='PENDENTE — alteração não autorizada'
 section 'MITIGAÇÃO ADICIONAL — Desativar progresso de upload em sessão'
 echo 'Será definido session.upload_progress.enabled=0 nos conf.d de PHP encontrados.'
 echo 'Isso desativa o recurso de acompanhamento de uploads via sessão; não desativa uploads.'
 echo 'Configurações anteriores serão copiadas para o diretório do relatório.'
 if ! sequence_confirm 'Aplicar esta configuração adicional recomendada pelo PHP?'; then
  return 0
 fi
 local -a dirs=()
 shopt -s nullglob
 for dir in "$root"/*/{cli,fpm,apache2,cgi}/conf.d; do
  [[ -d $dir ]] || continue
  dirs+=("$dir")
 done
 shopt -u nullglob
 if ((${#dirs[@]} == 0)); then
  SEC_UPLOAD_STATUS='PENDENTE — nenhum diretório padrão conf.d encontrado'
  echo "$SEC_UPLOAD_STATUS"; return 0
 fi
 backup="$run/upload-progress-backup"
 install -d -m 700 "$backup"
 # Primeiro valida todos os destinos, antes de alterar o primeiro.
 for dir in "${dirs[@]}"; do
  file="$dir/zzzz-gerbit-security-upload-progress.ini"
  if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
   echo "Destino não regular; operação bloqueada: $file"; return 1
  fi
 done
 : > "$run/upload-progress-files.txt"
 for dir in "${dirs[@]}"; do
  file="$dir/zzzz-gerbit-security-upload-progress.ini"
  if [[ -f $file ]]; then
   install -d -m 700 "$backup${dir}"
   cp -a -- "$file" "$backup$file"
   printf 'ANTERIOR\t%s\n' "$file" >> "$run/upload-progress-files.txt"
  else
   printf 'NOVO\t%s\n' "$file" >> "$run/upload-progress-files.txt"
  fi
  tmp=$(mktemp "$dir/.gerbit-upload-XXXXXXXX")
  printf '%s\n' \
   '; Gerbit: orientação PHP de 23/10/2026 — session upload progress' \
   '; https://www.php.net/archive/2026.php' \
   'session.upload_progress.enabled=0' > "$tmp"
  chmod 644 "$tmp"
  chown root:root "$tmp"
  mv -f -- "$tmp" "$file"
  printf 'CONFIGURADO: %s\n' "$file"
 done
 SEC_UPLOAD_STATUS='CONFIGURADO — aguarda reinicialização e verificação dos serviços web'
 # Overrides por pool/Apache podem prevalecer sobre conf.d. Não imprime conteúdo sensível.
 local -a checks=()
 for dir in "$root"/*/fpm/pool.d /etc/apache2; do [[ ! -d $dir ]] || checks+=("$dir"); done
 if ((${#checks[@]})); then
  conflict=$(grep -RIlE '^[[:space:]]*[^;#[:space:]].*session[.]upload_progress[.]enabled' "${checks[@]}" 2>/dev/null || true)
  if [[ -n $conflict ]]; then
   echo 'ATENÇÃO: existem referências em pools/Apache que podem sobrescrever o conf.d:'
   printf '%s\n' "$conflict"
   SEC_UPLOAD_STATUS='CONFIGURADO — overrides detectados; configuração efetiva precisa ser verificada'
  fi
 fi
 echo "Backup dos arquivos anteriores: $backup"
 echo "Lista de arquivos criados/alterados: $run/upload-progress-files.txt"
 echo 'Para reverter: restaure os arquivos ANTERIOR do backup e remova somente os arquivos NOVO listados; reinicie os serviços.'
}

security_flow() {
 ((EUID == 0)) || { echo 'Execute com sudo'; return 1; }
 [[ -t 0 ]] || { echo 'Execute em terminal interativo'; return 1; }
 . /etc/os-release
 [[ $ID == ubuntu || $ID == debian ]] || { echo 'Auditoria/atualização automática implementada apenas para Debian e Ubuntu.'; return 1; }
 local panel
 for panel in /usr/local/cpanel /usr/local/psa /usr/local/directadmin /www/server/panel /etc/pve /etc/proxmox-backup; do
  [[ ! -e $panel ]] || { echo "Ambiente com procedimento próprio: $panel. Operação bloqueada."; return 1; }
 done
 command -v flock >/dev/null || return 1
 exec 8>/run/lock/gerbit-suite.lock
 flock -n 8 || { echo 'Outra operação da suíte em execução'; return 1; }
 exec 9>/run/lock/atualizar-php.lock
 flock -n 9 || { echo 'Outra atualização PHP em execução'; return 1; }
 umask 077
 local run
 run=$(mktemp -d /var/backups/gerbit-php-security-XXXXXXXX)
 exec > >(tee -a "$run/security.log") 2>&1
 screen_header 'Correção prioritária — PHP2Shell'
 echo "Sistema: $PRETTY_NAME | $(uname -m)"
 apt_eol_notice
 echo "Relatório: $run/security.log"
 echo 'Escopo: CVE-2026-109618 e CVE-2026-109619, publicadas em 21/10/2026.'
 echo 'Prioridade: corrigir todas as linhas instaladas sem migrar a distribuição ou os sites.'
 local -a SEC_PACKAGES=() SEC_RUNTIMES=()
 local SEC_UNRESOLVED=0 SEC_REASON=''
 security_inventory
 ((${#SEC_RUNTIMES[@]})) || { echo 'Nenhum runtime PHP APT identificado; instalação manual/container exige auditoria própria.'; return 1; }
 security_report
 echo 'Fontes: https://www.php.net/archive/2026.php#2026-10-21-5'
 echo 'https://ubuntu.com/security/notices/USN-8948-1 | https://ubuntu.com/security/notices/USN-8948-2'
 echo 'Em 23/10, PHP também orientou session.upload_progress.enabled=0 para CVE-2026-115560.'
 echo 'Esta etapa oferecerá aplicar essa configuração com backup e reiniciar os serviços identificados.'
 sequence_confirm 'Atualizar os índices APT e procurar pacotes corrigidos nas linhas atuais?' || return 0
 apt_refresh
 apt-get check
 [[ -z $(dpkg --audit) ]] || { echo 'dpkg incompleto. Use --repair antes de tentar novamente.'; return 1; }
 local p n line candidate q name active_config unresolved_candidates=0
 local -a upgrades=() services=()
 local -A eligible=()
 section 'PLANO — Correções disponíveis'
 for p in "${SEC_RUNTIMES[@]}"; do
  n=${p%%:*}; [[ $n =~ php([0-9]+\.[0-9]+) ]] || continue; line=${BASH_REMATCH[1]}
  candidate=$(apt-cache policy "$p" | awk '/Candidate:/{print $2}')
  if security_version_fixed "$line" "$candidate" "$ID" "$VERSION_ID"; then
   printf '%s: candidato %s — %s\n' "$p" "$candidate" "$SEC_REASON"
   eligible[$line]=1
  else
   printf 'SEM CORREÇÃO COMPROVADA: %s, candidato %s\n' "$p" "${candidate:-ausente}"
   unresolved_candidates=$((unresolved_candidates+1))
  fi
 done
 # Atualiza runtimes e extensões já instalados apenas das linhas com candidato corrigido.
 for q in "${SEC_PACKAGES[@]}"; do
  name=${q%%:*}; [[ $name =~ php([0-9]+\.[0-9]+) ]] || continue; line=${BASH_REMATCH[1]}
  [[ ${eligible[$line]:-0} != 1 ]] || upgrades+=("$q")
 done
 if ((${#upgrades[@]})); then
  apt-get -s --only-upgrade --no-remove install "${upgrades[@]}"
  echo 'A instalação pode reiniciar serviços por scripts dos pacotes.'
  backup_question || return 10
  sequence_confirm 'Aplicar este plano de atualização PHP nas linhas atuais?' || return 10
  local -a paths=(etc/apt)
  for p in etc/php etc/apache2 etc/nginx; do [[ ! -e /$p ]] || paths+=("$p"); done
  tar -C / -czf "$run/configuration.tar.gz" "${paths[@]}"
  dpkg-query -W > "$run/packages-before.txt"
  # Guarda serviços ativos antes da atualização, para reiniciar inclusive workers antigos.
  mapfile -t services < <(systemctl list-units --type=service --state=active --no-legend --plain 'php*-fpm.service' | awk '{print $1}')
  if compgen -G '/etc/apache2/mods-enabled/php*.load' >/dev/null && systemctl is-active --quiet apache2; then services+=(apache2.service); fi
  apt_run --only-upgrade --no-remove install "${upgrades[@]}"
  apt-get check
  security_report
 else
  echo 'Nenhuma linha tem candidato corrigido disponível neste APT.'
 fi
 # Mesmo pacotes previamente atualizados podem ter processos carregados com binários antigos.
 if ((${#services[@]} == 0)); then
  mapfile -t services < <(systemctl list-units --type=service --state=active --no-legend --plain 'php*-fpm.service' | awk '{print $1}')
  if compgen -G '/etc/apache2/mods-enabled/php*.load' >/dev/null && systemctl is-active --quiet apache2; then services+=(apache2.service); fi
 fi
 local SEC_UPLOAD_STATUS='PENDENTE' SEC_UPLOAD_RESTARTED=0
 security_disable_upload_progress "$run"
 section 'ATIVAÇÃO — Reiniciar processos PHP dos serviços identificados'
 if ((${#services[@]})); then
  printf 'Serviço: %s\n' "${services[@]}"
  if sequence_confirm 'Validar configuração e reiniciar estes serviços para carregar os binários instalados?'; then
   for p in "${services[@]}"; do
    if [[ $p =~ ^php([0-9]+\.[0-9]+)-fpm.service$ ]]; then
     "/usr/sbin/php-fpm${BASH_REMATCH[1]}" -t
    elif [[ $p == apache2.service ]]; then apache2ctl configtest
    else echo "Serviço não reconhecido: $p"; return 1
    fi
   done
   for p in "${services[@]}"; do systemctl restart "$p"; systemctl is-active --quiet "$p"; done
   SEC_UPLOAD_RESTARTED=1
   echo 'Serviços identificados reiniciados e ativos. Valide o atendimento HTTP das aplicações.'
  else
   echo 'PENDENTE: workers não foram reiniciados por esta etapa; não considerar a correção ativada.'
  fi
 else
  echo 'Nenhum FPM/Apache com mod_php ativo identificado. CGI, supervisores e containers precisam de análise própria.'
 fi
 section 'RESULTADO — Revisão de segurança'
 security_report
 if ((SEC_UNRESOLVED || unresolved_candidates)); then
  echo 'PENDENTE: há linhas sem correção comprovada. Não declarar o servidor protegido.'
  if [[ $ID == ubuntu && $VERSION_ID == 20.04 ]]; then
   echo 'Ubuntu20.04/PHP7.4: o fix oficial é 7.4.3-4ubuntu2.29+esm5 via Ubuntu Pro.'
   echo 'Verifique Ubuntu Pro/ESM e disponibilidade para esta máquina antes de considerar migração.'
   if command -v pro >/dev/null; then pro status || true; fi
  fi
  echo 'Se não houver patch do fornecedor, planeje migração compatível ou restrição de exposição.'
  echo 'A modernização continua disponível em --sequence, com decisões separadas.'
 fi
 echo 'PENDENTE de auditoria específica: pools/configurações efetivas, workers fora do systemd e containers.'
 section 'RESULTADO — session.upload_progress.enabled'
 echo "$SEC_UPLOAD_STATUS"
 if ((SEC_UPLOAD_RESTARTED)); then
  echo 'Serviços web identificados reiniciados. Configurações de pools/virtualhosts ainda podem sobrescrever o valor.'
 else
  echo 'PENDENTE: ativar a configuração reiniciando todos os workers PHP afetados.'
 fi
 local phpbin effective
 for phpbin in /usr/bin/php[0-9]*; do
  [[ $phpbin =~ /php[0-9]+[.][0-9]+$ && -x $phpbin ]] || continue
  if effective=$("$phpbin" -r 'echo ini_get("session.upload_progress.enabled") ? "ATIVADO" : "DESATIVADO";' 2>/dev/null); then
   printf 'Verificação CLI (%s): %s — não comprova configuração HTTP/FPM.\n' "$phpbin" "$effective"
  fi
 done
 echo 'Pendentes de verificação própria: CGI persistente, pools/virtualhosts, supervisores e containers.' 
 echo "Relatório completo: $run/security.log"
}

if (($# == 0)) || [[ ${1:-} == --security ]]; then
 security_flow
elif [[ ${1:-} == --sequence ]]; then
 sequence_flow
elif [[ ${1:-} == --wizard ]]; then
 interactive_wizard
elif [[ ${1:-} == --repair ]]; then
 repair_stage
else
 main "$@"
fi
