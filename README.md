# TermHarness

PowerShell modules for driving interactive terminal programs from a script and reading back what
they drew, so that terminal UIs (fuzzy finders, editors, prompts) can be tested without a person at
the keyboard.

| Module | What it does | Platforms |
|---|---|---|
| [TermHarness.KeySpec](src/TermHarness.KeySpec/README.md) | Parses keystrokes and mouse actions written in [AutoHotkey's `Send` syntax](https://www.autohotkey.com/docs/v2/lib/Send.htm) (`'find{Enter}'`, `'^s'`, `'{Click 40 10}'`) into input events. | Windows, Linux, macOS |
| [TermHarness.Console](src/TermHarness.Console/README.md) | Runs a program in a hidden Windows console, injects keys and mouse, and reads the character grid conhost rendered. No dependencies beyond Win32. | Windows |
| [TermHarness.Pty](src/TermHarness.Pty/README.md) | Runs a program under a pseudo console and renders its output with [libghostty-vt](https://github.com/ghostty-org/ghostty), a real terminal emulator: colours, attributes, scrollback and reflow, read back as text, VT, HTML or styled runs. | Windows, Linux, macOS |

```powershell
Install-PSResource TermHarness.Console      # brings TermHarness.KeySpec with it

$session = Start-ConsoleApp -Command 'fzf' -WorkingDirectory C:\repo
try {
    Wait-ConsoleText $session '> '                      # poll for the prompt, don't sleep
    Send-ConsoleKeys $session 'readme'                  # type
    $screen = Send-ConsoleKeys $session '^s'            # Ctrl+S; returns the redrawn screen
    $screen -match 'README.md' | Should -Not -BeNullOrEmpty
} finally {
    Stop-ConsoleApp $session                            # always, even after a failure
}
```

```powershell
Install-PSResource TermHarness.Pty

$session = Start-PtyApp -CommandLine 'nvim README.md' -Columns 120 -Rows 30
try {
    Wait-PtyText $session 'README'
    Send-PtyKeys $session 'G'
    (Find-PtyText $session 'error' -WithStyle).Runs[0].EffectiveForeground.Hex   # -> #cc6666
    Get-PtyScreen $session -As Html | Set-Content screen.html
} finally {
    Stop-PtyApp $session
}
```

## Which harness

| | TermHarness.Console | TermHarness.Pty |
|---|---|---|
| How the screen is read | conhost renders it; the harness reads the character grid | the harness renders the VT stream itself |
| Dependencies | none | wasmtime, shipped with the module (about 22 MB per platform), plus a console host on Windows |
| Colours and attributes | no | yes |
| Mouse | console records or SGR, chosen per application | SGR; on Windows the console host adapts |
| Scrollback and reflow | conhost's | a real terminal's |
| Works on a bare machine | yes | yes, once installed |

Reach for the console harness when the thing under test runs in a Windows console and text is
enough. Reach for the pty harness when colours, reflow or genuine terminal semantics matter, when
you would rather not care which mouse delivery an application wants, or when the program runs on
Linux or macOS.

## Requirements

PowerShell 7.0 or later for `TermHarness.KeySpec` and `TermHarness.Console`; 7.4 or later for
`TermHarness.Pty` (its compiled part targets .NET 8). Windows PowerShell 5.1 is not supported.

## Building from source

```powershell
git clone https://github.com/cstrahan/pwsh-termharness
cd pwsh-termharness
./build.ps1                       # Build (needs the .NET 8+ SDK), Lint, Test
./build.ps1 -Task Test -Tag KeySpec
./build.ps1 -Task Stage, Package  # module trees and zips under out\
```

`build.ps1 -Task Bootstrap` saves Pester and PSScriptAnalyzer into `.tools\modules`; nothing is
installed into your own module folders. The console and pty tests drive real programs and need
`fzf` on `PATH`; they are skipped, visibly, when it isn't there or the platform can't run them.
`-Runtime` picks which native runtimes are staged (this machine's by default; a release ships
`win-x64`, `linux-x64` and `osx-arm64`).

Layout:

- `src/<Module>/`: one folder per module, each with its manifest, README and tests tags.
- `src/TermHarness.Pty.Native/`: the C# half of the pty harness (ConPTY and Unix pty interop, the
  libghostty callback and cell reader). Building it pulls the Wasmtime and ConPTY packages, and
  `build.ps1` stages their native libraries into `src/TermHarness.Pty/lib/` (git-ignored).
- `src/TermHarness.Pty/vendor/`: libghostty-vt as WebAssembly, with its signature and the reason
  it is vendored rather than fetched.
- `tests/`: Pester tests, tagged `KeySpec`, `Console`, `Pty`, `Manifest`; the ones that start
  programs are also tagged `Interactive`.

## Releasing

Push a tag named `<Module>/v<version>` that matches the module's manifest, for example
`TermHarness.KeySpec/v0.1.0`. The release workflow builds, tests, publishes that module
to the PowerShell Gallery, and attaches the zip to a GitHub release with a provenance attestation.
`build.ps1 -Task PublishLocal` rehearses the publish against a folder repository first.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <https://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in
the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.

Bundled third-party components keep their own licences; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
