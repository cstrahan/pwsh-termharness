# PSScriptAnalyzer settings for build.ps1 -Task Lint and CI. Warnings fail the build, so every rule
# switched off here is a decision, not an oversight.
@{
    Severity     = @('Error', 'Warning')
    IncludeRules = @('*')
    ExcludeRules = @(
        # These are test-harness commands: Start-ConsoleApp, Stop-PtyApp and Set-ConsoleSize act on
        # a program the caller started for the purpose. -WhatIf and -Confirm would be noise on every
        # call, and nothing here touches state a user would want to preview.
        'PSUseShouldProcessForStateChangingFunctions',
        # Send-ConsoleKeys and Send-PtyKeys send several keys at once, and "keys" is the vocabulary
        # of the syntax they take (AutoHotkey's Send, .NET's SendKeys). Send-PtyBytes likewise.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }
        PSAvoidUsingCmdletAliases = @{
            # None allowed; listed so the intent is visible.
            AllowList = @()
        }
    }
}
