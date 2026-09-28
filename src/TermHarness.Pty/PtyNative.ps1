# Pseudo terminal interop: start a program attached to a pty and get its byte streams.
#
# Two backends, both in the TermHarness.Pty.Native assembly (NativeRuntime.ps1 loads it):
#
# - Windows: ConPTY (PtyNative.cs). Windows' pseudo console (Windows 10 1809+) is what a terminal
#   emulator uses: the program thinks it has a console, and we get the VT stream it draws with,
#   rather than a rendered character grid. That's the whole difference from TermHarness.Console.
#   Which console host serves the pty matters: kernel32's CreatePseudoConsole binds to the
#   machine's own conhost, which on Windows 10 (10.0.19041.1, from 2020) has no mouse plumbing at
#   all. Microsoft ships a current one for exactly this case, as the MIT-licensed
#   Microsoft.Windows.Console.ConPTY package (conpty.dll plus OpenConsole.exe, built from
#   microsoft/terminal). The module ships it under lib\runtimes\win-<arch>\native, and this
#   prefers it. That is also what node-pty does, and so VS Code: it vendors the same two binaries
#   and picks between kernel32 and conpty.dll with a `useConptyDll` flag. Its default is still
#   kernel32, so anything using node-pty as it comes has the same gap.
#
# - Linux and macOS: a Unix pty (UnixPty.cs), with the program spawned as a session leader that
#   owns it. There is no console host in between: the program's bytes are the terminal's input.
#
# Dot-source this; it defines Start-PtyProcess, Resize-PtyProcess and Stop-PtyProcess.

function Get-ConptyLibraryPath {
    <#
    .SYNOPSIS
    Returns the redistributable conpty.dll if it is present and usable, otherwise $null.

    .DESCRIPTION
    conpty.dll looks for OpenConsole.exe next to itself, then in an architecture subdirectory,
    and if it finds neither it falls back to the inbox conhost (winconpty.cpp, _ConsoleHostPath).
    That fallback is silent and would cost us mouse, so both files are required here rather than
    just the library.

    $env:TERMHARNESS_CONPTY_DLL overrides the location.
    #>
    [CmdletBinding()]
    param()

    $library = if ($env:TERMHARNESS_CONPTY_DLL) { $env:TERMHARNESS_CONPTY_DLL } else { Join-Path (Get-PtyNativeDirectory) 'conpty.dll' }
    if (-not (Test-Path -LiteralPath $library)) { return $null }
    # Not $host: that is an automatic variable.
    $consoleHostExe = Join-Path (Split-Path -Parent $library) 'OpenConsole.exe'
    if (-not (Test-Path -LiteralPath $consoleHostExe)) { return $null }
    return $library
}

function Initialize-Conpty {
    <#
    .SYNOPSIS
    Loads conpty.dll so that PtyNative.cs's [DllImport("conpty.dll")] resolves to our copy.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    if ($script:ConptyLoaded) { return }
    # Loading by full path puts the module in the process under its plain name, which is what the
    # bare DllImport then finds; lib\ is on no search path. (NativeRuntime.ps1 loads wasmtime the
    # same way.) Loading the library is also what fixes OpenConsole's directory: conpty.dll
    # resolves the host relative to its own module path, so it finds the one shipped beside it.
    [void] [Runtime.InteropServices.NativeLibrary]::Load($Path)
    $script:ConptyLoaded = $true
}

function Test-UnixPty {
    param($Pty)
    return $Pty.GetType().Name -eq 'UnixPtyProcess'
}

function Start-PtyProcess {
    <#
    .SYNOPSIS
    Starts a command attached to a new pseudo terminal.

    .DESCRIPTION
    On Windows the command line is handed to CreateProcess as it is. Elsewhere /bin/sh runs it,
    as a terminal would, after changing to the working directory.

    .EXAMPLE
    $pty = Start-PtyProcess -CommandLine 'pwsh -NoLogo' -Columns 120 -Rows 30
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CommandLine,
        [string] $WorkingDirectory = $PWD.Path,
        [int] $Columns = 120,
        [int] $Rows = 30,
        # Windows only. Conpty is the redistributable host shipped with the module and handles
        # mouse; Inbox is whatever kernel32's CreatePseudoConsole gives us, which on Windows 10
        # forwards none. Auto takes Conpty when it is present.
        [ValidateSet('Auto', 'Conpty', 'Inbox')] [string] $ConsoleHost = 'Auto'
    )
    Import-PtyNativeAssembly

    if (-not $IsWindows) {
        $pty = [TermHarness.Pty.UnixNative]::Start($CommandLine, $WorkingDirectory, [short] $Columns, [short] $Rows)
        # Reported alongside the Windows host for Get-PtyInfo: here the terminal is ours alone.
        Add-Member -InputObject $pty -NotePropertyName ConsoleHost -NotePropertyValue 'pty' -Force
        return $pty
    }

    $library = if ($ConsoleHost -ne 'Inbox') { Get-ConptyLibraryPath } else { $null }
    if ($ConsoleHost -eq 'Conpty' -and -not $library) {
        throw "conpty.dll and OpenConsole.exe were not found in $(Get-PtyNativeDirectory); the module's runtime is incomplete (see build.ps1 -Task Build)."
    }
    if ($library) { Initialize-Conpty -Path $library }

    $pty = [TermHarness.Pty.Native]::Start($CommandLine, $WorkingDirectory, [short] $Columns, [short] $Rows, [bool] $library)
    $description = if ($library) { $library } else { 'inbox' }
    Add-Member -InputObject $pty -NotePropertyName ConsoleHost -NotePropertyValue $description -Force
    return $pty
}

function Resize-PtyProcess {
    <#
    .SYNOPSIS
    Tells the pseudo terminal its new size, which the program sees as a resize.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty, [Parameter(Mandatory)] [int] $Columns, [Parameter(Mandatory)] [int] $Rows)
    if (Test-UnixPty $Pty) {
        [TermHarness.Pty.UnixNative]::Resize($Pty, [short] $Columns, [short] $Rows)
    } else {
        [TermHarness.Pty.Native]::Resize($Pty, [short] $Columns, [short] $Rows)
    }
}

function Test-PtyProcessExited {
    <#
    .SYNOPSIS
    Whether the program attached to the pseudo terminal has exited.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty)
    if (Test-UnixPty $Pty) { return [TermHarness.Pty.UnixNative]::HasExited($Pty) }
    return [TermHarness.Pty.Native]::HasExited($Pty)
}

function Stop-PtyProcessTree {
    param([int] $Id)
    # Children first, or killing the parent reparents them and they keep running. The program we
    # start is often a shell that then runs the thing under test, so the tree matters.
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)) {
        Stop-PtyProcessTree -Id ([int] $child.ProcessId)
    }
    Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

function Stop-PtyProcess {
    <#
    .SYNOPSIS
    Closes the pseudo terminal and stops the program and everything it started.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty)
    if (Test-UnixPty $Pty) {
        # The Unix side signals the program's whole session itself.
        [TermHarness.Pty.UnixNative]::Stop($Pty)
        return
    }
    if ($Pty.ProcessId) { Stop-PtyProcessTree -Id $Pty.ProcessId }
    [TermHarness.Pty.Native]::Stop($Pty)
}
