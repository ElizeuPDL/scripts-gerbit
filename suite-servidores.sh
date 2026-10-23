#!/usr/bin/env bash
# Suíte Gerbit v2.3: assistente interativo de manutenção.
set -Eeuo pipefail
export LC_ALL=C
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
 Sem argumentos: abre o assistente interativo.
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
 ((backup)) || backup_question || return 0
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
   [[ $decision == 'ACEITAR FALHAS' ]] || return 0
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
 "${apt[@]}" update
 "${apt[@]}" check
 # Sem -y: o operador revisa remoções e responde perguntas de configuração.
 section 'ETAPA — Simulação da atualização de pacotes'
 "${apt[@]}" -s dist-upgrade | tee "$run/package-plan.txt"
 echo 'A operação pode substituir pacotes, remover dependências e reiniciar serviços.'
 local answer
 read -r -p 'Executar o plano? [s/N]: ' answer
 [[ $answer == s || $answer == S ]] || { echo 'Cancelado antes da atualização de pacotes.'; return 0; }
 section 'ETAPA — Execução da atualização de pacotes'
 "${apt[@]}" dist-upgrade
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
 "${apt[@]}" --no-remove install update-manager-core
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
((ACK)) || { backup_question || exit 0; }
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
 section 'ETAPA — Atualização dos índices APT para PHP'
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
section 'ETAPA — Simulação da instalação do PHP'
"${APT[@]}" -s --no-remove install "${PACKAGES[@]}" | tee "$RUN/plan.txt"
section 'ETAPA — Instalação dos pacotes PHP'
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
 printf '\nGERBIT — ASSISTENTE DE MANUTENÇÃO v2.3\n%s\n\n' "$1"
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
 echo 'GERBIT — ASSISTENTE DE MANUTENÇÃO v2.3'
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
   0|'') echo "Encerrado. Log: $session"; return 0;;
   *) echo 'Opção inválida';;
  esac
  section "FIM DA AÇÃO $choice — $action_title — $(date '+%H:%M:%S')"
  if ((rc == 20)); then
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
if (($# == 0)) || [[ ${1:-} == --wizard ]]; then
 interactive_wizard
elif [[ ${1:-} == --repair ]]; then
 repair_stage
else
 main "$@"
fi
