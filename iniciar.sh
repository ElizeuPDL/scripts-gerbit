#!/usr/bin/env bash
# Gerbit: inicializador com curl, wget ou Python3 e recuperação de download APT.
set -Eeuo pipefail
export LC_ALL=C
sequence_confirm() {
 local reply
 read -r -p "$1 [s/N]: " reply || return 1
 [[ $reply == s || $reply == S ]]
}
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

((EUID == 0)) || { echo 'Execute com sudo/root'; exit 1; }
[[ -t 0 ]] || { echo 'Baixe o arquivo antes de executá-lo; requer terminal interativo'; exit 1; }
apt_eol_notice
if ! command -v curl >/dev/null && ! command -v wget >/dev/null && ! command -v python3 >/dev/null; then
 echo 'Nenhum downloader suportado disponível.'
 sequence_confirm 'Instalar curl e certificados pelo APT?' || exit 0
 if ! apt_refresh; then
  apt_recover_indexes || exit 1
 fi
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
