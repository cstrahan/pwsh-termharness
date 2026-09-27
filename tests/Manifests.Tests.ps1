# Variables set in BeforeAll are read in the It blocks below, which the analyzer can't follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping: BeforeAll sets what It reads.')]
param()
# Checks every module can make before a program is started: the manifests are valid, what they
# export exists and is documented, and the Windows-only modules say so on other platforms.

BeforeDiscovery {
    $script:ModuleNames = @('TermHarness.KeySpec', 'TermHarness.Console', 'TermHarness.Pty')
}

BeforeAll {
    $script:Source = Join-Path $PSScriptRoot '..' 'src'

    function Get-ModuleAst([string] $Name) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Source $Name "$Name.psm1"), [ref] $tokens, [ref] $errors)
        if ($errors) { throw "parse errors in $Name.psm1: $($errors -join '; ')" }
        return $ast
    }
}

Describe 'Module <_>' -Tag Manifest -ForEach $ModuleNames {
    BeforeAll {
        $name = $_
        $manifestPath = Join-Path $Source $name "$name.psd1"
        $manifest = Import-PowerShellDataFile $manifestPath
        $ast = Get-ModuleAst $name
        $functions = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
    }

    It 'has a valid manifest' {
        # Test-ModuleManifest resolves RequiredModules, so the source tree has to be on the path.
        $env:PSModulePath = $Source + [IO.Path]::PathSeparator + $env:PSModulePath
        { Test-ModuleManifest -Path $manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'carries the gallery metadata' {
        $manifest.Description | Should -Not -BeNullOrEmpty
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
        $manifest.PrivateData.PSData.ProjectUri | Should -BeLike 'https://github.com/cstrahan/pwsh-termharness*'
        $manifest.PrivateData.PSData.LicenseUri | Should -Not -BeNullOrEmpty
        $manifest.PrivateData.PSData.Tags | Should -Contain 'PSEdition_Core'
    }

    It 'lists every exported function explicitly' {
        $manifest.FunctionsToExport | Should -Not -Contain '*'
        $manifest.FunctionsToExport.Count | Should -BeGreaterThan 0
    }

    It 'defines each exported function in its root module' {
        foreach ($exported in $manifest.FunctionsToExport) {
            $functions.Name | Should -Contain $exported
        }
    }

    It 'exports the same set from Export-ModuleMember' {
        $exportCall = $ast.FindAll({
            $args[0] -is [Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Export-ModuleMember'
        }, $false)
        $exportCall.Count | Should -Be 1
        $named = @($exportCall[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] } |
            ForEach-Object { $_.Value } | Where-Object { $_ -ne 'Export-ModuleMember' })
        # Comma-separated arguments arrive as one array expression.
        if (-not $named) {
            $named = @($exportCall[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.ArrayLiteralAst] } |
                ForEach-Object { $_.Elements } | ForEach-Object { $_.Value })
        }
        ($named | Sort-Object) | Should -Be ($manifest.FunctionsToExport | Sort-Object)
    }

    It 'documents each exported function with a synopsis' {
        foreach ($exported in $manifest.FunctionsToExport) {
            $function = $functions | Where-Object Name -eq $exported
            $help = $function.GetHelpContent()
            $help | Should -Not -BeNullOrEmpty -Because "$exported needs comment-based help"
            $help.Synopsis.Trim() | Should -Not -BeNullOrEmpty -Because "$exported needs a .SYNOPSIS"
        }
    }

    It 'uses approved verbs' {
        $verbs = (Get-Verb).Verb
        foreach ($function in $functions) {
            $verb = ($function.Name -split '-', 2)[0]
            $verbs | Should -Contain $verb -Because "$($function.Name) should start with an approved verb"
        }
    }
}

Describe 'Dependencies' -Tag Manifest {
    It 'makes the harnesses depend on TermHarness.KeySpec' {
        foreach ($name in 'TermHarness.Console', 'TermHarness.Pty') {
            $manifest = Import-PowerShellDataFile (Join-Path $Source $name "$name.psd1")
            @($manifest.RequiredModules | ForEach-Object { $_.ModuleName }) | Should -Contain 'TermHarness.KeySpec'
        }
    }

    It 'keeps TermHarness.KeySpec free of dependencies' {
        $manifest = Import-PowerShellDataFile (Join-Path $Source 'TermHarness.KeySpec' 'TermHarness.KeySpec.psd1')
        $manifest.ContainsKey('RequiredModules') | Should -BeFalse
    }
}

Describe 'Platform guards' -Tag Manifest {
    It 'imports TermHarness.KeySpec anywhere' {
        $module = Import-Module (Join-Path $Source 'TermHarness.KeySpec' 'TermHarness.KeySpec.psd1') -Force -PassThru
        $module.ExportedFunctions.Keys | Should -Contain 'ConvertFrom-KeySpec'
    }

    It 'refuses to import <_> off Windows, and says why' -Skip:$IsWindows -ForEach @('TermHarness.Console', 'TermHarness.Pty') {
        $env:PSModulePath = $Source + [IO.Path]::PathSeparator + $env:PSModulePath
        { Import-Module (Join-Path $Source $_ "$_.psd1") -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage '*Windows*'
    }
}
