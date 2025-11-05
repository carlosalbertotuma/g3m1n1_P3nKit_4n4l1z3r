# g3m1n1-toolkit

Conjunto de scripts para análise automatizada de saídas de ferramentas de pentest (ex.: `nmap`) usando o Gemini CLI e para executar comandos sugeridos de forma segura.

> **Aviso legal / ética**: Use apenas em alvos que você possui ou tem autorização explícita para testar. O autor e este repositório não se responsabilizam por uso indevido.
---

<img width="764" height="324" alt="image" src="https://github.com/user-attachments/assets/2293f27d-0eb3-4a5a-bfa4-8e2686b03b59" />

---

<img width="692" height="354" alt="image" src="https://github.com/user-attachments/assets/6cb8d883-01fa-4b01-a01a-f6c280809e1f" />


---

## Conteúdo

* `g3m1n1-4n4l1z3r.sh` — coleta saída do `nmap`, constrói um prompt e envia para `gemini-cli` (várias estratégias: `--prompt-file`, `-p`, stdin). Gera um relatório bruto com a análise do modelo.

* `g3m1n1-4n4l1z3r-v2-safer.sh` — lê o relatório gerado pelo Gemini, extrai comandos sugeridos, filtra ruído (headers/strings soltas), aplica políticas de segurança (whitelist, timeout, auto-attach de alvo opcional) e executa os comandos permitidos salvando logs.

* `g3m1n1-runner.sh` (opcional) — versão alternativa/mais simples para extrair e executar comandos; ver histórico do repositório para variantes.

---

## Requisitos

* `bash` (POSIX-compatible)
* `nmap` (se usar a etapa de scan dentro do primeiro script)
* `gemini-cli` disponível no `PATH` (ou ajuste de acordo com a sua instalação)
* `timeout` (coreutils) recomendado
* `perl` (usado para extração inline — há fallback se não tiver)
* `jq` (opcional, para salvar JSON)

Testado em sistemas Linux com utilitários coreutils comuns. Scripts incluem heurísticas para compatibilidade com `awk`, `sed`, `grep` mais básicos.

---

## Instalação

1. Clone o repositório:

```bash
git clone <repo-url>
cd <repo-dir>
```

2. Dê permissão de execução:

```bash
chmod +x g3m1n1-4n4l1z3r.sh g3m1n1-4n4l1z3r-v2-safer.sh g3m1n1-runner.sh
```

3. (Opcional) Instale dependências via package manager:

```bash
# Debian/Ubuntu example
sudo apt update && sudo apt install -y nmap perl jq coreutils
```

---

## Uso — fluxo recomendado (passo a passo)

### 1) Rodar análise (gera relatório do Gemini)

```bash
# Executa nmap e envia ao gemini-cli, salva saída em gemini_response.txt
./g3m1n1-4n4l1z3r.sh -t 127.0.0.1 -o gemini_response.txt
```

O script tentará `--prompt-file`, `-p` e stdin, e fará chunking automático para saídas grandes.

### 2) Extrair e (opcionalmente) executar comandos sugeridos

```bash
# Dry-run (lista comandos detectados)
./g3m1n1-4n4l1z3r-v2-safer.sh -f gemini_response.txt

# Executar comandos permitidos (ex.: curl, nikto, nmap)
./g3m1n1-4n4l1z3r-v2-safer.sh -f gemini_response.txt --run --allow "curl,nikto,nmap" --timeout 60
```

#### Opções úteis

* `--no-auto-attach`: impede anexar automaticamente um alvo quando o comando estiver sem argumentos.
* `--outdir <DIR>`: muda o diretório onde os logs são salvos.
* `--allow "a,b"`: substitui a whitelist padrão por prefixes permitidos.

---

## Como funciona (resumo técnico)

* **g3m1n1-4n4l1z3r.sh**: Executa `nmap` (se `-t` passado) ou usa arquivo (`-f`). Monta um prompt com instruções (resumir serviços, priorizar riscos, sugestões de comandos, mitigação) e envia para `gemini-cli`. Implementa três métodos de envio e chunking quando o prompt é grande.

* **g3m1n1-4n4l1z3r-v2-safer.sh**: Lê relatório, extrai blocos de código e inline code, aplica heurísticas para detectar verdadeiros comandos (flags, URLs, IPs, pipes), opcionalmente anexa um alvo detectado automaticamente, filtra tokens avulsos e executa apenas comandos que batem na whitelist. Cada comando é executado com `timeout` e seu stdout/stderr/meta são salvos em `outdir`.

---

## Segurança e boas práticas

* **Autorização**: confirme autorização escrita para todos os alvos.
* **Ambiente isolado**: para maior segurança, execute comandos de verificação dentro de contêineres (Docker) ou VMs. Posso fornecer um wrapper Docker para cada comando.
* **Revisão humana**: sempre faça dry-run e revise os comandos antes de executar. Preferência por executar manualmente em uma amostra antes de automatizar em larga escala.
* **Logs e auditoria**: o runner salva `*.out`, `*.err` e `*.meta` para investigação posterior. Não apague estes arquivos até completar auditoria.

---

## Troubleshooting

* `awk`/`grep -P` errors: use as versões coreutils; scripts têm variantes portáveis (sed/perl fallback). Se encontrar erros, reporte aqui o trecho do log.
* `gemini-cli` não aceita prompt: verifique flags com `gemini-cli --help`. Ajuste o script para priorizar `--prompt-file` ou usar stdin.

---

## Desenvolvimento

Contribuições são bem-vindas. Boas práticas:

* Abra issues descrevendo problema/feature.
* Para PRs: escreva testes mínimos, mantenha compatibilidade POSIX quando possível e documente mudanças no README.

---

## Exemplo de CI (opcional)

Um pipeline simples pode:

1. Rodar `shellcheck` nas scripts.
2. Executar `./g3m1n1-4n4l1z3r.sh -f tests/sample_nmap.txt -o /tmp/out.txt` (modo dry-run de integração).

---

## License


---


Qual desses deseja que eu faça a seguir?
