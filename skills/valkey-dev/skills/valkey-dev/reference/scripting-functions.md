# Functions Subsystem

Use when investigating FUNCTION LOAD/CALL/DELETE/LIST/STATS/DUMP/RESTORE, function libraries, the FCALL command, or how functions differ from EVAL scripts.

Standard Functions subsystem, same as Redis 7.0+. No Valkey-specific changes.

Source: `src/functions.c`, `src/functions.h`, `src/script.c`. Named persistent libraries with `#!lua name=mylib` shebang. Persisted to RDB (`RDB_OPCODE_FUNCTION2`). FUNCTION DUMP/RESTORE supports FLUSH/APPEND/REPLACE policies. Effects-based replication (individual writes replicated, not FCALL itself).
