@{
    RootModule        = 'TermHarness.Pty.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8800c1ad-f1e6-4a94-a3d9-3b4e3a2a1b40'
    Author            = 'Charles Strahan'
    CompanyName       = 'Charles Strahan'
    Copyright         = '(c) 2026 Charles Strahan. Licensed under MIT or Apache-2.0, at your option.'
    CompatiblePSEditions = @('Core')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    Description       = 'Drives an interactive program through a pseudo console and renders its output with libghostty-vt, so a test can read the screen with its colours, scrollback and reflow, and send keys and mouse events.'
    PowerShellVersion = '7.4'
    RequiredModules   = @(@{ ModuleName = 'TermHarness.KeySpec'; ModuleVersion = '0.1.0' })
    FunctionsToExport = @('Start-PtyApp',
                          'Get-PtyApp',
                          'Get-PtyScreen',
                          'Get-PtyStyleAt',
                          'Find-PtyText',
                          'Get-PtyInfo',
                          'Send-PtyKeys',
                          'Send-PtyText',
                          'Send-PtyBytes',
                          'Wait-PtyText',
                          'Set-PtySize',
                          'Stop-PtyApp')
    PrivateData = @{
        PSData = @{
            Tags         = @('Terminal', 'Testing', 'TUI', 'ConPTY', 'Pty', 'PSEdition_Core', 'Windows')
            LicenseUri   = 'https://github.com/cstrahan/pwsh-termharness#license'
            ProjectUri   = 'https://github.com/cstrahan/pwsh-termharness'
            ReleaseNotes = 'https://github.com/cstrahan/pwsh-termharness/blob/main/CHANGELOG.md'
            # No prerelease tag: a RequiredModules minimum of 0.1.0 can't be met by 0.1.0-preview1,
            # so the harnesses could not install alongside a prerelease KeySpec. 0.x says unstable.
        }
    }
}