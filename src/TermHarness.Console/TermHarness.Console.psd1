@{
    RootModule        = 'TermHarness.Console.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'fc0c7477-133a-4c5a-abcc-cf478f86b459'
    Author            = 'Charles Strahan'
    CompanyName       = 'Charles Strahan'
    Copyright         = '(c) 2026 Charles Strahan. Licensed under MIT or Apache-2.0, at your option.'
    CompatiblePSEditions = @('Core')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    Description       = 'Drives an interactive Windows console application (fzf, Neovim, a prompt) from a script and reads the screen conhost rendered, so terminal UIs can be tested without a person at the keyboard.'
    PowerShellVersion = '7.0'
    RequiredModules   = @(@{ ModuleName = 'TermHarness.KeySpec'; ModuleVersion = '0.1.0' })
    FunctionsToExport = @('Start-ConsoleApp',
                          'Get-ConsoleApp',
                          'Get-ConsoleScreen',
                          'Get-ConsoleInfo',
                          'Set-ConsoleSize',
                          'Move-ConsoleView',
                          'Send-ConsoleKeys',
                          'Send-ConsoleText',
                          'Wait-ConsoleText',
                          'Stop-ConsoleApp')
    PrivateData = @{
        PSData = @{
            Tags         = @('Terminal', 'Testing', 'TUI', 'Console', 'PSEdition_Core', 'Windows')
            LicenseUri   = 'https://github.com/cstrahan/pwsh-termharness#license'
            ProjectUri   = 'https://github.com/cstrahan/pwsh-termharness'
            ReleaseNotes = 'https://github.com/cstrahan/pwsh-termharness/blob/main/CHANGELOG.md'
            # No prerelease tag: a RequiredModules minimum of 0.1.0 can't be met by 0.1.0-preview1,
            # so the harnesses could not install alongside a prerelease KeySpec. 0.x says unstable.
        }
    }
}