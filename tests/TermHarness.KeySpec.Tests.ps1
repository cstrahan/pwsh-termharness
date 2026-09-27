# Tests for the key specification parser. Nothing here touches a console, so they run anywhere.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'TermHarness.KeySpec' 'TermHarness.KeySpec.psd1') -Force

    # Renders parsed events compactly, for readable expectations: each key press as
    # <modifiers>vk<code>:<character>, with 'v' for a press and '^' for its release.
    function Format-KeyEvent($Events) {
        $parts = foreach ($keyEvent in $Events) {
            $modifiers = ''
            if ($keyEvent.ControlState -band 0x000C) { $modifiers += 'C' }   # either Ctrl
            if ($keyEvent.ControlState -band 0x0003) { $modifiers += 'A' }   # either Alt
            if ($keyEvent.ControlState -band 0x0010) { $modifiers += 'S' }
            $character = if ($keyEvent.CharCode -eq 0) { '.' } else { '0x{0:x2}' -f $keyEvent.CharCode }
            '{0}{1}{2}:{3}' -f $(if ($keyEvent.KeyDown) { 'v' } else { '^' }), $modifiers, ('0x{0:x2}' -f $keyEvent.VirtualKey), $character
        }
        return $parts -join ' '
    }
}

Describe 'ConvertFrom-KeySpec' -Tag KeySpec {
    Context 'text' {
        It 'types plain text literally' {
            Format-KeyEvent (ConvertFrom-KeySpec 'hi') | Should -Be 'v0x00:0x68 ^0x00:0x68 v0x00:0x69 ^0x00:0x69'
        }

        It 'keeps words that name keys as text' {
            # The bug this syntax was adopted to fix: 'enter' used to press Enter.
            (ConvertFrom-KeySpec 'enter').Count | Should -Be 10
            (ConvertFrom-KeySpec 'enter')[0].CharCode | Should -Be 0x65
        }

        It 'keeps commas' {
            (ConvertFrom-KeySpec 'a,b').Count | Should -Be 6
            (ConvertFrom-KeySpec 'a,b')[2].CharCode | Should -Be 0x2C
        }

        It 'treats a newline as Enter, and a CRLF as one press' {
            Format-KeyEvent (ConvertFrom-KeySpec "`r`n") | Should -Be 'v0x0d:0x0d ^0x0d:0x0d'
            Format-KeyEvent (ConvertFrom-KeySpec "`n") | Should -Be 'v0x0d:0x0d ^0x0d:0x0d'
        }

        It 'sends nothing for an empty specification' {
            (ConvertFrom-KeySpec '').Count | Should -Be 0
        }

        It 'tags every event with a type name' {
            (ConvertFrom-KeySpec 'a')[0].PSObject.TypeNames[0] | Should -Be 'TermHarness.KeyEvent'
            (ConvertFrom-KeySpec '{Click 1 1}')[0].PSObject.TypeNames[0] | Should -Be 'TermHarness.MouseEvent'
        }
    }

    Context 'keys' {
        It 'presses the key for {Enter}' {
            Format-KeyEvent (ConvertFrom-KeySpec '{Enter}') | Should -Be 'v0x0d:0x0d ^0x0d:0x0d'
        }

        It 'accepts key names case-insensitively, with the usual aliases' {
            Format-KeyEvent (ConvertFrom-KeySpec '{RETURN}') | Should -Be (Format-KeyEvent (ConvertFrom-KeySpec '{Enter}'))
            Format-KeyEvent (ConvertFrom-KeySpec '{bs}') | Should -Be (Format-KeyEvent (ConvertFrom-KeySpec '{Backspace}'))
            Format-KeyEvent (ConvertFrom-KeySpec '{Esc}') | Should -Be (Format-KeyEvent (ConvertFrom-KeySpec '{Escape}'))
        }

        It 'repeats a key the given number of times' {
            (ConvertFrom-KeySpec '{BS 3}').Count | Should -Be 6
            (ConvertFrom-KeySpec '{a 5}').Count | Should -Be 10
        }

        It 'types a code point with {U+...}, outside the BMP too' {
            (ConvertFrom-KeySpec '{U+263A}')[0].CharCode | Should -Be 0x263A
            (ConvertFrom-KeySpec '{U+1F600}').Count | Should -Be 4   # a surrogate pair, pressed and released
        }
    }

    Context 'modifiers' {
        It 'sends ^s as Ctrl+S: virtual key S, control character 0x13' {
            Format-KeyEvent (ConvertFrom-KeySpec '^s') | Should -Be 'vC0x53:0x13 ^C0x53:0x13'
        }

        It 'applies a prefix to the next key only' {
            Format-KeyEvent (ConvertFrom-KeySpec '^ss') | Should -Be 'vC0x53:0x13 ^C0x53:0x13 v0x00:0x73 ^0x00:0x73'
        }

        It 'combines prefixes, and applies them to named keys' {
            Format-KeyEvent (ConvertFrom-KeySpec '^+{Enter}') | Should -Be 'vCS0x0d:0x0d ^CS0x0d:0x0d'
        }

        It 'sends +a as A' {
            Format-KeyEvent (ConvertFrom-KeySpec '+a') | Should -Be 'vS0x00:0x41 ^S0x00:0x41'
        }

        It 'sends !x as Alt+X, keeping the character' {
            Format-KeyEvent (ConvertFrom-KeySpec '!x') | Should -Be 'vA0x58:0x78 ^A0x58:0x78'
        }

        It 'holds a modifier with {Ctrl down} until {Ctrl up}' {
            Format-KeyEvent (ConvertFrom-KeySpec '{Ctrl down}jk{Ctrl up}j') |
                Should -Be 'vC0x4a:0x0a ^C0x4a:0x0a vC0x4b:0x0b ^C0x4b:0x0b v0x00:0x6a ^0x00:0x6a'
        }
    }

    Context 'escapes' {
        It 'types braces and modifier characters through their escapes' {
            Format-KeyEvent (ConvertFrom-KeySpec '{{}{}}') | Should -Be 'v0x00:0x7b ^0x00:0x7b v0x00:0x7d ^0x00:0x7d'
            Format-KeyEvent (ConvertFrom-KeySpec '{^}') | Should -Be 'v0x00:0x5e ^0x00:0x5e'
            # ':qa{!}{Enter}' in Neovim: an unescaped '!' would be Alt, and quietly send Alt+Enter.
            Format-KeyEvent (ConvertFrom-KeySpec '{!}{Enter}') | Should -Be 'v0x00:0x21 ^0x00:0x21 v0x0d:0x0d ^0x0d:0x0d'
        }

        It 'makes the rest literal after {Raw}' {
            Format-KeyEvent (ConvertFrom-KeySpec '{Raw}^{Enter}') | Should -Be (Format-KeyEvent (ConvertFrom-KeySpec '^{Enter}' -Literal))
            (ConvertFrom-KeySpec '{Raw}^{Enter}').Count | Should -Be 16   # the eight characters
        }

        It 'types braces and modifiers verbatim with -Literal' {
            Format-KeyEvent (ConvertFrom-KeySpec '^{' -Literal) | Should -Be 'v0x00:0x5e ^0x00:0x5e v0x00:0x7b ^0x00:0x7b'
        }
    }

    Context 'mouse' {
        It 'carries position, button and action in a click' {
            $events = ConvertFrom-KeySpec '{Click 40 10}'
            $events[0].Type | Should -Be 'Mouse'
            $events.Count | Should -Be 3 -Because 'a click is a move, then a press and a release'
            $events[0].Action | Should -Be 'Move'
            $events[1].X | Should -Be 40
            $events[1].Y | Should -Be 10
            $events[1].Button | Should -Be 'Left'
            $events[1].Action | Should -Be 'Down'
            $events[2].Action | Should -Be 'Up'
        }

        It 'keeps the pointer where the last token put it' {
            # {WheelDown} has no coordinates, so it happens where {Click} left the pointer. Assign
            # first: the result is one array object, and piping it would hand it over as one item.
            $all = ConvertFrom-KeySpec '{Click 40 10}{WheelDown}'
            $events = @($all | Where-Object { $_.Action -eq 'Wheel' })
            $events.Count | Should -Be 1
            $events[0].X | Should -Be 40
            $events[0].Y | Should -Be 10
            # With no coordinates at all, the harness fills in the middle of the window.
            (ConvertFrom-KeySpec '{WheelUp}')[0].X | Should -Be -1
        }

        It 'encodes wheel direction, axis and count' {
            (ConvertFrom-KeySpec '{WheelDown}')[0].Notches | Should -Be -1
            (ConvertFrom-KeySpec '{WheelUp}')[0].Notches | Should -Be 1
            (ConvertFrom-KeySpec '{WheelDown 3}').Count | Should -Be 3 -Because 'one event per notch'
            (ConvertFrom-KeySpec '{WheelRight}')[0].WheelAxis | Should -Be 'Horizontal'
            (ConvertFrom-KeySpec '{WheelDown 40 10 3}').Count | Should -Be 3
        }

        It 'takes a button, a count, or move-only as click options' {
            (ConvertFrom-KeySpec '{Click 5 5 Right}')[1].Button | Should -Be 'Right'
            (ConvertFrom-KeySpec '{MButton}')[0].Button | Should -Be 'Middle'
            (ConvertFrom-KeySpec '{Click 5 5 2}').Count | Should -Be 5 -Because 'a move plus two press/release pairs'
            $moveOnly = ConvertFrom-KeySpec '{Click 5 5 0}'
            $moveOnly.Count | Should -Be 1
            $moveOnly[0].Action | Should -Be 'Move'
            (ConvertFrom-KeySpec '{LButton down}')[0].Action | Should -Be 'Down'
        }

        It 'applies modifiers to the mouse too' {
            (ConvertFrom-KeySpec '^{Click 5 5}')[1].ControlState | Should -Be 8 -Because 'LEFT_CTRL_PRESSED'
        }

        It 'mixes keys and mouse in one specification' {
            $events = ConvertFrom-KeySpec 'hi{Click 1 2}{Enter}'
            ($events | ForEach-Object { $_.Type }) -join '' | Should -Be 'KeyKeyKeyKeyMouseMouseMouseKeyKey'
        }
    }

    Context 'mistakes' {
        It 'reports an unterminated brace' {
            { ConvertFrom-KeySpec '{Enter' } | Should -Throw -ExpectedMessage '*unterminated*'
        }

        It 'reports an unknown key, and offers -Literal' {
            { ConvertFrom-KeySpec '{Entr}' } | Should -Throw -ExpectedMessage "*unknown key '{Entr}'*"
            { ConvertFrom-KeySpec '{Entr}' } | Should -Throw -ExpectedMessage '*-Literal*'
        }

        It 'reports a bad key argument' {
            { ConvertFrom-KeySpec '{Tab x}' } | Should -Throw -ExpectedMessage '*expected a repeat count*'
        }

        It 'rejects a bare modifier' {
            { ConvertFrom-KeySpec '{Ctrl}' } | Should -Throw -ExpectedMessage '*only sees modifiers*'
        }

        It 'rejects the Win key' {
            { ConvertFrom-KeySpec '#r' } | Should -Throw -ExpectedMessage "*can't reach a console app*"
        }

        It 'rejects a trailing modifier prefix' {
            { ConvertFrom-KeySpec 'abc^' } | Should -Throw -ExpectedMessage '*modifier prefix*'
        }
    }
}
