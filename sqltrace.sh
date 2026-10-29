#!/usr/bin/env bash
# sqltrace.sh — 10053 (DBMS_SQLDIAG.DUMP_TRACE) + 10046 (sql_trace) + tkprof
# для одного sql_id (event на весь инстанс) или одной сессии (dbms_monitor).
#
# Oracle 19c, single instance. Запуск на сервере БД от владельца ORACLE_HOME
# (нужен "/ as sysdba", ORACLE_HOME и ORACLE_SID в окружении). Bash >= 4.2.
set -Eeuo pipefail
umask 077   # в трейсах значения binds — это данные, не даём их читать всем

readonly PROG=${0##*/}
readonly MAX_SECS=3600
readonly SAMPLE_SECS=3

SQL_ID="" CHILD=0 SECS=60 PDB="" OUT="" SESS="" SID="" SERIAL=""
NO_10046=0 FORCE=0 RATE_LIMIT=200
TRACE_ON=0 MODE="" MARKER="" SESS_TRACE=""

declare -A TK=([sort]=exeela,fchela,prsela [sys]=no [waits]=yes [aggregate]=yes)
declare -a TK_ORDER=(sort sys waits aggregate)

usage() {
  cat <<EOF
Usage:
  $PROG -s SQL_ID [-c CHILD] [-d SECS] [-r RATE] [-f] [-p PDB] [-o DIR] [-- TKPROF_OPTS...]
  $PROG -S SID,SERIAL [-s SQL_ID [-c CHILD]] [-d SECS] [-p PDB] [-o DIR] [-- TKPROF_OPTS...]
  $PROG -n -s SQL_ID [-c CHILD] [-p PDB] [-o DIR]

Захват 10046:
  -s SQL_ID       без -S: event sql_trace[SQL: id] на весь инстанс
  -S SID,SERIAL   dbms_monitor.session_trace_enable для одной сессии
                  (-s тогда нужен только для 10053 и сводки)
Опции:
  -c CHILD        child_number для 10053 (default 0)
  -d SECS         длительность захвата 1..$MAX_SECS (default 60); Ctrl+C — закончить раньше
  -r RATE         порог executions/sec для event-режима (default $RATE_LIMIT)
  -f              игнорировать порог RATE
  -p PDB          контейнер, где живёт курсор (для 10053)
  -o DIR          каталог результатов (default ./sqltrace_<id>_<timestamp>)
  -n              только 10053, без 10046/tkprof
  -- OPTS         опции tkprof key=value, перекрывают умолчания:
                  sort=exeela,fchela,prsela sys=no waits=yes aggregate=yes
EOF
}

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- SQL*Plus
# SQL пишется в heredoc с кавычками ('SQL'), поэтому $ в v$-вьюхах не трогается
# shell'ом. Параметры подставляются через плейсхолдеры @X@ после валидации.
render() {
  local s
  s=$(cat)
  s=${s//@SQL_ID@/$SQL_ID}
  s=${s//@CHILD@/$CHILD}
  s=${s//@SID@/$SID}
  s=${s//@SERIAL@/$SERIAL}
  s=${s//@PDB@/$PDB}
  printf '%s\n' "$s"
}

sql() {
  local out
  if ! out=$(
    {
      printf '%s\n' \
        'whenever sqlerror exit failure rollback' \
        'whenever oserror exit failure' \
        'set heading off feedback off pagesize 0 linesize 32767 verify off echo off tab off' \
        'set trimout on trimspool on serveroutput on size unlimited'
      render
      printf '%s\n' 'exit success'
    } | "$SQLPLUS" -S -L / as sysdba
  ); then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

# ---------------------------------------------------------------- args
parse_args() {
  local opt
  while getopts ':s:S:c:d:r:fp:o:nh' opt; do
    case $opt in
      s) SQL_ID=$OPTARG ;;
      S) SESS=$OPTARG ;;
      c) CHILD=$OPTARG ;;
      d) SECS=$OPTARG ;;
      r) RATE_LIMIT=$OPTARG ;;
      f) FORCE=1 ;;
      p) PDB=$OPTARG ;;
      o) OUT=$OPTARG ;;
      n) NO_10046=1 ;;
      h) usage; exit 0 ;;
      :) die "-$OPTARG требует значение" ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))   # getopts сам съедает "--"

  local a k v
  for a in "$@"; do
    [[ $a =~ ^([a-z_]+)=([^[:space:]]+)$ ]] || die "опция tkprof должна быть key=value: '$a'"
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    case $k in
      explain) die "explain= не поддерживается: tkprof перепарсит SQL с текущей статистикой и покажет не тот план; реальный план уже в STAT-строках" ;;
    esac
    [[ -n ${TK[$k]+x} ]] || TK_ORDER+=("$k")
    TK[$k]=$v
  done
}

validate() {
  [[ -n $SQL_ID || -n $SESS ]] || { usage >&2; exit 2; }
  [[ -z $SQL_ID || $SQL_ID =~ ^[0-9a-z]{13}$ ]] || die "sql_id: 13 символов [0-9a-z]"
  [[ $CHILD =~ ^[0-9]+$ ]] || die "child_number: целое >= 0"
  [[ $SECS =~ ^[0-9]+$ ]] && (( SECS >= 1 && SECS <= MAX_SECS )) || die "-d: 1..$MAX_SECS"
  [[ $RATE_LIMIT =~ ^[0-9]+$ ]] || die "-r: целое"
  [[ -z $PDB || $PDB =~ ^[A-Za-z][A-Za-z0-9_]{0,127}$ ]] || die "некорректное имя PDB"
  if [[ -n $SESS ]]; then
    [[ $SESS =~ ^([0-9]+),([0-9]+)$ ]] || die "-S: SID,SERIAL"
    SID=${BASH_REMATCH[1]} SERIAL=${BASH_REMATCH[2]}
  fi
  if (( NO_10046 )); then
    [[ -n $SQL_ID ]] || die "-n требует -s SQL_ID"
    MODE=none
  elif [[ -n $SESS ]]; then
    MODE=session
  else
    MODE=event
  fi

  : "${ORACLE_HOME:?ORACLE_HOME не задан}"
  : "${ORACLE_SID:?ORACLE_SID не задан}"
  SQLPLUS=$ORACLE_HOME/bin/sqlplus
  TKPROF=$ORACLE_HOME/bin/tkprof
  [[ -x $SQLPLUS ]] || die "нет $SQLPLUS"
  [[ $MODE == none || -x $TKPROF ]] || die "нет $TKPROF"
}

# ---------------------------------------------------------------- 10046
enable_trace() {
  case $MODE in
    event) sql <<'SQL' >/dev/null
alter system set events 'sql_trace[SQL: @SQL_ID@] wait=true, bind=true, plan_stat=all_executions';
SQL
    ;;
    session) sql <<'SQL' >/dev/null
begin
  dbms_monitor.session_trace_enable(
    session_id => @SID@, serial_num => @SERIAL@,
    waits => true, binds => true, plan_stat => 'ALL_EXECUTIONS');
end;
/
SQL
    ;;
  esac
  TRACE_ON=1
}

disable_trace() {
  case $MODE in
    event) sql <<'SQL' >/dev/null
alter system set events 'sql_trace[SQL: @SQL_ID@] off';
SQL
    ;;
    session) sql <<'SQL' >/dev/null
begin
  dbms_monitor.session_trace_disable(session_id => @SID@, serial_num => @SERIAL@);
exception
  when others then null;  -- сессия могла завершиться за время захвата
end;
/
SQL
    ;;
  esac
  TRACE_ON=0
}

cleanup() {
  local rc=$?
  if (( TRACE_ON )); then
    log "выключаю трейс после прерывания"
    disable_trace || log "WARNING: трейс НЕ выключен — выключите вручную!"
  fi
  if [[ -n $MARKER ]]; then rm -f "$MARKER"; fi
  exit "$rc"
}

exec_count() {
  sql <<'SQL'
select nvl(sum(executions), 0) from v$sql where sql_id = '@SQL_ID@';
SQL
}

preflight() {
  TRACE_DIR=$(sql <<'SQL'
select value from v$diag_info where name = 'Diag Trace';
SQL
)
  [[ -d $TRACE_DIR ]] || die "нет каталога трейсов: $TRACE_DIR"

  local maxdump
  maxdump=$(sql <<'SQL'
select upper(value) from v$parameter where name = 'max_dump_file_size';
SQL
)
  [[ $maxdump == UNLIMITED ]] || log "WARNING: max_dump_file_size=$maxdump — трейсы могут обрезаться"

  case $MODE in
    event)
      local e1 e2 rate
      e1=$(exec_count)
      sleep "$SAMPLE_SECS"
      e2=$(exec_count)
      rate=$(( (e2 - e1) / SAMPLE_SECS ))
      log "sql_id $SQL_ID: ~${rate} exec/s"
      (( e2 > 0 )) || log "WARNING: курсора нет в shared pool — за окно захвата может не выполниться ни разу"
      if (( rate > RATE_LIMIT && ! FORCE )); then
        die "~${rate} exec/s > порога ${RATE_LIMIT}: event-трейс затронет все сессии. Уменьшите -d, используйте -S или -f"
      fi
      ;;
    session)
      local row server status cur
      row=$(sql <<'SQL'
select s.server || '|' || s.status || '|' || nvl(s.sql_id, '-') || '|' || p.tracefile
  from v$session s
  join v$process p on p.addr = s.paddr
 where s.sid = @SID@ and s.serial# = @SERIAL@;
SQL
)
      [[ -n $row ]] || die "сессия $SID,$SERIAL не найдена"
      IFS='|' read -r server status cur SESS_TRACE <<<"$row"
      log "сессия $SID,$SERIAL: $server/$status, текущий sql_id=$cur"
      [[ $server == DEDICATED ]] || log "WARNING: $server server — трейс размажется по разным процессам, соберётся не всё"
      ;;
  esac
}

capture() {
  local pid
  log "захват 10046: ${SECS}s (Ctrl+C — закончить раньше)"
  sleep "$SECS" & pid=$!
  trap 'kill "$pid" 2>/dev/null || true' INT
  wait "$pid" 2>/dev/null || true
  trap 'exit 130' INT
}

collect_10046() {
  local -a files=()
  case $MODE in
    event)
      mapfile -t files < <(
        find "$TRACE_DIR" -maxdepth 1 -type f -name '*.trc' -newer "$MARKER" -print0 \
          | xargs -0 -r grep -l -F "sqlid='$SQL_ID'" || true
      )
      ;;
    session)
      if [[ -s $SESS_TRACE ]]; then files=("$SESS_TRACE"); fi
      ;;
  esac
  (( ${#files[@]} )) || { log "WARNING: трейсов 10046 не найдено"; return 0; }
  log "трейсов 10046: ${#files[@]}"

  local -a tk_args=()
  local k f b
  for k in "${TK_ORDER[@]}"; do tk_args+=("$k=${TK[$k]}"); done

  mkdir -p "$OUT/10046"
  for f in "${files[@]}"; do
    b=${f##*/}
    cp -p -- "$f" "$OUT/10046/$b"
    if ! "$TKPROF" "$OUT/10046/$b" "$OUT/10046/${b%.trc}.prf" "${tk_args[@]}" \
         >"$OUT/10046/${b%.trc}.tkprof.log" 2>&1; then
      log "WARNING: tkprof упал на $b (см. ${b%.trc}.tkprof.log)"
    fi
  done

  if [[ -n $SQL_ID ]]; then summarize_10046; fi
}

# Сводка по нашему sql_id из всех .prf: строка "total" каждого файла + сумма.
summarize_10046() {
  local -a prfs=("$OUT"/10046/*.prf)
  [[ -e ${prfs[0]} ]] || return 0
  awk -v id="$SQL_ID" '
    BEGIN { printf "%-60s %8s %10s %10s %10s %12s %10s\n",
                   "file", "count", "cpu", "elapsed", "disk", "query", "rows" }
    $0 ~ "^SQL ID: " id { hit = 1; next }
    hit && /^total/ {
      n = FILENAME; sub(/.*\//, "", n)
      printf "%-60s %8d %10.2f %10.2f %10d %12d %10d\n", n, $2, $3, $4, $5, $6, $8
      c += $2; cpu += $3; ela += $4; dsk += $5; q += $6; r += $8; hit = 0
    }
    END { printf "%-60s %8d %10.2f %10.2f %10d %12d %10d\n",
                 "TOTAL", c, cpu, ela, dsk, q, r }
  ' "${prfs[@]}" >"$OUT/10046/SUMMARY.txt"
}

# ---------------------------------------------------------------- 10053
dump_10053() {
  local trc
  trc=$(
    {
      if [[ -n $PDB ]]; then echo 'alter session set container = @PDB@;'; fi
      cat <<'SQL'
declare
  l_cnt   pls_integer;
  l_trace v$diag_info.value%type;
begin
  select count(*) into l_cnt
    from v$sql
   where sql_id = '@SQL_ID@' and child_number = @CHILD@;
  if l_cnt = 0 then
    raise_application_error(-20001, 'cursor @SQL_ID@/@CHILD@ not in shared pool');
  end if;

  sys.dbms_sqldiag.dump_trace(
    p_sql_id       => '@SQL_ID@',
    p_child_number => @CHILD@,
    p_component    => 'Compiler',
    p_file_id      => 'DUMP_@SQL_ID@_@CHILD@');

  select value into l_trace from v$diag_info where name = 'Default Trace File';
  dbms_output.put_line(l_trace);
end;
/
SQL
    } | sql
  )
  [[ -s $trc ]] || die "трейс 10053 не создан: '$trc'"

  mkdir -p "$OUT/10053"
  cp -p -- "$trc" "$OUT/10053/"
  extract_10053 "$OUT/10053/${trc##*/}" >"$OUT/10053/SUMMARY.txt"
  log "10053: ${trc##*/}"
}

# Best-effort выжимка из 10053: финальный запрос, peeked binds, план, outline.
extract_10053() {
  awk '
    function hdr(t) { printf "\n===== %s =====\n", t }
    !q && /UNPARSED QUERY IS/ {
      q = 1; hdr("Final query after transformations")
      if ((getline line) > 0) print line
      next
    }
    !b && /^Peeked values of the binds in SQL statement/ { b = 1; inb = 1; hdr("Peeked binds"); next }
    inb {
      if ($0 ~ /^[[:space:]]*$/ || ++bn > 300) inb = 0
      else if ($0 !~ /^\*+$/) print
      next
    }
    !p && /^Plan Table$/ { p = 1; inp = 1; hdr("Plan"); next }
    inp {
      if ($0 ~ /^(Content of other_xml|[[:space:]]*Outline Data:)/ || ++pn > 500) inp = 0
      else if ($0 !~ /^=+$/) { print; next }
    }
    !o && /BEGIN_OUTLINE_DATA/ { o = 1; ino = 1; hdr("Outline") }
    ino { print; if (/END_OUTLINE_DATA/) ino = 0 }
  ' "$1"
}

# ---------------------------------------------------------------- main
main() {
  parse_args "$@"
  validate

  local tag=${SQL_ID:-sid${SID}_${SERIAL}}
  OUT=${OUT:-./sqltrace_${tag}_$(date +%Y%m%d_%H%M%S)}
  mkdir -p "$OUT"

  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  if [[ $MODE != none ]]; then
    preflight
    MARKER=$(mktemp)
    enable_trace
    capture
    disable_trace
    collect_10046
  fi

  # 10053 — после выключения 10046, чтобы hard parse внутри DUMP_TRACE не попал в трейс
  if [[ -n $SQL_ID ]]; then dump_10053; fi

  log "готово: $OUT"
  find "$OUT" -type f -name '*SUMMARY.txt' -o -type f -name '*.prf' | sort >&2
}

main "$@"
