# Where the compiled half of the module lives, and how to load it.
#
# build.ps1 stages the .NET project's output into lib\: the TermHarness.Pty.Native assembly (ConPTY
# interop, the libghostty callback and the cell reader), the Wasmtime binding, and under
# lib\runtimes\<rid>\native the native libraries for each platform the package ships: the wasmtime
# engine, and on Windows the redistributable console host (conpty.dll beside OpenConsole.exe).
#
# Native libraries are loaded by full path before anything references them: a loose assembly has
# no deps.json-driven probing, but a module already in the process resolves by its plain name,
# which is what the bindings' DllImports use.
#
# Dot-sourced by the module and by the host process alike.

$script:PtyLibDirectory = Join-Path $PSScriptRoot 'lib'

function Get-PtyRuntimeIdentifier {
    <#
    .SYNOPSIS
    The .NET runtime identifier of this process, in the form the package's runtimes\ folder uses.
    #>
    # Portable RIDs (win-x64, linux-arm64, osx-arm64) are what .NET 8+ reports here.
    $rid = [Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
    if ($env:TERMHARNESS_RID) { $rid = $env:TERMHARNESS_RID }
    return $rid
}

function Get-PtyNativeDirectory {
    <#
    .SYNOPSIS
    The folder holding this platform's native libraries: lib\runtimes\<rid>\native.
    #>
    return [IO.Path]::Combine($script:PtyLibDirectory, 'runtimes', (Get-PtyRuntimeIdentifier), 'native')
}

function Get-PtyRuntimeFile {
    <#
    .SYNOPSIS
    Lists the files the module needs on this platform, each with whether it is present.
    #>
    $native = Get-PtyNativeDirectory
    $engine = if ($IsWindows) { 'wasmtime.dll' } elseif ($IsMacOS) { 'libwasmtime.dylib' } else { 'libwasmtime.so' }
    $files = [ordered]@{
        Assembly = Join-Path $script:PtyLibDirectory 'TermHarness.Pty.Native.dll'
        Binding  = Join-Path $script:PtyLibDirectory 'Wasmtime.Dotnet.dll'
        Engine   = Join-Path $native $engine
    }
    if ($IsWindows) {
        # Both, or neither: conpty.dll falls back to the inbox conhost without a word when the
        # host isn't beside it (see PtyNative.ps1).
        $files['ConptyLibrary'] = Join-Path $native 'conpty.dll'
        $files['ConsoleHost'] = Join-Path $native 'OpenConsole.exe'
    }
    foreach ($entry in $files.GetEnumerator()) {
        [pscustomobject]@{ Name = $entry.Key; Path = $entry.Value; Present = Test-Path -LiteralPath $entry.Value }
    }
}

function Assert-PtyRuntime {
    <#
    .SYNOPSIS
    Throws a message that says what is missing and how to get it, if the runtime isn't staged.
    #>
    $missing = @(Get-PtyRuntimeFile | Where-Object { -not $_.Present })
    if (-not $missing) { return }
    $list = ($missing | ForEach-Object { "  $($_.Name): $($_.Path)" }) -join "`n"
    throw "TermHarness.Pty is missing its runtime for $(Get-PtyRuntimeIdentifier):`n$list`n" +
        'In a clone of the repository, run build.ps1 -Task Build to stage it. An installed module should have shipped with it; reinstall it.'
}

function Import-PtyNativeAssembly {
    <#
    .SYNOPSIS
    Loads the native engine and the managed assemblies, once per process.
    #>
    if (('TermHarness.Pty.Native' -as [type]) -and ('Wasmtime.Engine' -as [type])) { return }
    Assert-PtyRuntime
    $files = @{}
    foreach ($file in Get-PtyRuntimeFile) { $files[$file.Name] = $file.Path }
    # The engine first, by path: Wasmtime.Dotnet p/invokes 'wasmtime', which then resolves to the
    # module already loaded rather than being searched for.
    [void] [Runtime.InteropServices.NativeLibrary]::Load($files['Engine'])
    Add-Type -Path $files['Binding']
    Add-Type -Path $files['Assembly']
}
