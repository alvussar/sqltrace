# CLAUDE.md — память проекта sqltrace

Ключевые факты, чтобы новая сессия не переспрашивала. Обновлять при каждом значимом изменении.

## Проект

- `sqltrace.sh` — bash-обёртка 10046 + tkprof + 10053 (`DBMS_SQLDIAG.DUMP_TRACE`) для одного `sql_id` в Oracle 19c, single instance. Запуск на сервере БД под владельцем `ORACLE_HOME`, `sqlplus / as sysdba`.
- Режимы: event `sql_trace[SQL: id]` на весь инстанс; `-S SID,SERIAL` через `dbms_monitor`; `-n` — только 10053.
- Владелец: alvussar. Отвечать по-русски, в формате анализ → причина → решение → код → тесты → альтернативы → риски.
- В репозиторий кладём только файлы проекта. Тестовые стенды (Docker-образы, compose, скрипты нагрузки) в репо НЕ кладём.

## Стиль кода

- `set -Eeuo pipefail`, `umask 077`; комментарии по-русски, объясняют «почему».
- SQL — в heredoc `<<'SQL'` с плейсхолдерами `@SQL_ID@`, `@CHILD@`, `@SID@`, `@SERIAL@`, `@PDB@`, которые подставляет `render()` только после валидации в `validate()`.
- Перед коммитом: `shellcheck -s bash sqltrace.sh` без замечаний.

## Найденные и исправленные баги (подробно — REVIEW.md)

1. `kill -9`/OOM оставлял event включённым на весь инстанс → фоновый сторож `start_watchdog` выключает трейс через `SECS + WATCHDOG_GRACE` (120 с). `setsid` не используем: его нет в образе 23ai.
2. `TRACE_ON=1` ставился после `alter system` (окно для Ctrl+C) → теперь до.
3. `-r 09` отключал порог RATE (octal в `(( ))`) → все числа через `10#`.
4. Без `-p` для курсора в PDB `DUMP_TRACE` из CDB$ROOT писал пустой 10053 при rc=0 → PDB определяется по `v$sql.con_id`.
5. С `-p` 10053 всегда падал: `DUMP_TRACE` в PDB сбрасывает буфер `dbms_output` → путь к трейсу берётся отдельным SELECT из `v$diag_info`.
6. «Final query» брался из первого `UNPARSED QUERY IS` (до трансформаций) → последний `Final query after transformations`.
7. Peeked binds всегда пустые (пустая строка после `****`) → ведущие пустые строки пропускаются.
8. Повторный захват той же сессии: SUMMARY молча суммирует старый трейс → WARNING в `warn_stale`. Вырезать только новую часть нельзя: `PARSING IN CURSOR` (единственная строка с `sqlid=`) пишется один раз на курсор.
9. Ещё: rate не меньше 0; проверка места в Diag Trace (`MIN_FREE_MB`=2048); `SETTLE_SECS`=5 после `off`; колонка `current` в SUMMARY.

## Поведение Oracle, подтверждённое на стендах

- `alter system set events ... on/off` доходит до чужих сессий на границе вызова: длинный PL/SQL-вызов пишет трейс ещё 6–10 с после `off`, включение тоже ленивое.
- `v$sql` в CDB$ROOT видит курсоры всех PDB (`con_id`); в non-CDB `con_id = 0`.
- `v$diag_info 'Default Trace File'` после `DUMP_TRACE` содержит `p_file_id` (`..._DUMP_<sql_id>_<child>.trc`).
- Static SQL в PL/SQL нормализуется (комментарии вырезаются), поэтому sql_id тестовых курсоров одинаковые на 19c и 23ai.

## Как поднять тестовую БД (вне репо)

- 19c: `docker run -d --name o19 --shm-size=2g -e ORACLE_SID=ORCLCDB -e ORACLE_PDB=ORCLPDB1 -e ORACLE_PWD=<pwd> doctorkirk/oracle-19c` → Oracle 19.9 EE, **non-CDB** (несмотря на ORACLE_PDB). БД создаётся ~15 мин, готовность — `DATABASE IS READY TO USE!` в `docker logs`.
- 23ai: `docker run -d --name ofree --shm-size=1g -e ORACLE_PASSWORD=<pwd> gvenzl/oracle-free:23` → 26ai Free 23.26, CDB + PDB `FREEPDB1`, ~2 мин. В образе нет `setsid`, `ps`, `which`, python; perl есть в `$ORACLE_HOME/perl/bin/perl`.
- Официальный `container-registry.oracle.com` из облачной среды Claude недоступен (403 на прокси), Docker Hub часто упирается в rate limit; рабочее зеркало — `mirror.gcr.io/<образ>`. `dockerd` в контейнере запускается вручную.
- Нагрузка: схема APP (`t` 100k строк с `grp = mod(id, 100)`, `g` 100 строк), PL/SQL-цикл в сессии с `module='LOAD'`, `dbms_session.sleep(0.05)`. Курсоры: `dv7y5u87v87r8` (`grp = :b1`), `btx5wy5zh00v4` (IN-подзапрос, unnesting в HASH JOIN).
- Ctrl+C в тестах эмулировать через perl: `$SIG{INT}="DEFAULT"; setpgrp(0,0); exec`, затем `kill -INT -- -pid`. Фоновый процесс неинтерактивного bash игнорирует SIGINT, и `kill -INT` ему ничего не сделает.

## Не проверено

- 19c **CDB** с `-p <PDB>`: сброс `dbms_output` в PDB воспроизведён только на 23ai. Фикс от этого не зависит, но прогнать `./sqltrace.sh -n -s <sql_id> -p <PDB>` на 19c CDB.
- RAC не поддерживается.
