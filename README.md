# sqltrace

`sqltrace.sh` — bash-обёртка для диагностики одного SQL в Oracle 19c (single instance):

- **10046** (`sql_trace` с waits, binds, `plan_stat=all_executions`) для одного `sql_id` на весь инстанс (event) или для одной сессии (`dbms_monitor`);
- **tkprof** по собранным трейсам и сводка по `sql_id` (`10046/SUMMARY.txt`);
- **10053** через `DBMS_SQLDIAG.DUMP_TRACE` и выжимка из него: финальный запрос после трансформаций, peeked binds, план, outline (`10053/SUMMARY.txt`).

## Требования

Запуск на сервере БД от владельца `ORACLE_HOME`: нужны `sqlplus / as sysdba`, `ORACLE_HOME` и `ORACLE_SID` в окружении, Bash >= 4.2.

## Использование

```bash
# event на весь инстанс, 60 с (по умолчанию), курсор в PDB определяется сам
./sqltrace.sh -s <sql_id>

# одна сессия
./sqltrace.sh -S <sid>,<serial#> -s <sql_id> -d 120

# только 10053
./sqltrace.sh -n -s <sql_id> -c <child> -p <PDB>

# свои опции tkprof
./sqltrace.sh -s <sql_id> -- sort=fchela sys=yes
```

`./sqltrace.sh -h` выводит все опции.

## Защита для прода

- Порог частоты выполнений для event-режима (`-r`, по умолчанию 200 exec/s): выше него скрипт откажется включать трейс без `-f`.
- Проверка свободного места в `Diag Trace` (не меньше 2 GB).
- Трейс выключается по Ctrl+C, TERM и HUP. Если скрипт убит через `kill -9` или OOM, фоновый сторож выключит трейс сам через `-d` + 120 с.

Подробный разбор багов исходной версии и результаты прогона на 19c и 23ai: [REVIEW.md](REVIEW.md).
