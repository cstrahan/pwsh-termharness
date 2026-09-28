#!/usr/bin/env pwsh
<#
.SYNOPSIS
Builds, lints, tests and packages the TermHarness modules.

.DESCRIPTION
Plain PowerShell rather than a task runner, so a clone needs nothing but pwsh and the .NET SDK.
Tools the build itself needs (Pester, PSScriptAnalyzer) are saved into .tools\modules by the
Bootstrap task and never installed into the user's module folders.

.EXAMPLE
.\build.ps1                          # Build, Lint, Test
.\build.ps1 -Task Test -Tag KeySpec  # one module's tests
.\build.ps1 -Task Build, Stage, PublishLocal   # rehearse a Gallery publish against a local folder
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read by the task functions below.')]
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Clean', 'Build', 'Lint', 'Test', 'Stage', 'Package', 'PublishLocal', 'Publish', 'All')]
    [string[]] $Task = @('Build', 'Lint', 'Test'),
    # Pester tags to run or exclude (KeySpec, Console, Pty, Manifest, Console-driving tests are
    # tagged 'Interactive' as well).
    [string[]] $Tag,
    [string[]] $ExcludeTag,
    # Native runtimes to stage into TermHarness.Pty: this machine's by default. A release stages
    # every platform the package supports (see release.yml).
    [string[]] $Runtime = @([Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier),
    # Publish: the PowerShell Gallery API key (or set $env:PSGALLERY_API_KEY).
    [string] $ApiKey = $env:PSGALLERY_API_KEY,
    # Publish: which modules, in dependency order. Default: all of them.
    [string[]] $Module = @('TermHarness.KeySpec', 'TermHarness.Console', 'TermHarness.Pty'),
    [ValidateSet('Normal', 'Detailed', 'Diagnostic', 'Minimal', 'None')]
    [string] $Verbosity = 'Normal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Source = Join-Path $Root 'src'
$Out = Join-Path $Root 'out'
$Tools = Join-Path $Root '.tools' 'modules'
$NativeProject = Join-Path $Source 'TermHarness.Pty.Native' 'TermHarness.Pty.Native.csproj'
$NativeOutput = Join-Path $Source 'TermHarness.Pty.Native' 'bin' 'Release' 'net8.0'
$PtyLib = Join-Path $Source 'TermHarness.Pty' 'lib'
$Modules = @('TermHarness.KeySpec', 'TermHarness.Console', 'TermHarness.Pty')
# Pinned so that a run here and a run in CI lint and test with the same tools.
$ToolVersions = @{ Pester = '6.2.0'; PSScriptAnalyzer = '1.25.0' }

function Write-Step([string] $Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Invoke-Bootstrap {
    Write-Step 'Bootstrap: build tools into .tools\modules'
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    foreach ($entry in $ToolVersions.GetEnumerator()) {
        $installed = Join-Path $Tools $entry.Key $entry.Value
        if (Test-Path -LiteralPath $installed) { continue }
        Write-Host "  saving $($entry.Key) $($entry.Value)"
        Save-PSResource -Name $entry.Key -Version $entry.Value -Path $Tools -TrustRepository -Quiet
    }
}

function Use-Tools {
    if (-not (Test-Path -LiteralPath $Tools)) { Invoke-Bootstrap }
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $Tools) {
        $env:PSModulePath = $Tools + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    # The modules under test resolve each other (RequiredModules) through the source tree.
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $Source) {
        $env:PSModulePath = $Source + [IO.Path]::PathSeparator + $env:PSModulePath
    }
}

function Invoke-Clean {
    Write-Step 'Clean'
    foreach ($path in $Out, $PtyLib, (Join-Path $Source 'TermHarness.Pty.Native' 'bin'), (Join-Path $Source 'TermHarness.Pty.Native' 'obj')) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}

function Invoke-Build {
    Write-Step 'Build: TermHarness.Pty.Native'
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'the .NET SDK (8.0 or later) is needed to build TermHarness.Pty.Native: https://dotnet.microsoft.com/download'
    }
    & dotnet build $NativeProject -c Release --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed with exit code $LASTEXITCODE" }

    Write-Step "Stage the runtime into TermHarness.Pty\lib ($($Runtime -join ', '))"
    if (Test-Path -LiteralPath $PtyLib) { Remove-Item -LiteralPath $PtyLib -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $PtyLib | Out-Null
    foreach ($file in 'TermHarness.Pty.Native.dll', 'Wasmtime.Dotnet.dll') {
        Copy-Item -LiteralPath (Join-Path $NativeOutput $file) -Destination $PtyLib
    }
    foreach ($rid in $Runtime) {
        $from = Join-Path $NativeOutput 'runtimes' $rid 'native'
        if (-not (Test-Path -LiteralPath $from)) { throw "the Wasmtime package has no native runtime for '$rid'" }
        $to = Join-Path $PtyLib 'runtimes' $rid 'native'
        New-Item -ItemType Directory -Force -Path $to | Out-Null
        Copy-Item -Path (Join-Path $from '*') -Destination $to
        # conpty.dll looks for OpenConsole.exe beside itself; the package puts the host under
        # <arch>\ instead, so move it next to the library it serves.
        if ($rid -like 'win-*') {
            $arch = $rid.Substring(4)
            $consoleHost = Join-Path $NativeOutput $arch 'OpenConsole.exe'
            if (Test-Path -LiteralPath $consoleHost) {
                Copy-Item -LiteralPath $consoleHost -Destination $to
            } elseif (Test-Path -LiteralPath (Join-Path $to 'conpty.dll')) {
                # Ship neither rather than a library that silently falls back to the inbox host.
                Remove-Item -LiteralPath (Join-Path $to 'conpty.dll')
                Write-Warning "no OpenConsole.exe for $rid in the ConPTY package; that runtime gets the inbox console host"
            }
        }
    }
    Get-ChildItem -LiteralPath $PtyLib -Recurse -File | ForEach-Object {
        '  {0,10:n0}  {1}' -f $_.Length, $_.FullName.Substring($PtyLib.Length + 1)
    }
}

function Invoke-Lint {
    Use-Tools
    Write-Step "Lint: PSScriptAnalyzer $($ToolVersions.PSScriptAnalyzer)"
    Import-Module PSScriptAnalyzer -RequiredVersion $ToolVersions.PSScriptAnalyzer
    $settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
    $paths = @($Source, (Join-Path $Root 'tests'), (Join-Path $Root 'build.ps1'))
    $findings = @(foreach ($path in $paths) { Invoke-ScriptAnalyzer -Path $path -Recurse -Settings $settings })
    # build.ps1 talks to a person, so Write-Host is right there and nowhere else.
    $findings = @($findings | Where-Object { -not ($_.RuleName -eq 'PSAvoidUsingWriteHost' -and $_.ScriptName -eq 'build.ps1') })
    if ($findings) {
        $findings | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String -Width 200 | Write-Host
        throw "PSScriptAnalyzer reported $($findings.Count) finding(s)"
    }
    Write-Host '  clean'
}

function Invoke-Test {
    Use-Tools
    Write-Step "Test: Pester $($ToolVersions.Pester)"
    Import-Module Pester -RequiredVersion $ToolVersions.Pester
    $results = Join-Path $Out 'test-results'
    New-Item -ItemType Directory -Force -Path $results | Out-Null
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $Root 'tests'
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Output.Verbosity = $Verbosity
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = Join-Path $results 'pester.xml'
    if ($Tag) { $configuration.Filter.Tag = $Tag }
    if ($ExcludeTag) { $configuration.Filter.ExcludeTag = $ExcludeTag }
    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) test(s) failed" }
    if ($result.TotalCount -eq 0) { throw 'no tests ran' }
}

function Get-ModuleVersionString([string] $Name) {
    $manifest = Import-PowerShellDataFile (Join-Path $Source $Name "$Name.psd1")
    $version = $manifest.ModuleVersion
    # Indexed, not dotted: under strict mode a missing Prerelease key would throw.
    $prerelease = $manifest.PrivateData.PSData['Prerelease']
    if ($prerelease) { "$version-$prerelease" } else { $version }
}

function Invoke-Stage {
    Write-Step 'Stage: out\modules'
    $staged = Join-Path $Out 'modules'
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
    # Test-ModuleManifest resolves RequiredModules, so the staged tree has to be on the path.
    $env:PSModulePath = $staged + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($name in $Modules) {
        $to = Join-Path $staged $name
        Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $to -Recurse
        # Nothing a user needs: build leftovers and editor files.
        Get-ChildItem -LiteralPath $to -Recurse -Include '*.pdb', '*.deps.json' | Remove-Item -Force
        if ($name -eq 'TermHarness.Pty' -and -not (Test-Path -LiteralPath (Join-Path $to 'lib' 'TermHarness.Pty.Native.dll'))) {
            throw 'TermHarness.Pty has no staged runtime; run the Build task first'
        }
        $manifest = Test-ModuleManifest -Path (Join-Path $to "$name.psd1")
        Write-Host "  $name $(Get-ModuleVersionString $name): $($manifest.ExportedFunctions.Count) functions"
    }
}

function Invoke-Package {
    Write-Step 'Package: out\*.zip'
    $staged = Join-Path $Out 'modules'
    if (-not (Test-Path -LiteralPath $staged)) { Invoke-Stage }
    foreach ($name in $Modules) {
        $zip = Join-Path $Out "$name-$(Get-ModuleVersionString $name).zip"
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
        Compress-Archive -Path (Join-Path $staged $name) -DestinationPath $zip
        Write-Host "  $(Split-Path -Leaf $zip)"
    }
}

function Publish-Staged([string] $Repository, [string] $Key) {
    $staged = Join-Path $Out 'modules'
    if (-not (Test-Path -LiteralPath $staged)) { Invoke-Stage }
    foreach ($name in $Module) {
        Write-Host "  publishing $name $(Get-ModuleVersionString $name) to $Repository"
        $arguments = @{ Path = (Join-Path $staged $name); Repository = $Repository }
        if ($Key) { $arguments['ApiKey'] = $Key }
        Publish-PSResource @arguments
    }
}

function Invoke-PublishLocal {
    # A rehearsal: publish to a folder repository, install from it into a clean path, import the
    # result. This catches manifest and dependency mistakes that only surface at publish time.
    Write-Step 'PublishLocal: out\repo, then install into out\install'
    $repo = Join-Path $Out 'repo'
    $install = Join-Path $Out 'install'
    foreach ($path in $repo, $install) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    $repositoryName = 'TermHarnessLocal'
    if (Get-PSResourceRepository -Name $repositoryName -ErrorAction SilentlyContinue) {
        Unregister-PSResourceRepository -Name $repositoryName
    }
    Register-PSResourceRepository -Name $repositoryName -Uri $repo -Trusted
    try {
        Publish-Staged -Repository $repositoryName
        foreach ($name in $Module) {
            Write-Host "  installing $name from the local repository"
            Save-PSResource -Name $name -Version "[$(Get-ModuleVersionString $name)]" -Prerelease -Repository $repositoryName -Path $install -TrustRepository -Quiet
        }
        Write-Host '  importing the installed modules in a fresh process'
        $script = @"
`$env:PSModulePath = '$install' + [IO.Path]::PathSeparator + `$env:PSModulePath
foreach (`$name in '$($Module -join "','")') {
    `$module = Import-Module `$name -PassThru -ErrorAction Stop
    '  {0} {1}: {2} commands' -f `$module.Name, `$module.Version, `$module.ExportedCommands.Count
}
"@
        & pwsh -NoProfile -NonInteractive -Command $script
        if ($LASTEXITCODE -ne 0) { throw 'importing the installed modules failed' }
    } finally {
        Unregister-PSResourceRepository -Name $repositoryName
    }
}

function Invoke-Publish {
    Write-Step 'Publish: PowerShell Gallery'
    if (-not $ApiKey) { throw 'pass -ApiKey or set $env:PSGALLERY_API_KEY' }
    Publish-Staged -Repository 'PSGallery' -Key $ApiKey
}

if ($Task -contains 'All') { $Task = @('Clean', 'Build', 'Lint', 'Test', 'Stage', 'Package') }
foreach ($step in $Task) {
    switch ($step) {
        'Bootstrap' { Invoke-Bootstrap }
        'Clean' { Invoke-Clean }
        'Build' { Invoke-Build }
        'Lint' { Invoke-Lint }
        'Test' { Invoke-Test }
        'Stage' { Invoke-Stage }
        'Package' { Invoke-Package }
        'PublishLocal' { Invoke-PublishLocal }
        'Publish' { Invoke-Publish }
    }
}
Write-Host 'Done.' -ForegroundColor Green
