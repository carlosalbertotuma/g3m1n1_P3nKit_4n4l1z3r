#!/bin/bash
export GEMINI_API_KEY="SUA KEY AQUI"

set -euo pipefail

PROG="$(basename "$0")"
TARGET=""
INPUT_FILE=""
NMAP_ARGS="-sV -sT"
OUT_FILE=""
SAVE_JSON=0
CHUNK_SIZE=30000   # caracteres por chunk (ajuste se necessário)

usage(){
  cat << "EOF"

        ____           __      __        _  _        _  _   _ __     ____       
       |___ \         /_ |    /_ |      | || |      | || | | /_ |   |___ \      
   __ _  __) |_ __ ___ | |_ __ | |______| || |_ _ __| || |_| || |____ __) |_ __ 
  / _` ||__ <| '_ ` _ \| | '_ \| |______|__   _| '_ \__   _| || |_  /|__ <| '__|
 | (_| |___) | | | | | | | | | | |         | | | | | | | | | || |/ / ___) | |   
  \__, |____/|_| |_| |_|_|_| |_|_|         |_| |_| |_| |_| |_||_/___|____/|_|   
   __/ |                                                                        
  |___/                                                      By bl4dsc4n - v 0.1

$PROG - Envia saída do nmap para gemini-cli.

Uso:
  $PROG [-t target] [-f nmap_file] [-a "nmap args"] [-o out_file] [--json]

Opções:
  -t TARGET       Executa nmap no TARGET
  -f FILE         Usa saída do nmap já existente em FILE
  -a "ARGS"       Argumentos extras do nmap (default: -sV -sT)
  -o FILE         Salva resposta do gemini-cli em FILE
  --json          Tenta salvar resposta no formato JSON simples (raw)
  -h              Mostrar ajuda
EOF
  exit 1
}

while (( "$#" )); do
  case "$1" in
    -t) TARGET="$2"; shift 2 ;;
    -f) INPUT_FILE="$2"; shift 2 ;;
    -a) NMAP_ARGS="$2"; shift 2 ;;
    -o) OUT_FILE="$2"; shift 2 ;;
    --json) SAVE_JSON=1; shift ;;
    -h) usage ;;
    *) echo "Opção inválida: $1"; usage ;;
  esac
done

if [[ -z "$TARGET" && -z "$INPUT_FILE" ]]; then
  echo "Erro: forneça -t TARGET ou -f NMAP_OUTPUT_FILE"
  exit 1
fi

if ! command -v gemini-cli >/dev/null 2>&1; then
  echo "Erro: gemini-cli não está no PATH."
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

NMAP_OUT="$TMPDIR/nmap.out"
PROMPT_FILE="$TMPDIR/prompt.txt"
RESPONSE_FILE="${OUT_FILE:-$TMPDIR/gemini_response.txt}"

# 1) gerar/recuperar saída do nmap
if [[ -n "$TARGET" ]]; then
  echo "[*] Executando: nmap $NMAP_ARGS $TARGET"
  # -oN - envia para stdout; redirecionamos
  nmap $NMAP_ARGS "$TARGET" -oN - > "$NMAP_OUT" 2>&1 || true
else
  echo "[*] Usando arquivo de entrada: $INPUT_FILE"
  cp "$INPUT_FILE" "$NMAP_OUT"
fi

# 2) construir prompt base (em PT-BR). Ajuste se quiser.
cat > "$PROMPT_FILE" <<'EOF'
Você é um assistente de segurança da informação. Analise a saída do nmap abaixo e:
1) Resuma brevemente serviços/versões encontrados.
2) Aponte portas/serviços que merecem investigação e por quê.
3) Sugira comandos de verificação adicionais (nmap scripts, banner grab, enumeração) com exemplos.
4) Dê recomendações de mitigação e prioridades (alta/média/baixa).
5) Liste possíveis falsos positivos a checar.
6) Forneça referências (CVE/exploit-db) quando aplicável.
Responda em português. Não forneça instruções para invasão não autorizada.
--- SAÍDA DO NMAP AQUI ---
EOF

# 3) anexar saída do nmap ao prompt (manter seguro)
# usamos sed para escapar sequências especiais que possam confundir a CLI
echo "----- INÍCIO OUTPUT NMAP -----" >> "$PROMPT_FILE"
cat "$NMAP_OUT" >> "$PROMPT_FILE"
echo "----- FIM OUTPUT NMAP -----" >> "$PROMPT_FILE"

# função utilitária: tentar --prompt-file, depois -p, depois stdin
send_to_gemini(){
  local file="$1"
  local response="$2"

  echo "[*] Tentativa 1: gemini-cli -i --prompt-file \"$file\""
  if gemini-cli -i --prompt-file "$file" > "$response" 2>&1; then
    echo "[*] Sucesso via --prompt-file"
    return 0
  fi

  echo "[*] Tentativa 2: gemini-cli -i -p (conteúdo do arquivo -> flag -p)"
  # enviar com -p (tem que escapar)
  local content
  content="$(cat "$file")"
  if gemini-cli -i -p "$content" > "$response" 2>&1; then
    echo "[*] Sucesso via -p"
    return 0
  fi

  echo "[*] Tentativa 3: enviar por stdin (pipe)"
  if cat "$file" | gemini-cli -i > "$response" 2>&1; then
    echo "[*] Sucesso via stdin"
    return 0
  fi

  return 1
}

# 4) Se o prompt for pequeno, tentar mandar inteiro; se for grande, chunk
PROMPT_LEN=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
if (( PROMPT_LEN <= CHUNK_SIZE )); then
  if send_to_gemini "$PROMPT_FILE" "$RESPONSE_FILE"; then
    echo "[*] Resposta salva em $RESPONSE_FILE"
  else
    echo "[!] Todas as tentativas falharam. Vou tentar enviar por chunks."
    CHUNK_MODE=1
  fi
else
  echo "[*] Prompt grande ($PROMPT_LEN bytes) -> usando modo chunk."
  CHUNK_MODE=1
fi

# 5) Chunking: enviar partes sequenciais com instrução 'CONTINUE' para o modelo
if [[ "${CHUNK_MODE:-0}" == "1" ]]; then
  # dividir em N partes por caracteres
  awk -v RS='' -v CHUNK="$CHUNK_SIZE" '{
    s=$0
    n=int((length(s)+CHUNK-1)/CHUNK)
    for(i=0;i<n;i++){
      start = i*CHUNK+1
      print substr(s,start,CHUNK)
      if(i<n-1) print "__CHUNK_BOUNDARY__"
    }
  }' "$PROMPT_FILE" > "$TMPDIR/_chunks.txt"

  # contar chunks e enviar sequencialmente. O esquema: enviar primeiro chunk com instruções
  # "Parte X/Y - você receberá próximas partes. Não responda até receber todas; ao final responda."
  # Alguns gemini-cli não respeitam multi-turn via stdin — ainda assim tentamos.
  mapfile -t CHUNKS < <(awk 'BEGIN{RS="__CHUNK_BOUNDARY__"} {print}' "$TMPDIR/_chunks.txt")
  TOTAL=${#CHUNKS[@]}
  echo "[*] Enviando $TOTAL chunks..."
  # começar conversa inicial (first)
  > "$RESPONSE_FILE"
  for idx in "${!CHUNKS[@]}"; do
    i=$((idx+1))
    body="PARTE $i DE $TOTAL\n\n${CHUNKS[idx]}"
    # instrução para o modelo: se não for a última, aguarde CONTINUE; se última peça, responder
    if (( i < TOTAL )); then
      body="$body\n\n--- INSTRUÇÃO: Isto é parte $i de $TOTAL. Aguarde as próximas partes. NÃO RESPONDA AINDA. ---"
    else
      body="$body\n\n--- INSTRUÇÃO: Esta é a última parte. Agora responda seguindo as instruções iniciais. ---"
    fi

    # tentar enviar o chunk
    # preferimos pipe para evitar problemas de quoting
    echo "$body" | gemini-cli -i >> "$RESPONSE_FILE" 2>&1 || {
      echo "[!] Falha ao enviar chunk $i. Abortando chunk mode."
      break
    }
    sleep 1
  done
  echo "[*] Chunks enviados; resposta agregada em $RESPONSE_FILE (pode precisar limpeza)."
fi

# 6) salvar/mostrar resultado
if [[ -n "${OUT_FILE:-}" ]]; then
  cp "$RESPONSE_FILE" "$OUT_FILE"
  echo "[*] Arquivo final salvo em $OUT_FILE"
fi

if (( SAVE_JSON )); then
  # tentativa simples: encapsula a resposta bruta num JSON com timestamp
  jq -n --arg target "${TARGET:-file}" --arg resp "$(sed 's/"/\\"/g' "$RESPONSE_FILE")" \
    '{target:$target, timestamp:now|todate, response:$resp}' > "${OUT_FILE:-./gemini_response.json}" 2>/dev/null || \
  printf '{"target":"%s","timestamp":"%s","response":"%s"}\n' "${TARGET:-file}" "$(date --iso-8601=seconds)" "$(sed 's/"/\\"/g' "$RESPONSE_FILE")" > "${OUT_FILE:-./gemini_response.json}"
  echo "[*] JSON salvo em ${OUT_FILE:-./gemini_response.json}"
else
  echo "----- INÍCIO DA RESPOSTA DO GEMINI -----"
  sed -n '1,400p' "$RESPONSE_FILE" || true
  echo "----- FIM DA RESPOSTA (arquivo:$RESPONSE_FILE) -----"
fi

exit 0
