#!/usr/bin/env bash

FILE=""
DO_RUN=0
TIMEOUT_SEC=30
OUTDIR="./g3m1n1_runs"
ALLOW_CSV="curl,nikto,nmap,nc,wget,python,openssl,sqlmap"
VERBOSE=1
AUTO_ATTACH_TARGET=1  

usage(){
  cat << "EOF"

        ____           __      __        _____ ____        _  ___ _   
       |___ \         /_ |    /_ |      |  __ \___ \      | |/ (_) |  
   __ _  __) |_ __ ___ | |_ __ | |______| |__) |__) |_ __ | ' / _| |_ 
  / _` ||__ <| '_ ` _ \| | '_ \| |______|  ___/|__ <| '_ \|  < | | __|
 | (_| |___) | | | | | | | | | | |      | |    ___) | | | | . \| | |_ 
  \__, |____/|_| |_| |_|_|_| |_|_|      |_|   |____/|_| |_|_|\_\_|\__|
   __/ |                                                              
  |___/                                            By bl4dsc4n - v 0.1


Uso: $0 -f FILE [--run] [--allow "cmd1,cmd2"] [--timeout N] [--outdir DIR] [--no-auto-attach]

  -f FILE           Arquivo com o relatório (stdout do gemini / nmap / result)
  --run             Executa os comandos extraídos (se estiverem na whitelist)
  --allow "a,b"     Override da whitelist (comandos permitidos por prefixo)
  --timeout N       Timeout em segundos por comando (default: $TIMEOUT_SEC)
  --outdir DIR      Diretório para salvar logs/outputs (default: $OUTDIR)
  --no-auto-attach  Não anexar automaticamente um IP/URL quando comando estiver sem alvo
  --quiet           Modo silencioso
EOF
  exit 1
}

while (( "$#" )); do
  case "$1" in
    -f) FILE="$2"; shift 2 ;;
    --run) DO_RUN=1; shift ;;
    --allow) ALLOW_CSV="$2"; shift 2 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --no-auto-attach) AUTO_ATTACH_TARGET=0; shift ;;
    --quiet) VERBOSE=0; shift ;;
    -h|--help) usage ;;
    *) echo "Opção inválida: $1"; usage ;;
  esac
done

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "Erro: forneça um arquivo válido com -f" >&2
  exit 2
fi

mkdir -p "$OUTDIR"

vprint(){ if (( VERBOSE )); then echo "$@"; fi }

TMP="$OUTDIR/_extracted_cmds.txt"
: > "$TMP"

sed -n '/^```/,/^```/p' "$FILE" | sed '/^```/d' >> "$TMP" 2>/dev/null || true
vprint "[*] extração de blocos de código (``` ``` ) via sed concluída"

perl -nle 'while(/`([^`]+)`/g){ print $1 }' "$FILE" >> "$TMP" 2>/dev/null || true
vprint "[*] extração inline via perl concluída"

grep -E '^\s*\$ .+' "$FILE" | sed -E 's/^\s*\$ //' >> "$TMP" || true
grep -E '^\s*(curl|nikto|nmap|nc|wget|python|openssl|sqlmap|msfconsole).+' "$FILE" | sed -E 's/^\s*//' >> "$TMP" || true

awk '{$1=$1};1' "$TMP" | awk '!seen[$0]++' > "$TMP".uniq
mv "$TMP".uniq "$TMP"
sed -i '/^\s*$/d' "$TMP"

IP_REGEX='([0-9]{1,3}\.){3}[0-9]{1,3}'
URL_REGEX='https?://[A-Za-z0-9._:/?&=%-]+'
DOMAIN_REGEX='[A-Za-z0-9.-]+\.(com|org|net|io|gov|edu|br|ru|de|cn|jp|info|dev|tech)'

# coletar primeiro alvo candidato (IP/URL/domínio) no arquivo, para auto-attach
FIRST_TARGET="$(grep -oE "$URL_REGEX" "$FILE" | head -n1 || true)"
if [[ -z "$FIRST_TARGET" ]]; then
  FIRST_TARGET="$(grep -oE "$IP_REGEX" "$FILE" | head -n1 || true)"
fi
if [[ -z "$FIRST_TARGET" ]]; then
  FIRST_TARGET="$(grep -oE "$DOMAIN_REGEX" "$FILE" | head -n1 || true)"
fi
vprint "[*] primeiro alvo candidato no relatório (auto-attach): ${FIRST_TARGET:-<nenhum>}"


FILTERED="$OUTDIR/_filtered_cmds.txt"
: > "$FILTERED"

while IFS= read -r line; do

  l="$(echo "$line" | sed 's/^[\*\-\s]*//')"
  if echo "$l" | grep -qE '(^|\s)-{1,2}[A-Za-z]+'; then
    echo "$l" >> "$FILTERED"
    continue
  fi
  if echo "$l" | grep -qE "$URL_REGEX|$IP_REGEX|$DOMAIN_REGEX"; then
    echo "$l" >> "$FILTERED"
    continue
  fi
  if echo "$l" | grep -qE '[\|>]' ; then
    echo "$l" >> "$FILTERED"
    continue
  fi
  firsttok=$(awk '{print $1}' <<< "$l")
  if echo "$ALLOW_CSV" | grep -q "$firsttok"; then
    tokcount=$(awk '{print NF}' <<< "$l")
    if (( tokcount >= 2 )); then
      echo "$l" >> "$FILTERED"
    elif (( AUTO_ATTACH_TARGET == 1 )) && [[ -n "$FIRST_TARGET" ]]; then
      echo "$l" >> "$FILTERED"
    else
      vprint "[SKIP] comando isolado sem alvo e sem auto-attach: $l"
    fi
    continue
  fi
  vprint "[SKIP] linha não parece comando: $l"
done < "$TMP"

awk '{$1=$1};1' "$FILTERED" | awk '!seen[$0]++' > "$FILTERED".uniq
mv "$FILTERED".uniq "$FILTERED"

mapfile -t CMDS < "$FILTERED"

if [[ ${#CMDS[@]} -eq 0 ]]; then
  echo "Nenhum comando detectado em $FILE após filtragem (ruído removido)."
  exit 0
fi

FINAL="$OUTDIR/_final_cmds.txt"
: > "$FINAL"
for cmd in "${CMDS[@]}"; do
  # trim
  cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  first="$(awk '{print $1}' <<< "$cmd")"
  has_target=0
  if echo "$cmd" | grep -qE "$URL_REGEX|$IP_REGEX|$DOMAIN_REGEX"; then
    has_target=1
  fi
  token_count=$(awk '{print NF}' <<< "$cmd")
  # if starts with known allowed verb but no target, attach FIRST_TARGET if enabled
  if echo "$ALLOW_CSV" | grep -q "$first" && (( has_target == 0 )); then
    if (( AUTO_ATTACH_TARGET == 1 )) && [[ -n "$FIRST_TARGET" ]]; then
      newcmd="$cmd $FIRST_TARGET"
      echo "# AUTO-ATTACHED_TARGET: original='$cmd' attached='$FIRST_TARGET'" >> "$OUTDIR/transform.log"
      echo "$newcmd" >> "$FINAL"
      continue
    else
      vprint "[DROP] comando permitido mas sem alvo e sem auto-attach: $cmd"
      continue
    fi
  fi
  if (( token_count == 1 )); then
    vprint "[DROP] token único sem alvo: $cmd"
    continue
  fi
  echo "$cmd" >> "$FINAL"
done

mapfile -t FINAL_CMDS < "$FINAL"

echo "Comandos detectados (após limpeza):"
for i in "${!FINAL_CMDS[@]}"; do
  idx=$((i+1))
  printf "%3d) %s\n" "$idx" "${FINAL_CMDS[i]}"
done

IFS=',' read -r -a ALLOW_ARR <<< "$ALLOW_CSV"
for i in "${!ALLOW_ARR[@]}"; do ALLOW_ARR[$i]=$(echo "${ALLOW_ARR[$i]}" | xargs); done

is_allowed(){
  local cmdline="$1"
  local first
  first=$(awk '{print $1}' <<< "$cmdline")
  for p in "${ALLOW_ARR[@]}"; do
    if [[ "$first" == "$p" ]]; then return 0; fi
  done
  return 1
}

if (( DO_RUN == 0 )); then
  echo
  echo "DRY-RUN (nenhum comando será executado). Use --run para executar comandos permitidos."
  exit 0
fi

echo
echo "=== EXECUTANDO COMANDOS (apenas comandos na whitelist) ==="
echo "Whitelist permitida (prefixos): ${ALLOW_ARR[*]}"
echo "Timeout por comando: ${TIMEOUT_SEC}s"
echo

for i in "${!FINAL_CMDS[@]}"; do
  idx=$((i+1))
  cmd="${FINAL_CMDS[i]}"
  safe_name="cmd_${idx}"
  out_file="$OUTDIR/${safe_name}.out"
  err_file="$OUTDIR/${safe_name}.err"
  meta_file="$OUTDIR/${safe_name}.meta"

  if is_allowed "$cmd"; then
    echo "[#${idx}] Executando: $cmd"
    echo "command: $cmd" > "$meta_file"
    echo "started: $(date --iso-8601=seconds)" >> "$meta_file"

    if command -v timeout >/dev/null 2>&1; then
      timeout --preserve-status "${TIMEOUT_SEC}"s bash -c "$cmd" > "$out_file" 2> "$err_file" || {
        rc=$?
        echo "ret=$rc" >> "$meta_file"
        echo "[$(date --iso-8601=seconds)] comando retornou código $rc (veja $err_file)" >> "$meta_file"
      }
    else
      bash -c "$cmd" > "$out_file" 2> "$err_file" &
      pid=$!
      ( sleep "$TIMEOUT_SEC"; kill -9 "$pid" 2>/dev/null ) &
      killer=$!
      wait $pid 2>/dev/null || true
      kill -9 "$killer" 2>/dev/null || true
      echo "ret=? (sem ferramenta timeout)" >> "$meta_file"
    fi

    echo "finished: $(date --iso-8601=seconds)" >> "$meta_file"
    echo "[#${idx}] Saída: $out_file  Erro: $err_file  Meta: $meta_file"
    echo
  else
    echo "[#${idx}] PULADO (não está na whitelist): $cmd"
    echo "$cmd" >> "$OUTDIR/blocked_commands.txt"
  fi
done

echo "Execução concluída. Logs em: $OUTDIR"
