# Custom Data Types and RDB Serialization

Use when implementing a custom data type with RDB persistence, AOF rewrite callbacks, or working with ValkeyModuleTypeMethods.

Standard module custom type API - `ValkeyModule_CreateDataType()` with 9-char name, encoding version 0-1023, and `ValkeyModuleTypeMethods` struct (currently version 5). RDB load/save, AOF rewrite, free, mem_usage, copy, defrag, unlink, and auxiliary data callbacks. Standard RDB serialization primitives (SaveUnsigned/LoadUnsigned, etc.).

Source: `src/valkeymodule.h`, `src/module.c`
