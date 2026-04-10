# Key Access API and Blocking Commands

Use when working with the low-level key access API (OpenKey/CloseKey) or building blocking commands with ValkeyModule_BlockClient.

Standard module key API - `ValkeyModule_OpenKey()` with READ/WRITE/NOTOUCH/NONOTIFY/NOSTATS/NOEXPIRE/NOEFFECTS flags, `ValkeyModule_BlockClient()` for blocking commands, `ValkeyModule_BlockClientOnKeys()` for key-waiting, thread-safe contexts via `ValkeyModule_GetThreadSafeContext()`.

Source: `src/valkeymodule.h`, `src/module.c`
