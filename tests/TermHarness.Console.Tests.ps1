# Tests for TermHarness.Console. These drive a real console, so they need Windows and fzf on
# PATH, and take a few seconds. The key syntax has its own tests in TermHarness.KeySpec.Tests.ps1.

BeforeDiscovery {
    $script:CanRun = [bool] $IsWindows -and [bool] (Get-Command fzf -ErrorAction SilentlyContinue)
}

Describe 'TermHarness.Console' -Tag Console, Interactive -Skip:(-not $CanRun) {
    BeforeAll {
        $source = Join-Path $PSScriptRoot '..' 'src'
        $env:PSModulePath = $source + [IO.Path]::PathSeparator + $env:PSModulePath
        $script:ModulePath = Join-Path $source 'TermHarness.Console' 'TermHarness.Console.psd1'
        Import-Module $ModulePath -Force
        $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'

        # Pin the shell fzf runs --preview with, so these tests don't depend on the environment
        # they were started from. Run from git bash, SHELL is /bin/bash.exe: fzf treats that as a
        # POSIX shell and converts the path with cygpath, which isn't on PATH when fzf was launched
        # from pwsh, so the preview never runs and the mouse assertions time out with an empty
        # selection. fzf's own tests pin it for the same reason. 'cmd' rather than 'pwsh' because
        # the assertions expect cmd's quoting: fzf substitutes {} as "item 1", quotes included.
        $env:SHELL = 'cmd'

        # fzf over a fixed list, so the tests don't depend on the current directory.
        $script:Items = 'alpha', 'beta,gamma', 'enter-the-void', 'delta'
        $script:Command = "@('$($Items -join "','")') | fzf"

        function Use-Fzf([scriptblock] $Body) {
            $session = Start-ConsoleApp -Command $Command -WorkingDirectory $Fixtures
            try {
                Wait-ConsoleText $session '^\s*>' | Out-Null
                & $Body $session
            } finally { Stop-ConsoleApp $session }
        }

        function Get-Query($Screen) {
            $line = $Screen | Where-Object { $_ -match '^\s*>' } | Select-Object -First 1
            return ($line -replace '^\s*>\s?', '').TrimEnd()
        }

        # The sink reports what actually arrived, so mouse and resize are asserted directly
        # instead of through some other app's reaction to them.
        function Use-Sink([switch] $VirtualTerminalInput, [scriptblock] $Body) {
            $log = Join-Path ([IO.Path]::GetTempPath()) "termharness-sink-$([guid]::NewGuid().ToString('N')).log"
            $sink = Join-Path $Fixtures 'InputSink.ps1'
            $sinkCommand = "& '$sink' -LogPath '$log'" + $(if ($VirtualTerminalInput) { ' -VirtualTerminalInput' } else { '' })
            $session = Start-ConsoleApp -Command $sinkCommand -WorkingDirectory $Fixtures
            try {
                Wait-ConsoleText $session 'INPUT SINK READY' -TimeoutSeconds 30 | Out-Null
                & $Body $session $log
            } finally {
                Stop-ConsoleApp $session
                Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
            }
        }

        # Mouse, against the application each delivery is for. Both use fzf's preview to read the
        # selection back, because the selection bar itself shows on every row of the grid.
        function Use-FzfWithPreview([string] $Extra, [scriptblock] $Body) {
            $list = "1..40 | ForEach-Object { 'item ' + `$_ }"
            $session = Start-ConsoleApp -Command "$list | fzf $Extra --preview 'echo SEL={}'" `
                -WorkingDirectory $Fixtures -Width 100 -Height 24
            try {
                Wait-ConsoleText $session 'SEL=' -TimeoutSeconds 30 | Out-Null
                & $Body $session
            } finally { Stop-ConsoleApp $session }
        }

        # Match a complete SEL="item N": the preview is drawn in pieces, so the label can be on
        # screen a frame before its value is.
        function Get-Selection($Session) {
            $line = Get-ConsoleScreen $Session | Where-Object { $_ -match 'SEL="item \d+"' } | Select-Object -First 1
            if ($line -match 'SEL="(item \d+)"') { return $Matches[1] }
            return ''
        }

        # Waits for a fully drawn selection that differs from $Previous. Waiting for a change
        # rather than for the expected value keeps the assertion meaningful: if the application
        # lands somewhere else, the test says so instead of polling until it agrees.
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

    Context 'keys' {
        It 'delivers text with a comma intact' {
            Use-Fzf {
                param($session)
                Get-Query (Send-ConsoleKeys $session 'beta,gam' -SettleMilliseconds 400) | Should -Be 'beta,gam'
            }
        }

        It "types 'enter' rather than pressing it" {
            Use-Fzf {
                param($session)
                Get-Query (Send-ConsoleKeys $session 'enter' -SettleMilliseconds 400) | Should -Be 'enter'
                $session.Process.HasExited | Should -BeFalse -Because 'fzf should still be running'
            }
        }

        It 'accepts the selection with {Enter}, and fzf exits' {
            Use-Fzf {
                param($session)
                Send-ConsoleKeys $session 'delta{Enter}' -SettleMilliseconds 600 | Out-Null
                $session.Process.WaitForExit(3000) | Should -BeTrue -Because 'fzf should have exited'
            }
        }

        It 'delivers a chord: Ctrl+U clears the query' {
            Use-Fzf {
                param($session)
                Send-ConsoleKeys $session 'alpha' -SettleMilliseconds 400 | Out-Null
                Get-Query (Send-ConsoleKeys $session '^u' -SettleMilliseconds 400) | Should -Be ''
            }
        }

        It 'delivers a repeat count: {BS 3}' {
            Use-Fzf {
                param($session)
                Send-ConsoleKeys $session 'alpha' -SettleMilliseconds 400 | Out-Null
                Get-Query (Send-ConsoleKeys $session '{BS 3}' -SettleMilliseconds 400) | Should -Be 'al'
            }
        }

        It 'types syntax characters with Send-ConsoleText' {
            Use-Fzf {
                param($session)
                Get-Query (Send-ConsoleText $session '^{Enter}' -SettleMilliseconds 400) | Should -Be '^{Enter}'
            }
        }

        It 'does not press keys from Send-ConsoleText' {
            Use-Fzf {
                param($session)
                Send-ConsoleText $session 'enter{Enter}' -SettleMilliseconds 500 | Out-Null
                $session.Process.HasExited | Should -BeFalse -Because 'fzf should still be running'
            }
        }

        It 'survives a command containing double quotes' {
            # Start-Process quoting used to mangle this into a call to Get-Item.
            $session = Start-ConsoleApp -Command '1..3 | ForEach-Object { "item " + $_ } | fzf' -WorkingDirectory $Fixtures
            try {
                Wait-ConsoleText $session 'item 3' | Out-Null
                @(Get-ConsoleScreen $session -NonEmpty) -match 'item 2' | Should -Not -BeNullOrEmpty
            } finally { Stop-ConsoleApp $session }
        }
    }

    Context 'sessions' {
        It 'lets another process pick the session up and drive it' {
            $session = Start-ConsoleApp -Command $Command -WorkingDirectory $Fixtures -Name 'harness-test'
            try {
                Wait-ConsoleText $session '^\s*>' | Out-Null
                Send-ConsoleKeys $session 'al' -SettleMilliseconds 400 | Out-Null
                # A separate process: it has only the name, and finds the running app from that.
                $script = @"
`$env:PSModulePath = '$(Join-Path $PSScriptRoot '..' 'src')' + [IO.Path]::PathSeparator + `$env:PSModulePath
Import-Module '$ModulePath'
`$s = Get-ConsoleApp -Name 'harness-test'
(Send-ConsoleKeys `$s 'pha' -SettleMilliseconds 400) -match '^\s*>' -replace '^\s*>\s?'
"@
                $seen = (& pwsh -NoProfile -NoLogo -Command $script | Select-Object -Last 1).TrimEnd()
                $seen | Should -Be 'alpha' -Because 'the other process should have typed onto the same query'
            } finally { Stop-ConsoleApp $session }
        }

        It 'kills the app when stopped, not just its wrapper' {
            $session = Start-ConsoleApp -Command $Command -WorkingDirectory $Fixtures
            Wait-ConsoleText $session '^\s*>' | Out-Null
            $descendants = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($session.Id)")
            $descendants.Count | Should -BeGreaterThan 0 -Because 'the wrapper should have a child'
            Stop-ConsoleApp $session
            $survivors = @($descendants | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
            $survivors.Count | Should -Be 0 -Because 'no child should be left running'
        }

        It 'forgets a stopped session' {
            $session = Start-ConsoleApp -Command $Command -WorkingDirectory $Fixtures -Name 'harness-test'
            Wait-ConsoleText $session '^\s*>' | Out-Null
            Stop-ConsoleApp $session
            { Get-ConsoleApp -Name 'harness-test' } | Should -Throw -ExpectedMessage "*no console app named 'harness-test'*"
            Test-Path -LiteralPath $session.RecordPath | Should -BeFalse -Because 'the record should be gone'
        }
    }

    Context 'mouse and resize, as the app receives them' {
        It 'delivers a wheel as a mouse record, with position and delta' {
            Use-Sink {
                param($session, $log)
                Send-ConsoleKeys $session '{WheelDown 2 }' -MouseDelivery Record -SettleMilliseconds 100 | Out-Null   # at the centre
                Send-ConsoleKeys $session '{WheelUp 7 3 1}' -MouseDelivery Record -SettleMilliseconds 400 | Out-Null
                $mouse = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^MOUSE' })
                $mouse.Count | Should -Be 3 -Because 'two notches down, then one up'
                # 120 per notch, negative down: 0xff88 is -120 in the high word. flags 0x4 = wheeled.
                $mouse[0] | Should -Match 'buttons=0xff880000 flags=0x4'
                $mouse[2] | Should -Match 'pos=7,3 buttons=0x00780000 flags=0x4'
            }
        }

        It 'delivers a click as a move, a press and a release' {
            Use-Sink {
                param($session, $log)
                Send-ConsoleKeys $session '{Click 12 4 Right}' -MouseDelivery Record -SettleMilliseconds 400 | Out-Null
                $mouse = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^MOUSE' })
                $mouse.Count | Should -Be 3
                $mouse[0] | Should -Match 'pos=12,4 buttons=0x00000000 flags=0x1'
                $mouse[1] | Should -Match 'pos=12,4 buttons=0x00000002 flags=0x0'
                $mouse[2] | Should -Match 'pos=12,4 buttons=0x00000000 flags=0x0'
            }
        }

        It 'sends SGR sequences to an app in virtual-terminal mode' {
            Use-Sink -VirtualTerminalInput {
                param($session, $log)
                (Get-ConsoleInfo $session).VtInput | Should -BeTrue
                Send-ConsoleKeys $session '{WheelDown 7 3 1}' -SettleMilliseconds 400 | Out-Null
                $characters = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^KEY down=1' } | ForEach-Object {
                    if ($_ -match 'char=0x([0-9a-f]+)') { [char] [Convert]::ToInt32($Matches[1], 16) }
                })
                # SGR: button 65 is wheel-down, and the coordinates are 1-based.
                (-join $characters) | Should -Be "$([char] 27)[<65;8;4M"
            }
        }

        It 'delivers a resize, and reports the new size' {
            Use-Sink {
                param($session, $log)
                $state = Set-ConsoleSize $session -Width 80 -Height 25 -SettleMilliseconds 400
                $state.WindowWidth | Should -Be 80
                $state.WindowHeight | Should -Be 25
                @(Get-Content -LiteralPath $log) -match 'RESIZE to 80x' | Should -Not -BeNullOrEmpty -Because 'the app should see a resize event'
            }
        }

        It 'resizes a full-screen app too, which reflows' {
            # fzf holds the alternate screen buffer, where conhost refuses SetConsoleScreenBufferSize
            # and SetConsoleWindowInfo, so this exercises the window-resize fallback.
            $session = Start-ConsoleApp -Command $Command -WorkingDirectory $Fixtures
            try {
                Wait-ConsoleText $session '^\s*>' | Out-Null
                $state = Set-ConsoleSize $session -Width 80 -Height 20 -SettleMilliseconds 600
                $state.WindowWidth | Should -Be 80
                $state.WindowHeight | Should -Be 20
                $widest = (@(Get-ConsoleScreen $session) | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
                $widest | Should -BeLessOrEqual 80 -Because 'the app should have redrawn for the narrower console'
            } finally { Stop-ConsoleApp $session }
        }

        It 'reports the console and its input mode' {
            Use-Sink {
                param($session)
                $state = Get-ConsoleInfo $session
                $state.WindowWidth | Should -Be 120
                $state.WindowHeight | Should -Be 30
                $state.BufferHeight | Should -Be 1000 -Because 'the default buffer leaves room for scrollback'
                $state.MouseInput | Should -BeTrue
                $state.VtInput | Should -BeFalse
                # The reported delivery is what was asked for, not a guess about the app: there is
                # no auto-detection, because an app can parse SGR without setting the VT input flag.
                $state.MouseDelivery | Should -Be 'Vt' -Because 'SGR is the default'
            }
        }
    }

    Context 'scrollback' {
        It 'reads the buffer and moves the view' {
            # 200 lines of output, then the app waits, so the buffer holds more than one screen.
            $session = Start-ConsoleApp -Command '1..200 | ForEach-Object { "line " + $_ }; $null = Read-Host' -WorkingDirectory $Fixtures
            try {
                Wait-ConsoleText $session 'line 200' -TimeoutSeconds 30 | Out-Null
                $state = Get-ConsoleInfo $session
                $state.WindowTop | Should -BeGreaterThan 0 -Because 'output should have scrolled the window down the buffer'

                @(Get-ConsoleScreen $session -NonEmpty) | Should -Not -Contain 'line 1' -Because 'line 1 has scrolled off'
                $all = @(Get-ConsoleScreen $session -Scrollback -NonEmpty)
                $all | Should -Contain 'line 1' -Because 'it is still in the buffer'
                $all | Should -Contain 'line 200'

                $rows = @(Get-ConsoleScreen $session -FromRow ($state.WindowTop - 3) -Rows 3)
                $rows.Count | Should -Be 3
                $rows[0] | Should -Match '^line \d+$'

                (Move-ConsoleView $session -Lines -10).WindowTop | Should -Be ($state.WindowTop - 10)
                (Move-ConsoleView $session -Start).WindowTop | Should -Be 0
                @(Get-ConsoleScreen $session -NonEmpty)[0] | Should -Be 'line 1'
                (Move-ConsoleView $session -End).WindowTop | Should -Be ($state.BufferHeight - $state.WindowHeight)
            } finally { Stop-ConsoleApp $session }
        }
    }

    Context 'mouse, per application' {
        It 'drives full-screen fzf with console records (tcell)' {
            Use-FzfWithPreview '' {
                param($session)
                $selected = Wait-Selection $session
                $selected | Should -Be 'item 1'
                Send-ConsoleKeys $session '{WheelUp 5 10 5}' -MouseDelivery Record -SettleMilliseconds 200 | Out-Null
                Wait-Selection $session $selected | Should -Be 'item 6' -Because 'five notches up the list'
            }
        }

        It 'selects the row a click lands on' {
            Use-FzfWithPreview '' {
                param($session)
                # Aim at where the application actually drew, rather than at a guess.
                $screen = Get-ConsoleScreen $session
                $row = -1
                for ($index = 0; $index -lt $screen.Count; $index++) {
                    if ($screen[$index] -match 'item 14') { $row = $index; break }
                }
                $row | Should -BeGreaterOrEqual 0 -Because 'item 14 should be on screen'
                $selected = Get-Selection $session
                Send-ConsoleKeys $session "{Click 4 $row}" -MouseDelivery Record -SettleMilliseconds 200 | Out-Null
                Wait-Selection $session $selected | Should -Be 'item 14'
            }
        }

        It 'drives fzf --height with SGR instead (light renderer)' {
            Use-FzfWithPreview '--height 60%' {
                param($session)
                $selected = Wait-Selection $session
                $selected | Should -Be 'item 1'
                # Record delivery is what this renderer ignores; Vt is what it reads. Nothing should
                # change here, so this one does have to wait out a fixed delay.
                Send-ConsoleKeys $session '{WheelUp 5 10 4}' -MouseDelivery Record -SettleMilliseconds 800 | Out-Null
                Get-Selection $session | Should -Be 'item 1' -Because 'console records are ignored here'
                Send-ConsoleKeys $session '{WheelUp 5 10 4}' -SettleMilliseconds 200 | Out-Null
                Wait-Selection $session $selected | Should -Be 'item 5' -Because 'the default (Vt) delivery works'
            }
        }
    }
}
