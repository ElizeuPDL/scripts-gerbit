#!/usr/bin/env bash
# Gerbit: inicializador com curl, wget ou Python3 e recuperação de download APT.
set -Eeuo pipefail
export LC_ALL=C
sequence_confirm() {
 local reply
 read -r -p "$1 [s/N]: " reply || return 1
 [[ $reply == s || $reply == S ]]
}
# APT com perfis temporários de recuperação; fontes persistentes não são alteradas.
apt-get() {
 local -a options=()
 [[ -z ${GERBIT_APT_LISTS:-} ]] || options+=(-o "Dir::State::lists=$GERBIT_APT_LISTS")
 [[ -z ${GERBIT_APT_SOURCE:-} ]] || options+=(-o "Dir::Etc::sourcelist=$GERBIT_APT_SOURCE" -o Dir::Etc::sourceparts=-)
 command apt-get "${options[@]}" "$@"
}
apt-cache() {
 local -a options=()
 [[ -z ${GERBIT_APT_LISTS:-} ]] || options+=(-o "Dir::State::lists=$GERBIT_APT_LISTS")
 [[ -z ${GERBIT_APT_SOURCE:-} ]] || options+=(-o "Dir::Etc::sourcelist=$GERBIT_APT_SOURCE" -o Dir::Etc::sourceparts=-)
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
apt_bullseye_archive() {
 local os_id os_version profile previous_source=${GERBIT_APT_SOURCE:-} previous_lists=${GERBIT_APT_LISTS:-}
 os_id=$(. /etc/os-release; echo "$ID")
 os_version=$(. /etc/os-release; echo "$VERSION_ID")
 [[ $os_id == debian && $os_version == 11 && -z $previous_source ]] || return 1
 [[ ${GERBIT_ALLOW_BULLSEYE_ARCHIVE:-1} != 0 ]] || { echo 'Fallback Bullseye bloqueado durante a migração para Bookworm.'; return 1; }
 if grep -RqsE '^[[:space:]]*(deb[[:space:]].*bookworm|Suites:[[:space:]].*bookworm)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  echo 'Fontes Bookworm detectadas: não será usado arquivo Bullseye para evitar mistura de releases.'; return 1
 fi
 echo 'O mirror atual não forneceu os arquivos. Existe um arquivo oficial para Bullseye.'
 echo 'Será usado archive.debian.org somente nesta execução, com índices separados.'
 echo 'Repositórios terceiros não serão usados nesta tentativa. /etc/apt não será modificado.'
 echo 'Pacotes arquivados NÃO são novas correções de segurança; servem para preparar a migração.'
 sequence_confirm 'Tentar o arquivo oficial assinado do Debian11?' || return 1
 [[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] || { echo 'Chave oficial Debian ausente; operação bloqueada.'; return 1; }
 umask 077
 profile=$(mktemp -d /var/backups/gerbit-bullseye-archive-XXXXXXXX)
 cat > "$profile/sources.list" <<'ARCHIVE'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://archive.debian.org/debian bullseye main contrib non-free
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://archive.debian.org/debian-security bullseye-security main contrib non-free
ARCHIVE
 GERBIT_APT_SOURCE="$profile/sources.list"
 GERBIT_APT_LISTS=$(mktemp -d /var/lib/apt/gerbit-lists-XXXXXXXX)
 chmod 755 "$GERBIT_APT_LISTS"
 install -d -m 700 "$GERBIT_APT_LISTS/partial"
 echo "Perfil temporário: $GERBIT_APT_SOURCE"
 # Sem trusted=yes, sem --allow-unauthenticated, sem desligar validade/TLS.
 if apt_refresh; then
  echo 'Índices do arquivo oficial validados pelo APT. Confira o novo plano antes de instalar.'
  return 0
 fi
 GERBIT_APT_SOURCE=$previous_source; GERBIT_APT_LISTS=$previous_lists
 echo 'Arquivo oficial não pôde ser validado. Não prosseguiremos com índices não autenticados.'
 return 1
}
apt_prepare() {
 if apt_refresh; then return 0; fi
 if apt_recover_indexes; then return 0; fi
 apt_bullseye_archive
}
apt_run() {
 local log rc retry_log
 log=$(mktemp /var/tmp/gerbit-apt-error-XXXXXXXX.log)
 chmod 600 "$log"
 if apt-get "$@" 2>&1 | tee "$log"; then rm -f "$log"; return 0; else rc=$?; fi
 if ! grep -Eq '404|Failed to fetch|Unable to fetch some archives' "$log"; then
  echo "Erro não relacionado a download. Sem repetição automática. Log: $log"; return "$rc"
 fi
 echo "Falha de download APT. Detalhes: $log"
 if apt_recover_indexes; then
  retry_log="$log.retry"
  echo 'Nova tentativa com índices recarregados; o APT recalculará o plano.'
  if apt-get "$@" 2>&1 | tee "$retry_log"; then return 0; else rc=$?; fi
  if ! grep -Eq '404|Failed to fetch|Unable to fetch some archives' "$retry_log"; then
   echo "A tentativa falhou por outro motivo. Sem troca de repositório. Log: $retry_log"; return "$rc"
  fi
 fi
 if apt_bullseye_archive; then
  echo 'Tentativa final com o arquivo oficial. Revise versões, remoções e tamanho do download.'
  if apt-get "$@"; then return 0; else rc=$?; fi
 fi
 echo "Operação interrompida. Logs: $log e possíveis arquivos .retry."
 echo 'O processo não ignora assinaturas, certificados ou metadados vencidos.'
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

((EUID == 0)) || { echo 'Execute com sudo/root'; exit 1; }
[[ -t 0 ]] || { echo 'Baixe o arquivo antes de executá-lo; requer terminal interativo'; exit 1; }
apt_eol_notice
if ! command -v curl >/dev/null && ! command -v wget >/dev/null && ! command -v python3 >/dev/null; then
 echo 'Nenhum downloader suportado disponível.'
 sequence_confirm 'Instalar curl e certificados pelo APT?' || exit 0
 apt_prepare
 apt_run --no-remove install curl ca-certificates
fi
url=https://raw.githubusercontent.com/ElizeuPDL/scripts-gerbit/main/suite-servidores.sh
work=$(mktemp -d /var/tmp/gerbit-download-XXXXXXXX)
chmod 700 "$work"
file="$work/suite-servidores.sh"
ok=0
if command -v curl >/dev/null; then
 if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$file"; then ok=1; fi
fi
if ((ok == 0)) && command -v wget >/dev/null; then
 if wget --https-only -O "$file" "$url"; then ok=1; fi
fi
if ((ok == 0)) && command -v python3 >/dev/null; then
 if python3 - "$url" "$file" <<'PYTHON'
import sys,urllib.request,ssl
with urllib.request.urlopen(sys.argv[1], context=ssl.create_default_context(), timeout=60) as r:
    if not r.geturl().startswith('https://'):
        raise SystemExit('Redirecionamento inseguro recusado')
    with open(sys.argv[2],'wb') as f:
        f.write(r.read())
PYTHON
 then ok=1; fi
fi
((ok)) || { echo 'Download falhou. Verifique rede, DNS, horário e certificados.'; exit 1; }
bash -n "$file"
echo "Suíte baixada e sintaxe Bash validada: $file"
sequence_confirm 'Executar agora o fluxo de segurança PHP?' || exit 0
# Uma recuperação do APT permanece válida apenas nesta execução do inicializador.
# A suíte fará a própria atualização e recuperação se necessário.
bash "$file" --security
