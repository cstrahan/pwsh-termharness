# Tests for TermHarness.Pty. These start real programs under a pseudo console, so they need
# Windows and the staged runtime (build.ps1 -Task Build), and take a few seconds. The mouse ones
# also need fzf on PATH.

BeforeDiscovery {
    $script:RuntimeStaged = Test-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'src' 'TermHarness.Pty' 'lib' 'TermHarness.Pty.Native.dll')
    $script:CanRun = [bool] $IsWindows -and $RuntimeStaged
    $script:HasFzf = [bool] (Get-Command fzf -ErrorAction SilentlyContinue)
}

Describe 'TermHarness.Pty' -Tag Pty, Interactive -Skip:(-not $CanRun) {
    BeforeAll {
        $source = Join-Path $PSScriptRoot '..' 'src'
        $env:PSModulePath = $source + [IO.Path]::PathSeparator + $env:PSModulePath
        $script:ModulePath = Join-Path $source 'TermHarness.Pty' 'TermHarness.Pty.psd1'
        Import-Module $ModulePath -Force
        $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
        $script:ColourProbe = Join-Path $Fixtures 'ColourProbe.ps1'

        function Use-Pty([string] $CommandLine, [int] $Columns, [int] $Rows, [string] $Ready, [scriptblock] $Body) {
            $session = Start-PtyApp -CommandLine $CommandLine -WorkingDirectory $Fixtures -Columns $Columns -Rows $Rows
            try {
                Wait-PtyText $session $Ready -TimeoutSeconds 30 | Out-Null
                & $Body $session
            } finally { Stop-PtyApp $session }
        }

        # The preview is drawn in pieces, so match a complete SEL="item N" rather than the bare
        # label: 'SEL=' can be on screen a frame before its value is.
        function Get-Selection($Session) {
            $line = Get-PtyScreen $Session | Where-Object { $_ -match 'SEL="item \d+"' } | Select-Object -First 1
            if ($line -match 'SEL="(item \d+)"') { return $Matches[1] }
            return ''
        }

        # Waits for a fully drawn selection that differs from $Previous. Waiting for a change
        # rather than for the expected value keeps the assertion meaningful.
        function Wait-Selection($Session, [string] $Previous = '', [int] $TimeoutSeconds = 10) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            do {
                $selection = Get-Selection $Session
                if ($selection -and $selection -ne $Previous) { return $selection }
                Start-Sleep -Milliseconds 150
            } while ((Get-Date) -lt $deadline)
            throw "the selection stayed at '$Previous' for ${TimeoutSeconds}s"
        }
    }

    Context 'a program under a pseudo console' {
        It 'runs, takes keys, and has its output rendered' {
            Use-Pty 'cmd.exe' 80 24 'Microsoft Windows' {
                param($session)
                Send-PtyKeys $session 'echo pty-harness-works{Enter}' -SettleMilliseconds 700 | Out-Null
                @(Get-PtyScreen $session -NonEmpty) -match '^pty-harness-works' | Should -Not -BeNullOrEmpty
            }
        }

        It 'is served by the redistributable console host' {
            Use-Pty 'cmd.exe' 80 24 'Microsoft Windows' {
                param($session)
                (Get-PtyInfo $session).consoleHost | Should -Match 'conpty\.dll$'
                # Say that we asked for it and believe what actually happened: conpty.dll falls
                # back to the machine's conhost without a word when OpenConsole.exe isn't beside
                # it, and that fallback costs mouse. The host is a child of the session's host.
                $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($session.HostProcessId)")
                ($children | ForEach-Object { $_.Name }) -join ', ' | Should -Match 'OpenConsole\.exe'
            }
        }

        It 'tells the program about a resize, which redraws for the new size' {
            Use-Pty 'cmd.exe' 80 24 'Microsoft Windows' {
                param($session)
                $state = Set-PtySize $session -Columns 60 -Rows 20 -SettleMilliseconds 500
                $state.columns | Should -Be 60
                $state.rows | Should -Be 20
                # Ask the program itself what size it thinks it has.
                Send-PtyKeys $session 'mode con{Enter}' -SettleMilliseconds 800 | Out-Null
                $line = Get-PtyScreen $session -NonEmpty | Where-Object { $_ -match 'Columns:\s+(\d+)' } | Select-Object -First 1
                $line | Should -Match 'Columns:\s+60'
            }
        }

        It 'answers what a program asks the terminal' {
            # Without this, a program that queries the terminal waits for a reply that never
            # comes, and the query itself can end up drawn on the screen (Neovim's XTGETTCAP did).
            $probe = Join-Path $Fixtures 'QueryProbe.ps1'
            Use-Pty "pwsh -NoProfile -File `"$probe`"" 80 24 'ANSWER:' {
                param($session)
                $line = Get-PtyScreen $session -NonEmpty | Where-Object { $_ -match 'ANSWER:' } | Select-Object -First 1
                # A primary device attributes reply: ESC [ ? ... c
                $line | Should -Match 'ANSWER:<ESC>\[\?[0-9;]+c:END'
            }
        }
    }

    Context 'the viewport and the scrollback' {
        It 'gives the viewport by default, and everything with -Scrollback' {
            # More output than fits, so some of it has scrolled off.
            Use-Pty 'cmd.exe' 80 10 'Microsoft Windows' {
                param($session)
                Send-PtyKeys $session 'for /L %i in (1,1,30) do @echo line %i{Enter}' -SettleMilliseconds 1200 | Out-Null
                $visible = @(Get-PtyScreen $session -NonEmpty)
                $everything = @(Get-PtyScreen $session -Scrollback -NonEmpty)
                $visible.Count | Should -BeLessOrEqual 10 -Because 'the viewport should fit the terminal'
                $everything.Count | Should -BeGreaterThan $visible.Count -Because 'scrollback should hold more than the viewport'
                $everything -match '^line 1$' | Should -Not -BeNullOrEmpty -Because 'the first line should still be in scrollback'
                $visible -match '^line 1$' | Should -BeNullOrEmpty -Because 'it should have scrolled out of view'
                $visible -match '^line 30$' | Should -Not -BeNullOrEmpty -Because 'the last line should be visible'
            }
        }

        It 'keeps every form of the screen to the viewport' {
            # libghostty's formatter emits history and viewport together, so Vt and Html would
            # carry the whole scrollback if nothing trimmed them.
            Use-Pty 'cmd.exe' 80 10 'Microsoft Windows' {
                param($session)
                Send-PtyKeys $session 'for /L %i in (1,1,30) do @echo line %i{Enter}' -SettleMilliseconds 1200 | Out-Null
                foreach ($form in 'Vt', 'Html') {
                    $screen = Get-PtyScreen $session -As $form
                    $screen | Should -Match 'line 30' -Because "-As $form should show the last line"
                    $screen | Should -Not -Match 'line 1\D' -Because "-As $form should not carry the scrollback"
                }
                @(Get-PtyScreen $session -As Styled).Count | Should -Be 10 -Because 'one entry per viewport row'
                # And Vt keeps the history when it is asked for.
                Get-PtyScreen $session -As Vt -Scrollback | Should -Match 'line 1\D'
            }
        }
    }

    Context 'colours and attributes' {
        It 'come back as styled runs' {
            Use-Pty "pwsh -NoProfile -File `"$ColourProbe`"" 40 8 'READY' {
                param($session)
                $rows = @(Get-PtyScreen $session -As Styled)
                $rows.Count | Should -Be 8 -Because 'one entry per viewport row'

                $red = @($rows[1].Runs)[0]
                $red.Text.Trim() | Should -Be 'red'
                $red.Foreground.Kind | Should -Be 'Palette'
                $red.Foreground.Index | Should -Be 1 -Because 'SGR 31 is palette entry 1'
                $red.Foreground.Hex | Should -Match '^#[0-9a-f]{6}$' -Because 'the palette should be resolved'

                $rgb = @($rows[1].Runs) | Where-Object { $_.Text -eq 'bold-rgb' } | Select-Object -First 1
                $rgb.Foreground.Kind | Should -Be 'Rgb'
                $rgb.Foreground.Hex | Should -Be '#0080ff'
                $rgb.Bold | Should -BeTrue

                @($rows[3].Runs)[0].Underline | Should -Be 'Single'

                # A plain row still reports the terminal's own colours, and says they are default.
                $plain = @($rows[0].Runs)[0]
                $plain.Text | Should -Be 'plain'
                $plain.Foreground.Kind | Should -Be 'Default'
                $plain.EffectiveForeground.Hex | Should -Be $plain.Foreground.Hex
            }
        }

        It 'resolve inverse into the effective colours' {
            # A highlighted row is usually inverse rather than literally coloured, so a test that
            # asks "what does this look like" has to get the swap done for it.
            Use-Pty "pwsh -NoProfile -File `"$ColourProbe`"" 40 8 'READY' {
                param($session)
                $rows = @(Get-PtyScreen $session -As Styled)
                $inverse = @($rows[2].Runs)[0]
                $inverse.Inverse | Should -BeTrue
                $inverse.EffectiveForeground.Hex | Should -Be $inverse.Background.Hex -Because 'inverse swaps the pair'
                $inverse.EffectiveBackground.Hex | Should -Be $inverse.Foreground.Hex

                $background = @($rows[2].Runs) | Where-Object { $_.Background.Kind -eq 'Palette' } | Select-Object -First 1
                $background.Background.Index | Should -Be 4 -Because 'SGR 44 is palette entry 4'
            }
        }

        It 'answer a point query and a search' {
            Use-Pty "pwsh -NoProfile -File `"$ColourProbe`"" 40 8 'READY' {
                param($session)
                (Get-PtyStyleAt $session -Row 1 -Column 0).Foreground.Kind | Should -Be 'Palette' -Because 'the first cell of the red run'
                Get-PtyStyleAt $session -Row 0 -Column 39 | Should -BeNullOrEmpty -Because 'that is past the end of what was drawn'

                $found = @(Find-PtyText $session 'bold-\w+' -WithStyle)
                $found.Count | Should -Be 1
                $found[0].Row | Should -Be 1
                $found[0].Column | Should -Be 8
                $found[0].Text | Should -Be 'bold-rgb'
                @($found[0].Runs)[0].EffectiveForeground.Hex | Should -Be '#0080ff'
            }
        }

        It 'can be had as VT or as a page to look at' {
            Use-Pty "pwsh -NoProfile -File `"$ColourProbe`"" 40 8 'READY' {
                param($session)
                $escape = [char] 27
                $vt = Get-PtyScreen $session -As Vt
                $vt | Should -Match "$escape\[38;2;0;128;255m" -Because 'the RGB colour should be an escape sequence'
                $vt | Should -Match 'bold-rgb'

                $html = Get-PtyScreen $session -As Html
                $html | Should -Match 'color:#0080ff' -Because 'the RGB colour should be CSS'
                $html | Should -Match 'font-weight:bold'
                # Palette colours are resolved, not left as the CSS variables libghostty would
                # emit and never define.
                $html | Should -Match 'color:#[0-9a-f]{6}[^>]*>red'
                $html | Should -Match '(?s)<html>.*</html>' -Because 'it should be a whole document'

                { Get-PtyScreen $session -As Html -Scrollback } | Should -Throw -ExpectedMessage "*doesn't apply to -As Html*"
                { Get-PtyScreen $session -As Vt -NonEmpty } | Should -Throw -ExpectedMessage '*-NonEmpty only applies*'
            }
        }
    }

    Context 'sessions' {
        It 'can be picked up by another process' {
            $session = Start-PtyApp -CommandLine 'cmd.exe' -WorkingDirectory $Fixtures -Name 'pty-test' -Columns 80 -Rows 24
            try {
                Wait-PtyText $session 'Microsoft Windows' -TimeoutSeconds 30 | Out-Null
                $script = @"
`$env:PSModulePath = '$(Join-Path $PSScriptRoot '..' 'src')' + [IO.Path]::PathSeparator + `$env:PSModulePath
Import-Module '$ModulePath'
`$s = Get-PtyApp -Name 'pty-test'
Send-PtyKeys `$s 'echo from-another-process{Enter}' -SettleMilliseconds 700 | Out-Null
(Get-PtyScreen `$s -NonEmpty) -match '^from-another-process' | Select-Object -Last 1
"@
                $seen = & pwsh -NoProfile -NoLogo -Command $script | Select-Object -Last 1
                "$seen" | Should -Match 'from-another-process'
            } finally { Stop-PtyApp $session }
        }

        It 'leaves nothing behind when stopped' {
            $session = Start-PtyApp -CommandLine 'cmd.exe' -WorkingDirectory $Fixtures -Name 'pty-test' -Columns 80 -Rows 24
            Wait-PtyText $session 'Microsoft Windows' -TimeoutSeconds 30 | Out-Null
            $hostId = $session.HostProcessId
            Stop-PtyApp $session
            { Get-PtyApp -Name 'pty-test' } | Should -Throw -ExpectedMessage "*no pty session named 'pty-test'*"
            Test-Path -LiteralPath $session.RecordPath | Should -BeFalse
            Get-Process -Id $hostId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the host should be gone'
        }
    }

    Context 'mouse' -Skip:(-not $HasFzf) {
        BeforeAll {
            # Pin the shell fzf runs --preview with; see the console tests for why. 'cmd' rather
            # than 'pwsh' because the assertions expect cmd's quoting of {}.
            $env:SHELL = 'cmd'
            # Both fzf renderers are driven with the same SGR reports: the console host adapts,
            # turning them into console records for the tcell renderer and passing them through
            # for the light one. This only works with the redistributable OpenConsole; the inbox
            # host forwards no mouse at all.
            $script:Items = "1..40 | ForEach-Object { 'item ' + `$_ }"
        }

        It 'drives full-screen fzf with the wheel and a click' {
            Use-Pty "pwsh -NoProfile -Command `"$Items | fzf --preview 'echo SEL={}'`"" 100 24 'SEL="item' {
                param($session)
                $selected = Wait-Selection $session
                $selected | Should -Be 'item 1'
                Send-PtyKeys $session '{WheelUp 5 10 5}' -SettleMilliseconds 200 | Out-Null
                $selected = Wait-Selection $session $selected
                $selected | Should -Be 'item 6' -Because 'five notches up the list'
                Send-PtyKeys $session '{Click 4 8}' -SettleMilliseconds 200 | Out-Null
                Wait-Selection $session $selected | Should -Be 'item 14' -Because 'the click lands on the row at index 8'
            }
        }

        It 'drives fzf --height with the same events, by a different route' {
            # Aim inside the box: with --height the application draws in part of the screen, and
            # events outside it are ignored (which looks exactly like mouse being broken).
            Use-Pty "pwsh -NoProfile -Command `"$Items | fzf --height 60% --preview 'echo SEL={}'`"" 100 30 'SEL="item' {
                param($session)
                $selected = Wait-Selection $session
                $selected | Should -Be 'item 1'
                Send-PtyKeys $session '{WheelUp 5 10 4}' -SettleMilliseconds 200 | Out-Null
                Wait-Selection $session $selected | Should -Be 'item 5'
            }
        }
    }
}
