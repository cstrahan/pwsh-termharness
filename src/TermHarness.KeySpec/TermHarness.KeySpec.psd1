@{
    RootModule        = 'TermHarness.KeySpec.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7a1ff8e6-09ca-4fb9-b92d-4ab24948909b'
    Author            = 'Charles Strahan'
    CompanyName       = 'Charles Strahan'
    Copyright         = '(c) 2026 Charles Strahan. Licensed under MIT or Apache-2.0, at your option.'
    CompatiblePSEditions = @('Core')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    Description       = 'Parses AutoHotkey-style key and mouse specifications into input events, for harnesses that drive terminal programs.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('ConvertFrom-KeySpec')
    PrivateData = @{
        PSData = @{
            Tags         = @('Terminal', 'Testing', 'TUI', 'Keyboard', 'AutoHotkey', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')
            LicenseUri   = 'https://github.com/cstrahan/pwsh-termharness#license'
            ProjectUri   = 'https://github.com/cstrahan/pwsh-termharness'
            ReleaseNotes = 'https://github.com/cstrahan/pwsh-termharness/blob/main/CHANGELOG.md'
            # No prerelease tag: a RequiredModules minimum of 0.1.0 can't be met by 0.1.0-preview1,
            # so the harnesses could not install alongside a prerelease KeySpec. 0.x says unstable.
        }
    }
}