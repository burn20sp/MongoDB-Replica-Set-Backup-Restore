#!/usr/bin/env bash
# =============================================================================
# MongoDB Replica Set Backup & Restore
# Autor: Script para uso em ambiente com replica set
# Versão: 1.0.0
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurações padrão (ajuste conforme seu ambiente)
# ---------------------------------------------------------------------------
DEFAULT_HOST="${MONGO_HOST:-localhost}"
DEFAULT_PORT="${MONGO_PORT:-27017}"
DEFAULT_USER="${MONGO_USER:-}"
DEFAULT_PASS="${MONGO_PASS:-}"
DEFAULT_AUTHDB="${MONGO_AUTHDB:-admin}"
DEFAULT_BACKUP_DIR="${MONGO_BACKUP_DIR:-/backup/mongodb}"
DEFAULT_COMPRESS="${MONGO_COMPRESS:-true}"
DEFAULT_RETENTION_DAYS="${MONGO_RETENTION_DAYS:-7}"

# ---------------------------------------------------------------------------
# Cores para output (somente quando houver terminal compatível)
# ---------------------------------------------------------------------------
setup_colors() {
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    RED=$'\e[0;31m'
    GREEN=$'\e[0;32m'
    YELLOW=$'\e[1;33m'
    BLUE=$'\e[0;34m'
    CYAN=$'\e[0;36m'
    BOLD=$'\e[1m'
    RESET=$'\e[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
  fi
}

log_info()    { printf '%b
' "${BLUE}[INFO]${RESET}  $*"; }
log_ok()      { printf '%b
' "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { printf '%b
' "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { printf '%b
' "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { printf '%b
' ""; printf '%b
' "${BOLD}${CYAN}==> $*${RESET}"; }

# ---------------------------------------------------------------------------
# Exibir ajuda
# ---------------------------------------------------------------------------
usage() {
  cat << EOF
${BOLD}${CYAN}MongoDB Replica Set - Backup & Restore${RESET}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${BOLD}USO:${RESET}
  $(basename "$0") <operação> [opções]

${BOLD}OPERAÇÕES:${RESET}
  ${GREEN}backup${RESET}   Realiza backup do replica set usando mongodump + --oplog
  ${YELLOW}restore${RESET}  Restaura um backup em um replica set usando --oplogReplay
  ${CYAN}list${RESET}     Lista backups disponíveis no diretório de backup

${BOLD}OPÇÕES COMUNS:${RESET}
  -h, --host         HOST    Host do MongoDB    [padrão: ${DEFAULT_HOST}]
  -p, --port         PORT    Porta do MongoDB   [padrão: ${DEFAULT_PORT}]
  -u, --user         USER    Usuário autenticado
  -w, --password     PASS    Senha do usuário
  -a, --authdb       AUTHDB  Auth database       [padrão: ${DEFAULT_AUTHDB}]
  -d, --dir          PATH    Diretório de backup [padrão: ${DEFAULT_BACKUP_DIR}]
  -n, --database     NAME    Database específica (backup/restore)
  --no-compress              Desabilita compressão gzip

${BOLD}OPÇÕES DE BACKUP:${RESET}
  --oplog                    Incluir oplog (recomendado para replica set) [padrão: ON]
  --no-oplog                 Desativar oplog no backup
  --retention        DIAS    Dias de retenção dos backups [padrão: ${DEFAULT_RETENTION_DAYS}]

${BOLD}OPÇÕES DE RESTORE:${RESET}
  -f, --file         PATH    Arquivo .archive para restore
  --drop                     Apaga coleções antes de restaurar [padrão: OFF]
  --no-oplog-replay          Desabilita oplogReplay no restore

${BOLD}VARIÁVEIS DE AMBIENTE:${RESET}
  MONGO_HOST                 Host do MongoDB
  MONGO_PORT                 Porta do MongoDB
  MONGO_USER                 Usuário
  MONGO_PASS                 Senha
  MONGO_AUTHDB               Auth database
  MONGO_BACKUP_DIR           Diretório de backup
  MONGO_COMPRESS             true/false para compressão
  MONGO_RETENTION_DAYS       Dias de retenção

${BOLD}EXEMPLOS:${RESET}

  # Backup completo do replica set com oplog
  $(basename "$0") backup -h mongo-secondary -u admin -w senha123

  # Backup de uma database específica
  $(basename "$0") backup -h mongo-secondary -u admin -w senha123 -n meubanco

  # Backup em diretório customizado sem compressão
  $(basename "$0") backup -h 192.168.1.10 -d /mnt/nfs/backup --no-compress

  # Listar backups disponíveis
  $(basename "$0") list -d /backup/mongodb

  # Restore a partir de arquivo archive
  $(basename "$0") restore -h mongo-primary -u admin -w senha123 -f /backup/mongodb/full_20240101_020000.archive

  # Restore de database específica com --drop
  $(basename "$0") restore -h mongo-primary -u admin -w senha123 \\
      -f /backup/mongodb/full_20240101_020000.archive --drop -n meubanco

${BOLD}NOTAS IMPORTANTES:${RESET}
  • Para replica set, prefira executar o backup em um SECONDARY para não
    impactar o PRIMARY. Use a URI do secondary ou de um hidden member.
  • A flag --oplog é essencial para garantir consistência point-in-time
    durante o backup, capturando operações que ocorrem enquanto o dump roda.
  • O --oplogReplay no restore aplica essas operações garantindo consistência.
  • Após restore em um replica set novo, execute rs.initiate() e adicione
    os demais membros com rs.add(). O MongoDB fará o initial sync automaticamente.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Verificar dependências
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  for cmd in mongodump mongorestore; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Ferramentas não encontradas: ${missing[*]}"
    log_error "Instale as mongodb-database-tools: https://www.mongodb.com/try/download/database-tools"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Montar URI de conexão
# ---------------------------------------------------------------------------
build_uri() {
  local host="$1" port="$2" user="$3" pass="$4" authdb="$5"
  if [[ -n "$user" && -n "$pass" ]]; then
    echo "mongodb://${user}:${pass}@${host}:${port}/?authSource=${authdb}"
  else
    echo "mongodb://${host}:${port}/"
  fi
}

# ---------------------------------------------------------------------------
# Listar backups disponíveis
# ---------------------------------------------------------------------------
cmd_list() {
  local backup_dir="$1"
  log_section "Backups disponíveis em: ${backup_dir}"

  if [[ ! -d "$backup_dir" ]]; then
    log_warn "Diretório não encontrado: ${backup_dir}"
    exit 0
  fi

  local count=0
  echo -e "\n${BOLD}  %-50s %15s %12s${RESET}" "Arquivo" "Data/Hora" "Tamanho"
  echo "  $(printf '%.0s─' {1..80})"

  while IFS= read -r -d '' f; do
    local basename size mtime
    basename=$(basename "$f")
    size=$(du -sh "$f" 2>/dev/null | cut -f1)
    mtime=$(stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1 || stat -f "%Sm" "$f" 2>/dev/null)
    printf "  %-50s %15s %12s\n" "$basename" "$mtime" "$size"
    ((count++))
  done < <(find "$backup_dir" -maxdepth 1 -name "*.archive" -print0 2>/dev/null | sort -z)

  if [[ $count -eq 0 ]]; then
    log_warn "Nenhum arquivo .archive encontrado em ${backup_dir}"
  else
    echo ""
    log_ok "Total: ${count} backup(s) encontrado(s)"
  fi
}

# ---------------------------------------------------------------------------
# Operação de BACKUP
# ---------------------------------------------------------------------------
cmd_backup() {
  # Parse de argumentos
  local host="$DEFAULT_HOST" port="$DEFAULT_PORT"
  local user="$DEFAULT_USER" pass="$DEFAULT_PASS" authdb="$DEFAULT_AUTHDB"
  local backup_dir="$DEFAULT_BACKUP_DIR"
  local database="" compress="$DEFAULT_COMPRESS"
  local use_oplog=true retention="$DEFAULT_RETENTION_DAYS"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--host)        host="$2";       shift 2 ;;
      -p|--port)        port="$2";       shift 2 ;;
      -u|--user)        user="$2";       shift 2 ;;
      -w|--password)    pass="$2";       shift 2 ;;
      -a|--authdb)      authdb="$2";     shift 2 ;;
      -d|--dir)         backup_dir="$2"; shift 2 ;;
      -n|--database)    database="$2";   shift 2 ;;
      --no-compress)    compress=false;  shift ;;
      --oplog)          use_oplog=true;  shift ;;
      --no-oplog)       use_oplog=false; shift ;;
      --retention)      retention="$2";  shift 2 ;;
      *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
  done

  # Validações
  if [[ -n "$database" && "$use_oplog" == true ]]; then
    log_warn "--oplog não é compatível com backup de database específica. Desativando --oplog."
    use_oplog=false
  fi

  # Criar diretório de backup
  mkdir -p "$backup_dir"

  local ts; ts=$(date +"%Y%m%d_%H%M%S")
  local prefix; [[ -n "$database" ]] && prefix="db_${database}_${ts}" || prefix="full_${ts}"
  local archive="${backup_dir}/${prefix}.archive"

  local uri; uri=$(build_uri "$host" "$port" "$user" "$pass" "$authdb")

  log_section "Iniciando BACKUP"
  log_info "Host/Port:  ${host}:${port}"
  log_info "Database:   ${database:-TODAS}"
  log_info "Destino:    ${archive}"
  log_info "oplog:      ${use_oplog}"
  log_info "Compressão: ${compress}"
  log_info "Retenção:   ${retention} dias"
  echo ""

  # Montar comando
  local cmd=(mongodump --uri="$uri" --archive="$archive")
  [[ "$compress"   == true ]]  && cmd+=(--gzip)
  [[ "$use_oplog"  == true ]]  && cmd+=(--oplog)
  [[ -n "$database" ]]          && cmd+=(--db="$database")

  log_info "Executando: ${cmd[*]//--uri=*@/--uri=***@}"
  echo ""

  local start_time; start_time=$(date +%s)

  if "${cmd[@]}"; then
    local end_time elapsed size
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    size=$(du -sh "$archive" 2>/dev/null | cut -f1)
    echo ""
    log_ok "Backup concluído com sucesso!"
    log_info "Arquivo:  ${archive}"
    log_info "Tamanho:  ${size}"
    log_info "Duração:  ${elapsed}s"
  else
    log_error "Falha no backup!"
    exit 1
  fi

  # Rotação de backups antigos
  if [[ "$retention" -gt 0 ]]; then
    log_section "Rotação de backups (retenção: ${retention} dias)"
    local deleted=0
    while IFS= read -r -d '' old_file; do
      log_warn "Removendo arquivo antigo: $(basename "$old_file")"
      rm -f "$old_file"
      ((deleted++))
    done < <(find "$backup_dir" -maxdepth 1 -name "*.archive" -mtime +"$retention" -print0 2>/dev/null)
    [[ $deleted -gt 0 ]] && log_ok "${deleted} arquivo(s) antigo(s) removido(s)" \
                          || log_info "Nenhum arquivo para remover."
  fi
}

# ---------------------------------------------------------------------------
# Operação de RESTORE
# ---------------------------------------------------------------------------
cmd_restore() {
  local host="$DEFAULT_HOST" port="$DEFAULT_PORT"
  local user="$DEFAULT_USER" pass="$DEFAULT_PASS" authdb="$DEFAULT_AUTHDB"
  local archive="" database="" drop=false oplog_replay=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--host)          host="$2";       shift 2 ;;
      -p|--port)          port="$2";       shift 2 ;;
      -u|--user)          user="$2";       shift 2 ;;
      -w|--password)      pass="$2";       shift 2 ;;
      -a|--authdb)        authdb="$2";     shift 2 ;;
      -f|--file)          archive="$2";    shift 2 ;;
      -n|--database)      database="$2";   shift 2 ;;
      --drop)             drop=true;       shift ;;
      --no-oplog-replay)  oplog_replay=false; shift ;;
      *) log_error "Opção desconhecida: $1"; exit 1 ;;
    esac
  done

  # Validações
  if [[ -z "$archive" ]]; then
    log_error "Informe o arquivo de backup com -f/--file"
    exit 1
  fi
  if [[ ! -f "$archive" ]]; then
    log_error "Arquivo não encontrado: ${archive}"
    exit 1
  fi

  # Detectar compressão automaticamente
  local compress=false
  file "$archive" 2>/dev/null | grep -qi "gzip" && compress=true

  local uri; uri=$(build_uri "$host" "$port" "$user" "$pass" "$authdb")

  log_section "Iniciando RESTORE"
  log_warn "ATENÇÃO: Esta operação irá restaurar dados no MongoDB!"
  [[ "$drop" == true ]] && log_warn "MODO --drop ATIVO: as coleções serão apagadas antes do restore!"
  echo ""
  log_info "Host/Port:     ${host}:${port}"
  log_info "Database:      ${database:-TODAS}"
  log_info "Arquivo:       ${archive}"
  log_info "Compressão:    ${compress}"
  log_info "oplogReplay:   ${oplog_replay}"
  log_info "Drop:          ${drop}"
  echo ""

  # Confirmação interativa
  if [[ -t 0 ]]; then
    read -r -p "$(echo -e "${YELLOW}Confirma o restore? [s/N]:${RESET} ")" confirm
    [[ "$confirm" =~ ^[sS]$ ]] || { log_warn "Restore cancelado pelo usuário."; exit 0; }
    echo ""
  fi

  # Montar comando
  local cmd=(mongorestore --uri="$uri" --archive="$archive")
  [[ "$compress"      == true ]] && cmd+=(--gzip)
  [[ "$oplog_replay"  == true ]] && cmd+=(--oplogReplay)
  [[ "$drop"          == true ]] && cmd+=(--drop)
  [[ -n "$database" ]]            && cmd+=(--db="$database" --nsInclude="${database}.*")

  log_info "Executando: ${cmd[*]//--uri=*@/--uri=***@}"
  echo ""

  local start_time; start_time=$(date +%s)

  if "${cmd[@]}"; then
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    echo ""
    log_ok "Restore concluído com sucesso!"
    log_info "Duração: ${elapsed}s"
    echo ""
    log_section "Próximos passos para replica set"
    log_info "Se este é um novo replica set, execute no mongo shell:"
    echo -e "  ${CYAN}rs.initiate()${RESET}             # Inicializa o replica set (se necessário)"
    echo -e "  ${CYAN}rs.add('host2:27017')${RESET}     # Adiciona secundários"
    echo -e "  ${CYAN}rs.status()${RESET}               # Verifica o status do replica set"
    log_info "Os secundários farão initial sync automaticamente após rs.add()."
  else
    echo ""
    log_error "Falha no restore!"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Entrypoint principal
# ---------------------------------------------------------------------------
main() {
  setup_colors
  check_deps

  if [[ $# -eq 0 ]]; then
    usage
  fi

  local operation="$1"; shift

  case "$operation" in
    backup)  cmd_backup  "$@" ;;
    restore) cmd_restore "$@" ;;
    list)
      local dir="$DEFAULT_BACKUP_DIR"
      [[ $# -ge 2 && "$1" == "-d" ]] && dir="$2"
      cmd_list "$dir"
      ;;
    help|-h|--help) usage ;;
    *)
      log_error "Operação desconhecida: ${operation}"
      echo -e "Use ${CYAN}$(basename "$0") help${RESET} para ver as opções disponíveis."
      exit 1
      ;;
  esac
}

main "$@"
