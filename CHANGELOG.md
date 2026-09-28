# Changelog

Each module is versioned and released on its own; entries are grouped by module. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## TermHarness.KeySpec

### Unreleased

- First release, factored out of [cstrahan/windows-setup](https://github.com/cstrahan/windows-setup)
  (`tools/KeySpec`). Key and mouse events now carry the type names `TermHarness.KeyEvent` and
  `TermHarness.MouseEvent`.

## TermHarness.Console

### Unreleased

- First release, factored out of `tools/ConsoleHarness` in windows-setup. Renamed from
  `ConsoleHarness`; session objects are typed `TermHarness.ConsoleSession`, and session records live
  under `termharness-console` in the temp folder. Depends on `TermHarness.KeySpec` through the
  manifest rather than a relative import. Refuses to import off Windows with a message that says so.

## TermHarness.Pty

### Unreleased

- First release, factored out of `tools/PtyHarness` in windows-setup. Renamed from `PtyHarness`;
  session objects are typed `TermHarness.PtySession`, the override variable is
  `TERMHARNESS_CONPTY_DLL`, and session records live under `termharness-pty` in the temp folder.
- The C# interop is now compiled once into `TermHarness.Pty.Native.dll` (a .NET 8 project) instead
  of being compiled by `Add-Type` on every import, and the module ships wasmtime and the
  redistributable console host under `lib/runtimes/<rid>/native` rather than fetching them.
- Runs on Linux and macOS as well: the program is started as a session leader on a Unix pty with
  posix_spawn, and its bytes feed the emulator directly, with no console host in between.
- Requires PowerShell 7.4 or later.
