# =================================================================
# WorkCtl v1.5 - Generic TUI Engine
# =================================================================

$script:UiPreviousFrame = @()
$script:UiOriginTop = 0
$script:UiActive = $false
$script:UiLastWidth = 0
$script:UiLastHeight = 0
$script:UiModuleDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { "E:\TOOLS\WorkstationControl\modules" }
$script:WorkCtlSharedTelemetryWorker = $null
$script:WorkCtlSharedTelemetryRefCount = 0
$script:WorkCtlSharedTelemetryLock = New-Object object
$script:WorkCtlHomeItemRows = @(5, 6, 7, 8, 9, 11, 12, 13, 14, 16, 17, 18)

function Assert-WorkCtlScalarInt {
    param(
        $Value,
        [string]$Name = "Dimension",
        [int]$Fallback = 0
    )
    if ($Value -is [int]) { return $Value }
    if ($Value -is [array]) {
        if ($Value.Count -gt 0) {
            $parsed = 0
            if ([int]::TryParse([string]$Value[0], [ref]$parsed)) {
                return $parsed
            }
        }
        return $Fallback
    }
    $res = 0
    if ([int]::TryParse([string]$Value, [ref]$res)) {
        return $res
    }
    return $Fallback
}

function Get-WorkCtlCount {
    [OutputType([int])]
    param($Value)
    if ($null -eq $Value) { return [int]0 }
    if ($Value -is [System.Collections.ICollection]) { return [int]$Value.Count }
    [int]$c = 0
    foreach ($item in $Value) {
        $c++
    }
    return [int]$c
}

function Step-WorkCtlListSelection {
    [OutputType([int])]
    param(
        $Index,
        [int]$Total,
        [ValidateSet("Up", "Down", "PageUp", "PageDown", "Home", "End")][string]$Direction,
        [int]$PageSize = 10,
        [int]$StepBy = 1
    )
    [int]$cur = if ($Index -is [System.Management.Automation.PSReference]) { $Index.Value } else { [int]$Index }
    [int]$tot = [int][math]::Max(0, $Total)
    if ($tot -le 0) {
        if ($Index -is [System.Management.Automation.PSReference]) { $Index.Value = [int]0 }
        return [int]0
    }
    $cur = [int][math]::Max(0, [int][math]::Min([int]($tot - 1), $cur))
    [int]$newIdx = $cur
    [int]$step = [math]::Max(1, $StepBy)

    switch ($Direction) {
        "Up"       { $newIdx = [int][math]::Max(0, [int]($cur - $step)) }
        "Down"     { $newIdx = [int][math]::Min([int]($tot - 1), [int]($cur + $step)) }
        "PageUp"   { $newIdx = [int][math]::Max(0, [int]($cur - [math]::Max(1, $PageSize * $step))) }
        "PageDown" { $newIdx = [int][math]::Min([int]($tot - 1), [int]($cur + [math]::Max(1, $PageSize * $step))) }
        "Home"     { $newIdx = [int]0 }
        "End"      { $newIdx = [int]($tot - 1) }
    }

    if ($Index -is [System.Management.Automation.PSReference]) {
        $Index.Value = $newIdx
    }
    return [int]$newIdx
}

# =================================================================
# FRAME MODEL CACHE & SELECTION-ONLY FAST PATH
# =================================================================

$script:WorkCtlFrameCache = @{}

function Set-WorkCtlCachedFrame([string]$Screen, $Frame) {
    if ($Screen -and $Frame) {
        $script:WorkCtlFrameCache[$Screen] = $Frame
    }
}

function Update-WorkCtlFrameCache([string]$Screen, $Frame) {
    Set-WorkCtlCachedFrame $Screen $Frame
}

function Get-WorkCtlCachedFrame([string]$Screen) {
    if ($Screen -and $script:WorkCtlFrameCache.ContainsKey($Screen)) {
        return $script:WorkCtlFrameCache[$Screen]
    }
    return $null
}

function Clear-WorkCtlFrameCache {
    $script:WorkCtlFrameCache.Clear()
}

function Clone-UiLine($Line) {
    if (!$Line) { return $null }
    $newSegs = New-Object System.Collections.Generic.List[object]
    if ($Line.Segments) {
        foreach ($s in $Line.Segments) {
            $newSegs.Add((New-UiSegment -Text $s.Text -Foreground $s.Foreground -Background $s.Background))
        }
    }
    return (New-UiLine $newSegs.ToArray())
}

function Update-WorkCtlSelectionFast {
    param(
        [Parameter(Mandatory=$true)][string]$Screen,
        [Parameter(Mandatory=$true)][int]$OldIndex,
        [Parameter(Mandatory=$true)][int]$NewIndex,
        [int]$OldScrollOffset = 0,
        [int]$NewScrollOffset = 0,
        [scriptblock]$PreviewUpdater = $null
    )

    if ($OldScrollOffset -ne $NewScrollOffset) {
        return $null
    }

    $frame = Get-WorkCtlCachedFrame $Screen
    if (!$frame -or $frame.Count -lt 6) {
        return $null
    }

    $rowOffset = switch ($Screen) {
        "shell-workloads-list" { 4 }
        "shell-workload-list"  { 4 }
        "shell-tools-list"     { 4 }
        "shell-home"           { 5 }
        "shell-storage"        { 6 }
        "shell-services"       { 5 }
        "shell-processes"      { 4 }
        "shell-dev-menu"       { 5 }
        "shell-projects"       { 4 }
        "shell-agents"         { 4 }
        "shell-search"         { 4 }
        "shell-guide"          { 4 }
        default                { -1 }
    }

    if ($rowOffset -lt 0) {
        return $null
    }

    $oldRowIdx = if ($Screen -eq "shell-home" -and $script:WorkCtlHomeItemRows -and $OldIndex -lt $script:WorkCtlHomeItemRows.Count) {
        $script:WorkCtlHomeItemRows[$OldIndex]
    } else {
        $rowOffset + ($OldIndex - $OldScrollOffset)
    }
    $newRowIdx = if ($Screen -eq "shell-home" -and $script:WorkCtlHomeItemRows -and $NewIndex -lt $script:WorkCtlHomeItemRows.Count) {
        $script:WorkCtlHomeItemRows[$NewIndex]
    } else {
        $rowOffset + ($NewIndex - $NewScrollOffset)
    }

    if ($oldRowIdx -ge 0 -and $oldRowIdx -lt $frame.Count -and
        $newRowIdx -ge 0 -and $newRowIdx -lt $frame.Count) {

        # Clone rows so they are new object instances, preventing differential diff short-circuit
        $oldRow = Clone-UiLine $frame[$oldRowIdx]
        $newRow = Clone-UiLine $frame[$newRowIdx]

        if ($oldRow.Segments -and $oldRow.Segments.Count -ge 2 -and
            $newRow.Segments -and $newRow.Segments.Count -ge 2) {

            $oldRow.Segments[1].Text = "  "
            $newRow.Segments[1].Text = "> "

            if ($Screen -eq "shell-home") {
                if ($oldRow.Segments.Count -ge 4) {
                    $oldRow.Segments[1].Foreground = [ConsoleColor]::DarkGray
                    $oldRow.Segments[2].Foreground = [ConsoleColor]::DarkGray
                    $oldRow.Segments[3].Foreground = [ConsoleColor]::White
                    if ($oldRow.Segments.Count -ge 5) { $oldRow.Segments[4].Foreground = [ConsoleColor]::DarkGray }
                }
                if ($newRow.Segments.Count -ge 4) {
                    $newRow.Segments[1].Foreground = [ConsoleColor]::Cyan
                    $newRow.Segments[2].Foreground = [ConsoleColor]::Cyan
                    $newRow.Segments[3].Foreground = [ConsoleColor]::Cyan
                    if ($newRow.Segments.Count -ge 5) { $newRow.Segments[4].Foreground = [ConsoleColor]::Gray }
                }
            }

            $frame[$oldRowIdx] = $oldRow
            $frame[$newRowIdx] = $newRow

            # Fast sub-0.1ms direct console write
            if ($script:UiActive) {
                Write-UiLineAt -Row $oldRowIdx -Line $oldRow
                Write-UiLineAt -Row $newRowIdx -Line $newRow
            }

            # Keep previous frame cache synchronized
            if ($script:UiPreviousFrame -and $script:UiPreviousFrame.Count -gt [math]::Max($oldRowIdx, $newRowIdx)) {
                $script:UiPreviousFrame[$oldRowIdx] = $oldRow
                $script:UiPreviousFrame[$newRowIdx] = $newRow
            }

            if ($PreviewUpdater) {
                try {
                    & $PreviewUpdater $frame $NewIndex
                } catch {}
            }

            return $frame
        }
    }

    return $null
}

function Split-WorkCtlText {
    param(
        [string]$Text,
        [int]$MaxWidth = 80
    )
    [int]$width = [int][math]::Max(10, $MaxWidth)
    $lines = New-Object System.Collections.Generic.List[string]
    if (!$Text) {
        $lines.Add("")
        return $lines.ToArray()
    }

    $paragraphs = @($Text -split "`r?`n")
    foreach ($para in $paragraphs) {
        if ($para.Length -le $width) {
            $lines.Add($para)
            continue
        }

        $words = $para -split "\s+"
        $currentLine = New-Object System.Text.StringBuilder
        foreach ($w in $words) {
            if (!$w) { continue }
            if ($currentLine.Length -eq 0) {
                if ($w.Length -gt $width) {
                    $remainingWord = $w
                    while ($remainingWord.Length -gt $width) {
                        $lines.Add($remainingWord.Substring(0, $width))
                        $remainingWord = $remainingWord.Substring($width)
                    }
                    if ($remainingWord.Length -gt 0) {
                        $null = $currentLine.Append($remainingWord)
                    }
                } else {
                    $null = $currentLine.Append($w)
                }
            } elseif (($currentLine.Length + 1 + $w.Length) -le $width) {
                $null = $currentLine.Append(" ").Append($w)
            } else {
                $lines.Add($currentLine.ToString())
                $currentLine.Clear() | Out-Null
                if ($w.Length -gt $width) {
                    $remainingWord = $w
                    while ($remainingWord.Length -gt $width) {
                        $lines.Add($remainingWord.Substring(0, $width))
                        $remainingWord = $remainingWord.Substring($width)
                    }
                    if ($remainingWord.Length -gt 0) {
                        $null = $currentLine.Append($remainingWord)
                    }
                } else {
                    $null = $currentLine.Append($w)
                }
            }
        }
        if ($currentLine.Length -gt 0) {
            $lines.Add($currentLine.ToString())
        }
    }

    $lines.ToArray()
}

function Get-WorkCtlWindowWidth {
    [OutputType([int])]
    param()
    if ($script:WorkCtlMockWindowWidth -and $script:WorkCtlMockWindowWidth -ge 20) {
        return [int]$script:WorkCtlMockWindowWidth
    }
    try {
        $w = [Console]::WindowWidth
        if ($w -is [int] -and $w -ge 20) { return [int]$w }
    } catch {}
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -is [int] -and $w -ge 20) { return [int]$w }
    } catch {}
    return [int]80
}

function Get-WorkCtlWindowHeight {
    [OutputType([int])]
    param()
    if ($script:WorkCtlMockWindowHeight -and $script:WorkCtlMockWindowHeight -ge 10) {
        return [int]$script:WorkCtlMockWindowHeight
    }
    try {
        $h = [Console]::WindowHeight
        if ($h -is [int] -and $h -ge 10) { return [int]$h }
    } catch {}
    try {
        $h = $Host.UI.RawUI.WindowSize.Height
        if ($h -is [int] -and $h -ge 10) { return [int]$h }
    } catch {}
    return [int]30
}

function Get-WorkCtlMargin {
    param(
        [int]$Width = 0
    )

    if ($Width -le 0) {
        $Width = Get-WorkCtlWindowWidth
    }

    if ($Width -ge 140) {
        return "    "   # 4 spaces (ultra-wide)
    } elseif ($Width -ge 110) {
        return "   "    # 3 spaces (wide)
    } elseif ($Width -ge 80) {
        return "  "     # 2 spaces (standard)
    } else {
        return " "      # 1 space (compact)
    }
}

function Get-WorkCtlCanvas {
    param(
        [int]$Width = 0,
        [int]$Height = 0
    )

    [int]$w = if ($Width -gt 0) { $Width } else { (Get-WorkCtlWindowWidth) }
    [int]$h = if ($Height -gt 0) { $Height } else { (Get-WorkCtlWindowHeight) }

    # SafeWidth: In Windows Console/Terminal, writing to the final column (w-1) on the bottom row triggers automatic scrolling.
    # To maintain strict viewport containment across all supported terminals without scroll jitter or margin wrap,
    # SafeWidth is clamped to w - 1.
    [int]$safeWidth = [math]::Max(20, $w - 1)

    $margin = Get-WorkCtlMargin -Width $w
    [int]$marginLen = [int]$margin.Length
    [int]$usableContentWidth = [math]::Max(10, $safeWidth - ($marginLen * 2))

    [int]$footerRow = [math]::Max(0, $h - 1)
    [int]$footerSepRow = [math]::Max(0, $h - 2)
    [int]$contentTop = 2
    [int]$contentBottom = [math]::Max($contentTop, $footerSepRow - 1)
    [int]$availableContentRows = [math]::Max(1, $footerSepRow - $contentTop)

    [int]$leftPaneWidth = [math]::Min(55, [math]::Max(36, [int]($usableContentWidth * 0.45)))
    [int]$paneGap = 3
    [int]$rightPaneWidth = [math]::Max(20, $usableContentWidth - $leftPaneWidth - $paneGap)

    [PSCustomObject]@{
        Width                 = $w
        Height                = $h
        SafeWidth             = $safeWidth
        Margin                = $margin
        MarginLength          = $marginLen
        UsableContentWidth    = $usableContentWidth
        ContentTop            = $contentTop
        ContentBottom         = $contentBottom
        AvailableContentRows  = $availableContentRows
        FooterSepRow          = $footerSepRow
        FooterRow             = $footerRow
        LeftPaneWidth         = $leftPaneWidth
        PaneGap               = $paneGap
        RightPaneWidth        = $rightPaneWidth
        IsWide                = ($w -ge 110)
    }
}

function Start-WorkCtlUI {

    try {
        Clear-Host
    } catch {}

    $script:UiOriginTop = 0
    $script:UiPreviousFrame = @()
    $script:UiActive = $true
    $script:UiLastWidth = Get-WorkCtlWindowWidth
    $script:UiLastHeight = Get-WorkCtlWindowHeight

    try {
        [Console]::CursorVisible = $false
    } catch {}
}

function Stop-WorkCtlUI {

    try {
        [Console]::CursorVisible = $true
    } catch {}

    $script:UiPreviousFrame = @()
    $script:UiActive = $false

    try {
        $curHeight = Get-WorkCtlWindowHeight
        $lastRow = [math]::Min($curHeight - 1, $script:UiLastHeight)
        [Console]::SetCursorPosition(0, [math]::Max(0, $lastRow))
    } catch {}

    Write-Host ""
}

function New-UiSegment {

    param(
        [string]$Text = "",
        [ConsoleColor]$Foreground = [ConsoleColor]::Gray,
        [ConsoleColor]$Background = [ConsoleColor]::Black
    )

    [PSCustomObject]@{
        Text = $Text
        Foreground = $Foreground
        Background = $Background
    }
}

function New-UiLine {

    param(
        [object[]]$Segments
    )

    [PSCustomObject]@{
        Segments = @($Segments)
    }
}

function Get-UiLineText($Line) {

    if (!$Line) {
        return ""
    }

    $texts = New-Object System.Collections.Generic.List[string]

    foreach ($seg in @($Line.Segments)) {
        if ($seg -and $seg.Text) {
            $texts.Add([string]$seg.Text)
        }
    }

    $texts -join ""
}

function Test-UiLineEqual($A, $B) {

    if ($null -eq $A -and $null -eq $B) {
        return $true
    }

    if ($null -eq $A -or $null -eq $B) {
        return $false
    }

    $as = @($A.Segments)
    $bs = @($B.Segments)

    if ($as.Count -ne $bs.Count) {
        return $false
    }

    for ($i = 0; $i -lt $as.Count; $i++) {

        if (
            $as[$i].Text -ne $bs[$i].Text -or
            $as[$i].Foreground -ne $bs[$i].Foreground -or
            $as[$i].Background -ne $bs[$i].Background
        ) {
            return $false
        }
    }

    return $true
}

function Write-UiLineAt {
    param(
        [int]$Row,
        $Line
    )

    $canvas = Get-WorkCtlCanvas
    $width = $canvas.SafeWidth

    try {
        [Console]::SetCursorPosition(
            0,
            $script:UiOriginTop + $Row
        )
    } catch {
        return
    }

    $used = 0
    $lastFg = $null
    $lastBg = $null

    foreach ($seg in @($Line.Segments)) {
        if ($used -ge $width) { break }

        $text = [string]$seg.Text
        $remaining = $width - $used
        if ($text.Length -gt $remaining) {
            $text = $text.Substring(0, $remaining)
        }

        # Direct console write avoids Write-Host overhead (23x faster)
        try {
            if ($seg.Foreground -ne $lastFg) {
                [Console]::ForegroundColor = $seg.Foreground
                $lastFg = $seg.Foreground
            }
            if ($seg.Background -ne $lastBg) {
                [Console]::BackgroundColor = $seg.Background
                $lastBg = $seg.Background
            }
            [Console]::Write($text)
        } catch {
            Write-Host $text -ForegroundColor $seg.Foreground -BackgroundColor $seg.Background -NoNewline
        }

        $used += $text.Length
    }

    if ($used -lt $width) {
        $fill = " " * ($width - $used)
        try {
            if ($lastFg -ne [ConsoleColor]::Gray) {
                [Console]::ForegroundColor = [ConsoleColor]::Gray
            }
            if ($lastBg -ne [ConsoleColor]::Black) {
                [Console]::BackgroundColor = [ConsoleColor]::Black
            }
            [Console]::Write($fill)
        } catch {
            Write-Host $fill -ForegroundColor Gray -BackgroundColor Black -NoNewline
        }
    }
}

function Write-WorkCtlDiffFrame {

    param(
        [object[]]$Frame,
        [switch]$Force
    )

    if (!$script:UiActive) {
        Start-WorkCtlUI
    }

    # Terminal geometry and resize detection
    $canvas = Get-WorkCtlCanvas
    $curWidth = $canvas.Width
    $curHeight = $canvas.Height

    if ($curWidth -ne $script:UiLastWidth -or $curHeight -ne $script:UiLastHeight) {
        $Force = $true
        $script:UiLastWidth = $curWidth
        $script:UiLastHeight = $curHeight
        $script:UiPreviousFrame = @()
        try { Clear-Host } catch {}
    }

    $old = @($script:UiPreviousFrame)
    $new = @($Frame)

    # Clamp rendering strictly to window height to prevent terminal scroll spam
    $maxVisibleRows = [math]::Max(1, $curHeight - 1)

    # Guarantee that abandoned rows from longer previous screens are blanked
    $height = if ($Force) { $maxVisibleRows } else { [math]::Min($maxVisibleRows, [math]::Max($old.Count, $new.Count)) }

    for ($i = 0; $i -lt $height; $i++) {

        $oldLine = if ($i -lt $old.Count) {
            $old[$i]
        } else {
            $null
        }

        $newLine = if ($i -lt $new.Count) {
            $new[$i]
        } else {
            New-UiLine @(
                New-UiSegment ""
            )
        }

        if (
            $Force -or
            !(Test-UiLineEqual $oldLine $newLine)
        ) {
            Write-UiLineAt `
                -Row $i `
                -Line $newLine
        }
    }

    $script:UiPreviousFrame = $new
}

function Read-WorkCtlKey {

    param(
        [int]$TimeoutMs = 20
    )

    $until = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)

    while ([datetime]::UtcNow -lt $until) {

        try {
            if ([Console]::KeyAvailable) {
                return [Console]::ReadKey($true)
            }
        } catch {
            return $null
        }

        Start-Sleep -Milliseconds 5
    }

    return $null
}

function Read-WorkCtlSearchInput {

    param(
        [string]$CurrentQuery = "",
        [int]$Row = -1
    )

    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin
    if ($Row -lt 0) {
        $Row = [math]::Max(0, (Get-WorkCtlWindowHeight) - 2)
    }

    $query = $CurrentQuery

    try {
        [Console]::CursorVisible = $true
    } catch {}

    try {
        while ($true) {

            # Render search input line with proper margin
            try {
                [Console]::SetCursorPosition(0, $Row)
            } catch {}

            $prompt = $margin + " SEARCH: "
            $displayText = $prompt + $query

            if ($displayText.Length -gt $width) {
                $displayText = $displayText.Substring(0, $width)
            }

            Write-Host $prompt -ForegroundColor Cyan -BackgroundColor Black -NoNewline
            Write-Host $query -ForegroundColor Yellow -BackgroundColor Black -NoNewline

            $pad = $width - ($prompt.Length + $query.Length)
            if ($pad -gt 0) {
                Write-Host (" " * $pad) -ForegroundColor Gray -BackgroundColor Black -NoNewline
            }

            try {
                $cursorPos = [math]::Min($width - 1, $prompt.Length + $query.Length)
                [Console]::SetCursorPosition($cursorPos, $Row)
            } catch {}

            $key = $null
            try {
                $key = [Console]::ReadKey($true)
            } catch {
                return [PSCustomObject]@{
                    Cancelled = $true
                    Query = $CurrentQuery
                }
            }

            if ($key.Key -eq [ConsoleKey]::Enter) {
                return [PSCustomObject]@{
                    Cancelled = $false
                    Query = $query.Trim()
                }
            }

            if ($key.Key -eq [ConsoleKey]::Escape) {
                return [PSCustomObject]@{
                    Cancelled = $true
                    Query = $CurrentQuery
                }
            }

            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($query.Length -gt 0) {
                    $query = $query.Substring(0, $query.Length - 1)
                }
                continue
            }

            # Normal printable characters
            if ($key.KeyChar -ge [char]32 -and $key.KeyChar -le [char]126) {
                if ($query.Length -lt 40) {
                    $query += $key.KeyChar
                }
            }
        }

    } finally {
        try {
            [Console]::CursorVisible = $false
        } catch {}
    }
}

function Get-WorkCtlViewport {

    param(
        [int]$Total,
        [int]$Selected,
        [int]$Height,
        [int]$CurrentOffset = 0
    )

    [int]$tot = [int]$Total
    [int]$sel = [int]$Selected
    [int]$h = [int]$Height
    [int]$off = [int]$CurrentOffset

    if ($h -lt 1) {
        $h = 1
    }

    if ($tot -le 0) {
        return [PSCustomObject]@{
            Offset = 0
            End = 0
        }
    }

    if ($tot -le $h) {
        return [PSCustomObject]@{
            Offset = 0
            End = [int]($tot - 1)
        }
    }

    if ($sel -lt $off) {
        $off = $sel
    }

    if ($sel -ge ($off + $h)) {
        $off = [int]($sel - $h + 1)
    }

    $max = [int][math]::Max(0, [int]($tot - $h))

    if ($off -gt $max) {
        $off = $max
    }

    if ($off -lt 0) {
        $off = 0
    }

    [PSCustomObject]@{
        Offset = $off
        End = [int][math]::Min([int]($tot - 1), [int]($off + $h - 1))
    }
}

function New-WorkCtlBar {

    param(
        [double]$Percent,
        [int]$Width = 10
    )

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $filled = [math]::Round(
        ($Percent / 100) * $Width
    )

    ("#" * $filled) + (
        "-" * ($Width - $filled)
    )
}

function New-WorkCtlHeaderLine {

    param(
        [string[]]$Breadcrumbs,
        [int]$Width = 0
    )

    $canvas = Get-WorkCtlCanvas -Width $Width
    $w = $canvas.Width
    $margin = $canvas.Margin
    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-UiSegment $margin DarkGray))
    $segs.Add((New-UiSegment "WORKCTL" White))

    if ($Breadcrumbs -and $Breadcrumbs.Count -gt 0) {
        [int]$total = [int]$Breadcrumbs.Count
        for ($i = 0; $i -lt $total; $i++) {
            $b = $Breadcrumbs[$i]
            $segs.Add((New-UiSegment "  /  " DarkGray))
            $col = if ($i -eq ($total - 1)) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }
            $segs.Add((New-UiSegment $b.ToUpperInvariant() $col))
        }
    }

    if ($w -ge 80) {
        $leftLen = 0
        foreach ($s in $segs) { $leftLen += $s.Text.Length }
        $rightText = "ADMIN"
        $pad = $canvas.SafeWidth - $leftLen - $rightText.Length - $margin.Length
        if ($pad -gt 4) {
            $segs.Add((New-UiSegment (" " * $pad) DarkGray))
            $segs.Add((New-UiSegment $rightText DarkGray))
        }
    }

    New-UiLine $segs.ToArray()
}

function New-WorkCtlSeparatorLine {

    param(
        [string]$Char = "",
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray,
        [int]$Width = 0
    )

    $canvas = Get-WorkCtlCanvas -Width $Width
    $ch = if ($Char) { $Char } else { Get-WorkCtlBoxChar "BoxHorizontal" }
    $margin = $canvas.Margin
    [int]$ruleWidth = [math]::Max(10, [int]($canvas.SafeWidth - ($canvas.MarginLength * 2)))
    $text = [string]$ch * $ruleWidth

    New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment $text $Color)
    )
}

function New-WorkCtlFooterLine {

    param(
        [hashtable[]]$Items,
        [string]$RightText = "",
        [int]$Width = 0
    )

    $canvas = Get-WorkCtlCanvas -Width $Width
    $margin = $canvas.Margin
    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-UiSegment $margin DarkGray))

    [int]$usedLen = [int]$margin.Length

    foreach ($item in @($Items)) {
        $keyText = "[{0}]" -f $item.Key
        $label = " {0}  " -f $item.Label

        # Responsive: skip if would exceed safe width
        if (($usedLen + $keyText.Length + $label.Length + 10) -gt $canvas.SafeWidth) {
            break
        }

        $segs.Add((New-UiSegment $keyText Cyan))
        $segs.Add((New-UiSegment $label Gray))

        $usedLen += [int]$keyText.Length + [int]$label.Length
    }

    if ($RightText) {
        $rText = "{0}" -f $RightText
        [int]$pad = [int]($canvas.SafeWidth - $usedLen - [int]$rText.Length - [int]$margin.Length)
        if ($pad -gt 0) {
            $segs.Add((New-UiSegment (" " * $pad) DarkGray))
            $segs.Add((New-UiSegment $rText Yellow))
        } elseif ($canvas.SafeWidth -gt ($usedLen + 4)) {
            # Truncate right text if tight
            [int]$avail = $canvas.SafeWidth - $usedLen - $margin.Length
            if ($avail -gt 4) {
                $truncated = $rText.Substring(0, [math]::Min($avail, $rText.Length))
                $segs.Add((New-UiSegment (" " * [math]::Max(1, $avail - $truncated.Length)) DarkGray))
                $segs.Add((New-UiSegment $truncated Yellow))
            }
        }
    }

    New-UiLine $segs.ToArray()
}

# =================================================================
# Canonical Design Tokens & Standardized Footer Primitive
# =================================================================

$script:WorkCtlDesignTokens = @{
    # Padding / Spacing tokens
    PaddingX               = 2
    PaddingY               = 1
    SectionGap             = 1
    ColumnGap              = 2
    LabelGap               = 2
    PanelPadding           = 1
    LabelWidth             = 16
    PreviewGap             = 2
    PreviewMinWidth        = 40
    UseBackgroundSelection = $false

    # Semantic Colors (Foreground only - canvas inherits terminal default)
    Primary                = [ConsoleColor]::White       # Primary content, active titles
    Secondary              = [ConsoleColor]::Gray        # Legible descriptions, active table cells
    Muted                  = [ConsoleColor]::DarkGray    # Metadata, inactive indicators, table headers
    Disabled               = [ConsoleColor]::DarkGray    # Inactive actions, unavailable items
    Identity               = [ConsoleColor]::Cyan        # Brand, cursor, active selection, keybinds
    Warning                = [ConsoleColor]::Yellow      # Warnings, guarded status, confirmations
    Success                = [ConsoleColor]::Green       # Running, healthy, available, active ports
    Protected              = [ConsoleColor]::Magenta     # Protected workloads, security boundaries
    Danger                 = [ConsoleColor]::Red         # Errors, critical hardware conflicts

    # Legacy color aliases for backward compatibility
    Cyan                   = [ConsoleColor]::Cyan
    White                  = [ConsoleColor]::White
    DarkGray               = [ConsoleColor]::DarkGray
    Green                  = [ConsoleColor]::Green
    Yellow                 = [ConsoleColor]::Yellow
    Magenta                = [ConsoleColor]::Magenta
    Red                    = [ConsoleColor]::Red

    # Box Drawing Primitives (Unicode with graceful ASCII fallback)
    BoxHorizontal          = [string][char]0x2500
    BoxVertical            = [string][char]0x2502
    BoxTopLeft             = [string][char]0x250C
    BoxTopRight            = [string][char]0x2510
    BoxBottomLeft          = [string][char]0x2514
    BoxBottomRight         = [string][char]0x2518
    BoxTDown               = [string][char]0x252C
    BoxTUp                 = [string][char]0x2534
    BoxTLeft               = [string][char]0x2524
    BoxTRight              = [string][char]0x251C
    BoxCross               = [string][char]0x253C
}

function Get-WorkCtlBoxChar([string]$Name) {
    if ($env:WORKCTL_ASCII_ONLY -eq "1") {
        switch ($Name) {
            "BoxHorizontal"  { return "-" }
            "BoxVertical"    { return "|" }
            default          { return "+" }
        }
    }
    if ($script:WorkCtlDesignTokens.ContainsKey($Name)) {
        return $script:WorkCtlDesignTokens[$Name]
    }
    return "-"
}

function New-WorkCtlFooter {
    param(
        [Parameter(Mandatory=$true)][object[]]$Actions,
        [string]$Context = "",
        [string]$RightText = "",
        [int]$Width = 0
    )

    $canvas = Get-WorkCtlCanvas -Width $Width
    $w = $canvas.Width

    $items = New-Object System.Collections.Generic.List[hashtable]

    $arrowKey = "$([char]0x2191)$([char]0x2193)"
    $leftRightKey = "$([char]0x2190)$([char]0x2192)"
    if ($env:WORKCTL_ASCII_ONLY -eq "1") {
        $arrowKey = "UP/DN"
        $leftRightKey = "L/R"
    }

    foreach ($act in $Actions) {
        if ($act -is [hashtable]) {
            $items.Add($act)
        } elseif ($act -is [string]) {
            switch ($act.ToUpperInvariant()) {
                "MOVE"     { $items.Add(@{ Key = $arrowKey;      Label = "Move" }) }
                "SCROLL"   { $items.Add(@{ Key = $arrowKey;      Label = "Scroll" }) }
                "PAGE"     { $items.Add(@{ Key = "PgUp/Dn";      Label = "Page" }) }
                "SECTION"  { $items.Add(@{ Key = $leftRightKey;  Label = "Section" }) }
                "OPEN"     { $items.Add(@{ Key = "Enter";        Label = "Open" }) }
                "READ"     { $items.Add(@{ Key = "Enter";        Label = "Read" }) }
                "SEARCH"   { $items.Add(@{ Key = "/";            Label = "Search" }) }
                "COMMAND"  { $items.Add(@{ Key = ":";            Label = "Command" }) }
                "HELP"     { $items.Add(@{ Key = "?";            Label = "Help" }) }
                "BACK"     { $items.Add(@{ Key = "Esc";          Label = "Back" }) }
                "CATALOG"  { $items.Add(@{ Key = "Esc";          Label = "Catalog" }) }
                "EXIT"     { $items.Add(@{ Key = "Q";            Label = "Exit" }) }
                "REDRAW"   { $items.Add(@{ Key = "R";            Label = "Redraw" }) }
                "REFRESH"  { $items.Add(@{ Key = "R";            Label = "Refresh" }) }
                "RUN"      { $items.Add(@{ Key = "R";            Label = "Run Example" }) }
                "DETAILS"  { $items.Add(@{ Key = "D";            Label = "Details" }) }
                "FILTER"   { $items.Add(@{ Key = "Tab";          Label = "Filter" }) }
                "START"    { $items.Add(@{ Key = "S";            Label = "Start" }) }
                "STOP"     { $items.Add(@{ Key = "X";            Label = "Stop" }) }
                "RESTART"  { $items.Add(@{ Key = "R";            Label = "Restart" }) }
                default    { $items.Add(@{ Key = $act;           Label = $act }) }
            }
        }
    }

    $right = if ($RightText) { $RightText } elseif ($Context) { "Context: " + $Context } else { "" }
    return New-WorkCtlFooterLine -Items $items.ToArray() -RightText $right -Width $w
}

function New-WorkCtlTableModel {
    param(
        [Parameter(Mandatory=$true)][hashtable[]]$Columns,
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [int]$SelectedIndex = 0,
        [int]$ScrollOffset = 0,
        [int]$ViewportHeight = 10,
        [int]$Width = 0,
        [bool]$ShowCursor = $true
    )

    $canvas = Get-WorkCtlCanvas -Width $Width
    [int]$usableWidth = $canvas.UsableContentWidth
    $margin = $canvas.Margin

    [int]$cursorReserve = if ($ShowCursor) { 2 } else { 0 }
    [int]$colGap = 2
    [int]$availWidth = [math]::Max(10, $usableWidth - $cursorReserve)

    $cols = New-Object System.Collections.Generic.List[hashtable]
    foreach ($c in $Columns) {
        $minW = if ($c.ContainsKey("MinWidth") -and $c.MinWidth) { [int]$c.MinWidth } else { [math]::Max(4, [string]$c.Header.Length) }
        $minW = [math]::Max(2, $minW)

        $prefW = if ($c.ContainsKey("PreferredWidth") -and $c.PreferredWidth) { [int]$c.PreferredWidth } else { [math]::Max(6, [string]$c.Header.Length + 2) }
        $maxW = if ($c.ContainsKey("MaxWidth") -and $c.MaxWidth) { [int]$c.MaxWidth } else { 999 }
        $prio = if ($c.ContainsKey("Priority") -and $null -ne $c.Priority) { [int]$c.Priority } else { 2 }
        $align = if ($c.ContainsKey("Align") -and $c.Align -eq "Right") { "Right" } else { "Left" }

        $cols.Add(@{
            Header         = [string]$c.Header
            Key            = [string]$c.Key
            MinWidth       = $minW
            PreferredWidth = $prefW
            MaxWidth       = $maxW
            Priority       = $prio
            Align          = $align
            Formatter      = $c.Formatter
            AllocatedWidth = 0
            Included       = $false
        })
    }

    $priority1Cols = @($cols | Where-Object { $_.Priority -eq 1 })
    $otherCols = @($cols | Where-Object { $_.Priority -gt 1 } | Sort-Object Priority)

    [int]$usedWidth = 0
    foreach ($c in $priority1Cols) {
        $gap = if ($usedWidth -gt 0) { $colGap } else { 0 }
        $c.AllocatedWidth = $c.MinWidth
        $c.Included = $true
        $usedWidth += ($c.AllocatedWidth + $gap)
    }

    if ($usedWidth -gt $availWidth -and $priority1Cols.Count -gt 0) {
        $excess = $usedWidth - $availWidth
        foreach ($c in $priority1Cols) {
            if ($excess -le 0) { break }
            $shrink = [math]::Min($excess, [math]::Max(0, $c.AllocatedWidth - 4))
            $c.AllocatedWidth -= $shrink
            $excess -= $shrink
        }
        $usedWidth = $availWidth
    }

    [int]$remWidth = [math]::Max(0, $availWidth - $usedWidth)
    foreach ($c in $otherCols) {
        $needed = $c.MinWidth + $colGap
        if ($remWidth -ge $needed) {
            $c.AllocatedWidth = $c.MinWidth
            $c.Included = $true
            $remWidth -= $needed
            $usedWidth += $needed
        } else {
            $c.Included = $false
        }
    }

    $includedCols = @($cols | Where-Object { $_.Included })
    if ($remWidth -gt 0 -and $includedCols.Count -gt 0) {
        foreach ($c in $includedCols) {
            if ($remWidth -le 0) { break }
            $growRoom = [math]::Min($c.MaxWidth, $c.PreferredWidth) - $c.AllocatedWidth
            if ($growRoom -gt 0) {
                $give = [math]::Min($remWidth, $growRoom)
                $c.AllocatedWidth += $give
                $remWidth -= $give
            }
        }
        if ($remWidth -gt 0) {
            $lastCol = $includedCols[$includedCols.Count - 1]
            $give = [math]::Min($remWidth, [math]::Max(0, $lastCol.MaxWidth - $lastCol.AllocatedWidth))
            $lastCol.AllocatedWidth += $give
        }
    }

    $headerSegs = New-Object System.Collections.Generic.List[object]
    $headerSegs.Add((New-UiSegment $margin DarkGray))
    if ($ShowCursor) { $headerSegs.Add((New-UiSegment "  " DarkGray)) }

    for ($ci = 0; $ci -lt $includedCols.Count; $ci++) {
        $c = $includedCols[$ci]
        $w = $c.AllocatedWidth
        $ht = $c.Header
        if ($ht.Length -gt $w) { $ht = $ht.Substring(0, $w) }
        $fmt = if ($c.Align -eq "Right") { "{0,$w}" } else { "{0,-$w}" }
        $headerSegs.Add((New-UiSegment ($fmt -f $ht) DarkGray))
        if ($ci -lt ($includedCols.Count - 1)) {
            $headerSegs.Add((New-UiSegment (" " * $colGap) DarkGray))
        }
    }
    $headerLine = New-UiLine $headerSegs.ToArray()

    [int]$totalTableWidth = $cursorReserve
    for ($ci = 0; $ci -lt $includedCols.Count; $ci++) {
        $totalTableWidth += $includedCols[$ci].AllocatedWidth
        if ($ci -lt ($includedCols.Count - 1)) { $totalTableWidth += $colGap }
    }
    [int]$sepWidth = [math]::Min($canvas.SafeWidth - ($canvas.MarginLength * 2), $totalTableWidth)
    $sepChar = Get-WorkCtlBoxChar "BoxHorizontal"
    $sepLine = New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment ($sepChar * $sepWidth) DarkGray)
    )

    [int]$totalRows = $Rows.Count
    [int]$budget = [math]::Max(1, $ViewportHeight)
    $vp = Get-WorkCtlViewport -Total $totalRows -Selected $SelectedIndex -Height $budget -CurrentOffset $ScrollOffset

    $dataLines = New-Object System.Collections.Generic.List[object]
    for ($r = $vp.Offset; $r -le $vp.End -and $r -lt $totalRows; $r++) {
        $rowObj = $Rows[$r]
        $isSel = ($r -eq $SelectedIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $cursorCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }

        $rowSegs = New-Object System.Collections.Generic.List[object]
        $rowSegs.Add((New-UiSegment $margin DarkGray))
        if ($ShowCursor) { $rowSegs.Add((New-UiSegment $cursor $cursorCol)) }

        for ($ci = 0; $ci -lt $includedCols.Count; $ci++) {
            $c = $includedCols[$ci]
            $w = $c.AllocatedWidth
            $val = $null

            if ($c.Formatter -is [scriptblock]) {
                $val = & $c.Formatter $rowObj $c
            } elseif ($rowObj -is [hashtable] -and $rowObj.ContainsKey($c.Key)) {
                $val = $rowObj[$c.Key]
            } elseif ($rowObj -and $rowObj.PSObject.Properties[$c.Key]) {
                $val = $rowObj.($c.Key)
            } else {
                $val = ""
            }

            $cellText = ""
            $cellCol = if ($isSel) { [ConsoleColor]::White } else { [ConsoleColor]::Gray }
            if ($val -is [hashtable] -or ($val -and $val.PSObject.Properties["Text"])) {
                $cellText = [string]$val.Text
                if ($val.Color) { $cellCol = $val.Color }
            } else {
                $cellText = [string]$val
            }

            if ($cellText.Length -gt $w) {
                if ($w -gt 2) {
                    $cellText = $cellText.Substring(0, $w - 2) + ".."
                } else {
                    $cellText = $cellText.Substring(0, $w)
                }
            }

            $fmt = if ($c.Align -eq "Right") { "{0,$w}" } else { "{0,-$w}" }
            $paddedText = $fmt -f $cellText
            $rowSegs.Add((New-UiSegment $paddedText $cellCol))

            if ($ci -lt ($includedCols.Count - 1)) {
                $rowSegs.Add((New-UiSegment (" " * $colGap) DarkGray))
            }
        }
        $dataLines.Add((New-UiLine $rowSegs.ToArray()))
    }

    return [PSCustomObject]@{
        HeaderLine    = $headerLine
        SeparatorLine = $sepLine
        DataLines     = $dataLines.ToArray()
        Viewport      = $vp
        IncludedCols  = $includedCols
    }
}

function Complete-WorkCtlCanvasFrame {
    param(
        [System.Collections.Generic.List[object]]$FrameList,
        $Canvas,
        $FooterLine,
        [int]$Width = 0
    )
    [int]$w = if ($Width -gt 0) { $Width } else { $Canvas.Width }
    [int]$safeW = $Canvas.SafeWidth

    if ($FrameList.Count -gt $Canvas.FooterSepRow) {
        $clamped = New-Object System.Collections.Generic.List[object]
        for ($k = 0; $k -lt $Canvas.FooterSepRow; $k++) {
            $clamped.Add($FrameList[$k])
        }
        $FrameList = $clamped
    } else {
        for ($pad = $FrameList.Count; $pad -lt $Canvas.FooterSepRow; $pad++) {
            $FrameList.Add((New-UiLine @((New-UiSegment ""))))
        }
    }
    $FrameList.Add((New-WorkCtlSeparatorLine -Width $w))
    $FrameList.Add($FooterLine)

    for ($idx = 0; $idx -lt $FrameList.Count; $idx++) {
        $line = $FrameList[$idx]
        if ($line -and $line.Segments) {
            $len = 0
            foreach ($s in $line.Segments) { $len += $s.Text.Length }
            if ($len -gt $safeW) {
                $clampedSegs = New-Object System.Collections.Generic.List[object]
                $used = 0
                foreach ($s in $line.Segments) {
                    if ($used -ge $safeW) { break }
                    $rem = $safeW - $used
                    if ($s.Text.Length -gt $rem) {
                        $clampedSegs.Add((New-UiSegment -Text $s.Text.Substring(0, $rem) -Foreground $s.Foreground -Background $s.Background))
                        $used += $rem
                        break
                    } else {
                        $clampedSegs.Add($s)
                        $used += $s.Text.Length
                    }
                }
                $FrameList[$idx] = New-UiLine $clampedSegs.ToArray()
            }
        }
    }
    return $FrameList.ToArray()
}


# =================================================================
# Shared Telemetry Background Worker Singleton
# =================================================================

function Start-WorkCtlTelemetryWorker {
    param([int]$IntervalMs = 1500)

    [System.Threading.Monitor]::Enter($script:WorkCtlSharedTelemetryLock)
    try {
        if ($script:WorkCtlSharedTelemetryWorker -and $script:WorkCtlSharedTelemetryWorker.Sync -and $script:WorkCtlSharedTelemetryWorker.Sync.Running) {
            $script:WorkCtlSharedTelemetryRefCount++
            return $script:WorkCtlSharedTelemetryWorker
        }

        $sync = [hashtable]::Synchronized(@{
            Running = $true
            Snapshot = $null
            Error = $null
            IntervalMs = $IntervalMs
            LastUpdated = [datetime]::MinValue
        })

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("sync", $sync)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        $resPath = Join-Path $script:UiModuleDir "resources.ps1"
        if (!(Test-Path -LiteralPath $resPath)) {
            $resPath = "E:\TOOLS\WorkstationControl\modules\resources.ps1"
        }

        $rs.SessionStateProxy.SetVariable("resModulePath", $resPath)

        $scriptBlock = {
            if ($resModulePath -and (Test-Path -LiteralPath $resModulePath)) {
                . $resModulePath
            }
            while ($sync.Running) {
                try {
                    $s = Get-WorkCtlSnapshot
                    $sync.Snapshot = $s
                    $sync.LastUpdated = [datetime]::UtcNow
                    $sync.Error = $null
                } catch {
                    $sync.Error = $_.Exception.Message
                }

                $slept = 0
                while ($slept -lt $sync.IntervalMs -and $sync.Running) {
                    [System.Threading.Thread]::Sleep(50)
                    $slept += 50
                }
            }
        }

        $asyncResult = $ps.AddScript($scriptBlock).BeginInvoke()

        $worker = [PSCustomObject]@{
            Sync = $sync
            Runspace = $rs
            PowerShell = $ps
            AsyncResult = $asyncResult
        }

        $script:WorkCtlSharedTelemetryWorker = $worker
        $script:WorkCtlSharedTelemetryRefCount = 1
        return $worker
    } catch {
        return $null
    } finally {
        [System.Threading.Monitor]::Exit($script:WorkCtlSharedTelemetryLock)
    }
}

function Stop-WorkCtlTelemetryWorker($Worker, [switch]$Force) {
    [System.Threading.Monitor]::Enter($script:WorkCtlSharedTelemetryLock)
    try {
        if (!$script:WorkCtlSharedTelemetryWorker) { return }

        $script:WorkCtlSharedTelemetryRefCount--
        if ($script:WorkCtlSharedTelemetryRefCount -le 0 -or $Force) {
            $w = $script:WorkCtlSharedTelemetryWorker
            $script:WorkCtlSharedTelemetryWorker = $null
            $script:WorkCtlSharedTelemetryRefCount = 0

            try {
                if ($w.Sync) { $w.Sync.Running = $false }
            } catch {}

            Start-Sleep -Milliseconds 60

            try {
                if ($w.PowerShell) { $w.PowerShell.Dispose() }
            } catch {}

            try {
                if ($w.Runspace) {
                    $w.Runspace.Close()
                    $w.Runspace.Dispose()
                }
            } catch {}
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:WorkCtlSharedTelemetryLock)
    }
}

function Get-WorkCtlTelemetryWorker {
    return $script:WorkCtlSharedTelemetryWorker
}

# =================================================================
# Viewport Budget & Chrome Pinning
# =================================================================

function Get-WorkCtlContentBudget {
    [OutputType([int])]
    param(
        [int]$ReservedHeaderRows = 4,
        [int]$ReservedFooterRows = 2,
        [int]$Height = 0
    )

    [int]$h = [int]$Height
    if ($h -le 0) {
        $h = [int](Get-WorkCtlWindowHeight)
    }

    [int]$available = $h - [int]$ReservedHeaderRows - [int]$ReservedFooterRows
    return [int][math]::Max(3, $available)
}

# =================================================================
# Interactive Command Line Reader with Inline Suggestions & History
# =================================================================

function Read-WorkCtlCommandLine {
    param(
        [string]$PromptText = "workctl > ",
        [string]$InitialText = "",
        [string[]]$History = @(),
        [scriptblock]$CompletionHook = $null,
        [scriptblock]$SuggestionHook = $null,
        [int]$Row = -1
    )

    [int]$width = [int][math]::Max(20, [int](Get-WorkCtlWindowWidth) - 1)
    [int]$winHeight = [int](Get-WorkCtlWindowHeight)
    [int]$promptRow = if ($Row -lt 0) { [int][math]::Max(0, [int]($winHeight - 1)) } else { [int]$Row }

    $buffer = [string]$InitialText
    [int]$cursorPos = [int]$buffer.Length
    $historyList = @($History)
    [int]$historyIndex = [int]$historyList.Count

    try {
        [Console]::CursorVisible = $true
    } catch {}

    try {
        while ($true) {
            # Compute ghost suggestion or discovery hint
            $ghostText = ""
            $suggestedFull = ""
            $isHint = $false

            if ($buffer.Trim().Length -gt 0) {
                if ($SuggestionHook) {
                    try {
                        $suggestedFull = [string](& $SuggestionHook $buffer)
                        if ($suggestedFull -and $suggestedFull.StartsWith($buffer, [System.StringComparison]::OrdinalIgnoreCase) -and $suggestedFull.Length -gt $buffer.Length) {
                            $ghostText = $suggestedFull.Substring($buffer.Length)
                        }
                    } catch {}
                }
            } else {
                # Empty buffer -> show compact command discovery hint
                $ghostText = "(e.g. workloads, powertoys, media, tools, ls, cd, help | Esc)"
                $isHint = $true
            }

            # Position cursor at prompt row
            try {
                [Console]::SetCursorPosition(0, $promptRow)
            } catch {}

            # Render Prompt
            Write-Host $PromptText -ForegroundColor Cyan -BackgroundColor Black -NoNewline
            Write-Host $buffer -ForegroundColor White -BackgroundColor Black -NoNewline

            # Render ghost suggestion if at end of input
            [int]$ghostRenderedLen = 0
            if ($ghostText -and $cursorPos -eq $buffer.Length) {
                $ghostColor = if ($isHint) { [ConsoleColor]::DarkGray } else { [ConsoleColor]::DarkCyan }
                Write-Host $ghostText -ForegroundColor $ghostColor -BackgroundColor Black -NoNewline
                $ghostRenderedLen = [int]$ghostText.Length
            }

            # Pad remainder of line
            [int]$usedSoFar = [int]$PromptText.Length + [int]$buffer.Length + $ghostRenderedLen
            [int]$remainingSpaces = [int][math]::Max(0, [int]($width - $usedSoFar))
            if ($remainingSpaces -gt 0) {
                Write-Host (" " * $remainingSpaces) -ForegroundColor Gray -BackgroundColor Black -NoNewline
            }

            # Set hardware cursor to logical position
            try {
                [int]$screenCursorX = [int][math]::Min([int]($width - 1), [int]($PromptText.Length + $cursorPos))
                [Console]::SetCursorPosition($screenCursorX, $promptRow)
            } catch {}

            # Read single key
            $key = $null
            try {
                $key = [Console]::ReadKey($true)
            } catch {
                return [PSCustomObject]@{ Cancelled = $true; Command = "" }
            }

            # Enter
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $trimmed = $buffer.Trim()
                if ($trimmed.Length -eq 0) {
                    return [PSCustomObject]@{
                        Cancelled = $true
                        Command = ""
                    }
                }
                return [PSCustomObject]@{
                    Cancelled = $false
                    Command = $trimmed
                }
            }

            # Escape or Ctrl+C
            if ($key.Key -eq [ConsoleKey]::Escape -or ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))) {
                return [PSCustomObject]@{
                    Cancelled = $true
                    Command = ""
                }
            }

            # Backspace
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($cursorPos -gt 0) {
                    $buffer = $buffer.Substring(0, $cursorPos - 1) + $buffer.Substring($cursorPos)
                    $cursorPos--
                }
                continue
            }

            # Delete
            if ($key.Key -eq [ConsoleKey]::Delete) {
                if ($cursorPos -lt $buffer.Length) {
                    $buffer = $buffer.Substring(0, $cursorPos) + $buffer.Substring($cursorPos + 1)
                }
                continue
            }

            # Left Arrow
            if ($key.Key -eq [ConsoleKey]::LeftArrow) {
                if ($cursorPos -gt 0) {
                    $cursorPos--
                }
                continue
            }

            # Right Arrow
            if ($key.Key -eq [ConsoleKey]::RightArrow) {
                if ($cursorPos -lt $buffer.Length) {
                    $cursorPos++
                } elseif (!$isHint -and $ghostText) {
                    # Accept inline ghost suggestion on RightArrow!
                    $buffer = $suggestedFull
                    $cursorPos = [int]$buffer.Length
                }
                continue
            }

            # Home
            if ($key.Key -eq [ConsoleKey]::Home) {
                $cursorPos = 0
                continue
            }

            # End
            if ($key.Key -eq [ConsoleKey]::End) {
                $cursorPos = [int]$buffer.Length
                continue
            }

            # Ctrl+A (Beginning of line)
            if ($key.Key -eq [ConsoleKey]::A -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                $cursorPos = 0
                continue
            }

            # Ctrl+E (End of line)
            if ($key.Key -eq [ConsoleKey]::E -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                $cursorPos = [int]$buffer.Length
                continue
            }

            # Ctrl+U (Clear line)
            if ($key.Key -eq [ConsoleKey]::U -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                $buffer = ""
                $cursorPos = 0
                continue
            }

            # Ctrl+W (Delete backward word)
            if ($key.Key -eq [ConsoleKey]::W -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if ($cursorPos -gt 0) {
                    $prefix = $buffer.Substring(0, $cursorPos)
                    $suffix = $buffer.Substring($cursorPos)
                    $trimmedPrefix = $prefix.TrimEnd()
                    $lastSpace = $trimmedPrefix.LastIndexOfAny(@([char]' ', [char]'\', [char]'/', [char]':'))
                    if ($lastSpace -ge 0) {
                        $newPrefix = $trimmedPrefix.Substring(0, $lastSpace + 1)
                    } else {
                        $newPrefix = ""
                    }
                    $buffer = $newPrefix + $suffix
                    $cursorPos = [int]$newPrefix.Length
                }
                continue
            }

            # Tab completion
            if ($key.Key -eq [ConsoleKey]::Tab) {
                if (!$isHint -and $ghostText -and $cursorPos -eq $buffer.Length) {
                    $buffer = $suggestedFull
                    $cursorPos = [int]$buffer.Length
                } elseif ($CompletionHook) {
                    try {
                        $matches = @(& $CompletionHook $buffer)
                        if ($matches.Count -eq 1) {
                            $buffer = [string]$matches[0]
                            if (!$buffer.EndsWith(" ")) { $buffer += " " }
                            $cursorPos = [int]$buffer.Length
                        } elseif ($matches.Count -gt 1) {
                            # Auto-complete longest common prefix
                            $common = [string]$matches[0]
                            for ($m = 1; $m -lt $matches.Count; $m++) {
                                while ($matches[$m].IndexOf($common, [System.StringComparison]::OrdinalIgnoreCase) -ne 0 -and $common.Length -gt 0) {
                                    $common = $common.Substring(0, $common.Length - 1)
                                }
                            }
                            if ($common.Length -gt $buffer.Length) {
                                $buffer = $common
                                $cursorPos = [int]$buffer.Length
                            }
                        }
                    } catch {}
                }
                continue
            }

            # History Up
            if ($key.Key -eq [ConsoleKey]::UpArrow) {
                if ($historyList.Count -gt 0 -and $historyIndex -gt 0) {
                    $historyIndex--
                    $buffer = [string]$historyList[$historyIndex]
                    $cursorPos = [int]$buffer.Length
                }
                continue
            }

            # History Down
            if ($key.Key -eq [ConsoleKey]::DownArrow) {
                if ($historyIndex -lt ($historyList.Count - 1)) {
                    $historyIndex++
                    $buffer = [string]$historyList[$historyIndex]
                    $cursorPos = [int]$buffer.Length
                } else {
                    $historyIndex = [int]$historyList.Count
                    $buffer = ""
                    $cursorPos = 0
                }
                continue
            }

            # Normal printable characters
            if ($key.KeyChar -ge [char]32 -and $key.KeyChar -le [char]126) {
                if ($buffer.Length -lt 200) {
                    $buffer = $buffer.Substring(0, $cursorPos) + $key.KeyChar + $buffer.Substring($cursorPos)
                    $cursorPos++
                }
            }
        }
    } finally {
        try {
            [Console]::CursorVisible = $false
        } catch {}
    }
}

# =================================================================
# Modal Confirmation & Governance Alert Dialog Frame
# =================================================================

function New-WorkCtlConfirmDialogFrame {
    param(
        [string]$Title = "CONFIRMATION REQUIRED",
        [string[]]$MessageLines = @(),
        [string]$Policy = "CONFIRM", # "CONFIRM" or "EXPLICIT"
        [string]$WorkloadName = "",
        [int]$Width = 0,
        [int]$Height = 0
    )

    [int]$w = [int]$Width
    [int]$h = [int]$Height
    if ($w -le 0) { $w = [int](Get-WorkCtlWindowWidth) }
    if ($h -le 0) { $h = [int](Get-WorkCtlWindowHeight) }

    [int]$boxWidth = [int][math]::Min(72, [int][math]::Max(40, [int]($w - 6)))
    [int]$boxLeftPad = [int][math]::Max(1, [int][math]::Floor([double]($w - $boxWidth) / 2.0))
    $leftPadStr = " " * $boxLeftPad

    $borderCol = if ($Policy -ieq "EXPLICIT") { [ConsoleColor]::Magenta } else { [ConsoleColor]::Yellow }
    $titleCol = if ($Policy -ieq "EXPLICIT") { [ConsoleColor]::Magenta } else { [ConsoleColor]::Yellow }

    $lines = New-Object System.Collections.Generic.List[object]

    # Top padding
    [int]$dialogHeight = 8 + [int]$MessageLines.Count
    [int]$topPaddingRows = [int][math]::Max(1, [int][math]::Floor([double]($h - $dialogHeight) / 2.0))
    for ($p = 0; $p -lt $topPaddingRows; $p++) {
        $lines.Add((New-UiLine @((New-UiSegment ""))))
    }

    # Box Top
    $topRule = "+" + ("-" * ($boxWidth - 2)) + "+"
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment $topRule $borderCol)
    )))

    # Box Title
    $titlePadded = "  " + $Title.ToUpperInvariant()
    [int]$titleSpace = [int][math]::Max(0, [int]($boxWidth - 2 - $titlePadded.Length))
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment "|" $borderCol),
        (New-UiSegment $titlePadded $titleCol),
        (New-UiSegment (" " * $titleSpace) White),
        (New-UiSegment "|" $borderCol)
    )))

    # Separator
    $midRule = "|" + ("-" * ($boxWidth - 2)) + "|"
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment $midRule $borderCol)
    )))

    # Blank inside
    $blankInside = "|" + (" " * ($boxWidth - 2)) + "|"
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment $blankInside $borderCol)
    )))

    # Message lines
    foreach ($msg in @($MessageLines)) {
        $mText = "  " + $msg
        if ($mText.Length -gt ($boxWidth - 4)) {
            $mText = $mText.Substring(0, $boxWidth - 7) + "..."
        }
        [int]$mSpace = [int][math]::Max(0, [int]($boxWidth - 2 - $mText.Length))
        $lines.Add((New-UiLine @(
            (New-UiSegment $leftPadStr DarkGray),
            (New-UiSegment "|" $borderCol),
            (New-UiSegment $mText White),
            (New-UiSegment (" " * $mSpace) White),
            (New-UiSegment "|" $borderCol)
        )))
    }

    # Blank inside
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment $blankInside $borderCol)
    )))

    # Actions line
    $actionText = if ($Policy -ieq "EXPLICIT") {
        "  [ESC / ENTER] Acknowledge & Return (Mutations are blocked)"
    } else {
        "  [Y] Confirm Action        [N / ESC] Cancel (Default)"
    }
    $actCol = if ($Policy -ieq "EXPLICIT") { [ConsoleColor]::Magenta } else { [ConsoleColor]::Cyan }
    [int]$actSpace = [int][math]::Max(0, [int]($boxWidth - 2 - $actionText.Length))
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment "|" $borderCol),
        (New-UiSegment $actionText $actCol),
        (New-UiSegment (" " * $actSpace) White),
        (New-UiSegment "|" $borderCol)
    )))

    # Box Bottom
    $botRule = "+" + ("-" * ($boxWidth - 2)) + "+"
    $lines.Add((New-UiLine @(
        (New-UiSegment $leftPadStr DarkGray),
        (New-UiSegment $botRule $borderCol)
    )))

    # Pad bottom so total lines match window height - 1
    [int]$curCount = [int]$lines.Count
    [int]$targetHeight = [int][math]::Max(10, [int]($h - 1))
    for ($b = $curCount; $b -lt $targetHeight; $b++) {
        $lines.Add((New-UiLine @((New-UiSegment ""))))
    }

    $lines.ToArray()
}

# =================================================================
# FIXED UI REGIONS / COMPOSITOR
# =================================================================
function New-WorkCtlComposedFrame {
    param(
        [object[]]$HeaderLines,
        [object[]]$StatusLines = @(),
        [object[]]$ContentLines = @(),
        [object[]]$PreviewLines = @(),
        [object]$NotificationLine = $null,
        [object]$FooterLine = $null,
        [int]$Width = 0,
        [int]$Height = 0
    )

    [int]$w = if ($Width -gt 0) { $Width } else { (Get-WorkCtlWindowWidth) }
    [int]$h = if ($Height -gt 0) { $Height } else { (Get-WorkCtlWindowHeight) }

    # Guard: Minimum terminal size invariant (Requirement 8)
    if ($w -lt 50 -or $h -lt 12) {
        $tooSmall = New-Object System.Collections.Generic.List[object]
        $tooSmall.Add((New-UiLine @((New-UiSegment "WORKCTL > TERMINAL TOO SMALL" Yellow))))
        $tooSmall.Add((New-WorkCtlSeparatorLine -Color Red -Width $w))
        $tooSmall.Add((New-UiLine @((New-UiSegment ("Current window: {0} x {1}" -f $w, $h) White))))
        $tooSmall.Add((New-UiLine @((New-UiSegment "Minimum required: 50 x 12" DarkCyan))))
        $tooSmall.Add((New-UiLine @((New-UiSegment "Please resize your terminal window to continue." DarkGray))))
        while ($tooSmall.Count -lt ($h - 1)) {
            $tooSmall.Add((New-UiLine @((New-UiSegment "" DarkGray))))
        }
        $tooSmall.Add((New-UiLine @((New-UiSegment "[Resize terminal window to resume]" Yellow))))
        return $tooSmall.ToArray()
    }

    $out = New-Object System.Collections.Generic.List[object]

    # 1. Header (fixed top)
    if ($HeaderLines) {
        foreach ($hl in $HeaderLines) { $out.Add($hl) }
    }

    # 2. Contextual Status / Metrics
    if ($StatusLines) {
        foreach ($sl in $StatusLines) { $out.Add($sl) }
    }

    # 3. Calculate fixed bottom budget
    # Footer = 1 line (ALWAYS last row $h - 1)
    # Notification = 1 line (if present)
    # Preview = PreviewLines.Count
    [int]$bottomCount = 1 # Footer
    if ($NotificationLine) { $bottomCount++ }
    if ($PreviewLines) { $bottomCount += $PreviewLines.Count }

    # Viewport budget for Content
    [int]$usedTop = $out.Count
    [int]$availableContentRows = [math]::Max(2, $h - $usedTop - $bottomCount)

    # 4. Content Lines (strictly clamped to viewport budget)
    [int]$contentAdded = 0
    if ($ContentLines) {
        for ($i = 0; $i -lt [math]::Min($availableContentRows, $ContentLines.Count); $i++) {
            $out.Add($ContentLines[$i])
            $contentAdded++
        }
    }

    # Fill any empty rows up to availableContentRows so preview/footer stay pinned
    while ($contentAdded -lt $availableContentRows) {
        $out.Add((New-UiLine @((New-UiSegment "" DarkGray))))
        $contentAdded++
    }

    # 5. Preview Card Lines
    if ($PreviewLines) {
        foreach ($pl in $PreviewLines) { $out.Add($pl) }
    }

    # 6. Notification Bar
    if ($NotificationLine) {
        $out.Add($NotificationLine)
    }

    # 7. Pinned Footer (GUARANTEED at row $h - 1)
    if ($FooterLine) {
        $out.Add($FooterLine)
    } else {
        $out.Add((New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DN"; Label = "Select" },
                @{ Key = "ENTER"; Label = "Open" },
                @{ Key = ":";     Label = "Command" },
                @{ Key = "/";     Label = "Palette" },
                @{ Key = "?";     Label = "Help" },
                @{ Key = "Q";     Label = "Quit" }
            ) -Width $w))
    }

    return $out.ToArray()
}

# =================================================================
# =================================================================
# SCREEN NAVIGATION STACK & CANONICAL ENTRY CONSTRUCTOR (P0)
# =================================================================

function New-WorkCtlNavigationEntry {
    param(
        [Parameter(Mandatory=$true)][string]$Screen,
        [string]$Context = "",
        [int]$SelectedIndex = 0,
        [int]$ScrollOffset = 0,
        [string]$Filter = "",
        [string]$Search = "",
        [string]$Category = "",
        [string]$SelectedEntity = "",
        $ContextData = $null,
        $SubsystemState = $null
    )

    [PSCustomObject]@{
        Screen         = $Screen
        Context        = $Context
        SelectedIndex  = $SelectedIndex
        ScrollOffset   = $ScrollOffset
        Filter         = $Filter
        Search         = $Search
        Category       = $Category
        SelectedEntity = $SelectedEntity
        ContextData    = $ContextData
        SubsystemState = $SubsystemState
    }
}

function Push-WorkCtlScreen {
    param(
        $State,
        [string]$NextScreen,
        [string]$TargetScreen,
        $AdditionalContext = $null
    )
    if (!$NextScreen -and $TargetScreen) {
        $NextScreen = $TargetScreen
    }
    if (!$State.ScreenStack) {
        $State.ScreenStack = New-Object System.Collections.Generic.Stack[object]
    }

    $selIdx = 0
    $scroll = 0
    $filter = ""
    $search = ""
    $cat = if ($State.SelectedCategory) { [string]$State.SelectedCategory } else { "ALL" }
    $entity = ""
    $subsystemState = $null

    switch ($State.Screen) {
        "shell-home" {
            $selIdx = [int]$State.SelectedHomeItem
        }
        "shell-workloads-list" {
            $selIdx = [int]$State.SelectedWorkloadIndex
            $scroll = [int]$State.WorkloadScroll
            $entity = [string]$State.SelectedWorkload
            $filter = [string]$State.WorkloadFilter
            $cat = [string]$State.SelectedWorkloadCategory
        }
        "shell-tools-list" {
            $selIdx = [int]$State.SelectedToolIndex
            $scroll = [int]$State.ToolScroll
            $entity = [string]$State.SelectedTool
            $filter = [string]$State.ToolFilter
        }
        "shell-storage" {
            $selIdx = [int]$State.SelectedStorageIndex
            $scroll = [int]$State.StorageScroll
            $entity = [string]$State.SelectedStorage
        }
        "shell-network" {
            $selIdx = [int]$State.SelectedNetworkIndex
        }
        "shell-network-ports" {
            $selIdx = [int]$State.SelectedPortIndex
            $scroll = [int]$State.PortScroll
            $filter = [string]$State.PortFilter
        }
        "shell-hardware" {
            $selIdx = [int]$State.SelectedHardwareIndex
            $scroll = [int]$State.HardwareScroll
        }
        "shell-services" {
            $selIdx = [int]$State.SelectedServiceIndex
            $scroll = [int]$State.ServiceScroll
            $entity = [string]$State.SelectedService
        }
        "shell-processes" {
            $selIdx = [int]$State.SelectedProcessIndex
            $scroll = [int]$State.ProcessScroll
            $entity = [string]$State.SelectedProcess
        }
        "shell-projects" {
            $selIdx = [int]$State.SelectedProjectIndex
            $scroll = [int]$State.ProjectScroll
            $entity = [string]$State.SelectedProject
        }
        "shell-agents" {
            if ($State.DevelopmentState) {
                $selIdx = [int]$State.DevelopmentState.SelectedAgentIndex
                $scroll = [int]$State.DevelopmentState.AgentScroll
            }
        }
        "shell-dev-menu" {
            if ($State.DevelopmentState) {
                $selIdx = [int]$State.DevelopmentState.SelectedMenuIndex
            }
        }
        "shell-search" {
            $selIdx = [int]$State.SelectedSearchIndex
            $scroll = [int]$State.SearchScroll
            $search = [string]$State.SearchQuery
        }
        "shell-guide" {
            if ($State.GuideState) {
                $subsystemState = $State.GuideState
            }
        }
    }

    $entry = New-WorkCtlNavigationEntry `
        -Screen $State.Screen `
        -Context ([string]$State.Context) `
        -SelectedIndex $selIdx `
        -ScrollOffset $scroll `
        -Filter $filter `
        -Search $search `
        -Category $cat `
        -SelectedEntity $entity `
        -ContextData $AdditionalContext `
        -SubsystemState $subsystemState

    $State.ScreenStack.Push($entry)
    $State.PreviousScreen = $State.Screen
    $State.Screen = $NextScreen
    if (Get-Command Import-WorkCtlSubsystem -ErrorAction SilentlyContinue) {
        $sub = switch -Wildcard ($NextScreen) {
            "shell-storage*"     { "storage" }
            "shell-hardware*"    { "hardware" }
            "shell-service*"     { "services" }
            "shell-process*"     { "processes" }
            "shell-dev*"         { "development" }
            "shell-project*"     { "development" }
            "shell-agent*"       { "development" }
            "shell-guide*"       { "guide" }
            "shell-tool*"        { "tools" }
            "shell-workload*"    { "workloads" }
            default              { $null }
        }
        if ($sub) {
            Import-WorkCtlSubsystem $sub
        }
    }
    $State.Dirty = $true
}

function Pop-WorkCtlScreen {
    param($State)
    if ($State.ScreenStack -and $State.ScreenStack.Count -gt 0) {
        $entry = $State.ScreenStack.Pop()
        $State.Screen = $entry.Screen
        $State.Context = $entry.Context
        $State.Dirty = $true

        $selIdx = if ($null -ne $entry.SelectedIndex) { $entry.SelectedIndex } else { 0 }
        $scroll = if ($null -ne $entry.ScrollOffset) { $entry.ScrollOffset } else { 0 }
        $entity = if ($null -ne $entry.SelectedEntity) { $entry.SelectedEntity } else { "" }
        $filter = if ($null -ne $entry.Filter) { $entry.Filter } else { "" }
        $cat = if ($null -ne $entry.Category) { $entry.Category } else { "" }

        # Legacy fallback if entry used old shape
        if ($null -eq $entry.SelectedIndex) {
            if ($null -ne $entry.SelectedHomeItem) { $selIdx = $entry.SelectedHomeItem }
            elseif ($null -ne $entry.SelectedWorkloadIndex) { $selIdx = $entry.SelectedWorkloadIndex }
            elseif ($null -ne $entry.SelectedToolIndex) { $selIdx = $entry.SelectedToolIndex }
            elseif ($null -ne $entry.SelectedServiceIndex) { $selIdx = $entry.SelectedServiceIndex }
            elseif ($null -ne $entry.SelectedProcessIndex) { $selIdx = $entry.SelectedProcessIndex }
            elseif ($null -ne $entry.SelectedProjectIndex) { $selIdx = $entry.SelectedProjectIndex }
            elseif ($null -ne $entry.SelectedStorageIndex) { $selIdx = $entry.SelectedStorageIndex }
        }

        switch ($entry.Screen) {
            "shell-home" {
                $State.SelectedHomeItem = $selIdx
            }
            "shell-workloads-list" {
                $State.SelectedWorkloadIndex = $selIdx
                $State.WorkloadScroll = $scroll
                if ($entity) { $State.SelectedWorkload = $entity }
                if ($filter) { $State.WorkloadFilter = $filter }
                if ($cat) { $State.SelectedWorkloadCategory = $cat }
            }
            "shell-tools-list" {
                $State.SelectedToolIndex = $selIdx
                $State.ToolScroll = $scroll
                if ($entity) { $State.SelectedTool = $entity }
                if ($filter) { $State.ToolFilter = $filter }
                if ($cat) { $State.SelectedCategory = $cat }
            }
            "shell-storage" {
                $State.SelectedStorageIndex = $selIdx
                $State.StorageScroll = $scroll
                if ($entity) { $State.SelectedStorage = $entity }
            }
            "shell-network" {
                $State.SelectedNetworkIndex = $selIdx
            }
            "shell-network-ports" {
                $State.SelectedPortIndex = $selIdx
                $State.PortScroll = $scroll
                if ($filter) { $State.PortFilter = $filter }
            }
            "shell-hardware" {
                $State.SelectedHardwareIndex = $selIdx
                $State.HardwareScroll = $scroll
            }
            "shell-services" {
                $State.SelectedServiceIndex = $selIdx
                $State.ServiceScroll = $scroll
                if ($entity) { $State.SelectedService = $entity }
                if ($cat) { $State.SelectedCategory = $cat }
            }
            "shell-processes" {
                $State.SelectedProcessIndex = $selIdx
                $State.ProcessScroll = $scroll
                if ($entity) { $State.SelectedProcess = $entity }
            }
            "shell-projects" {
                $State.SelectedProjectIndex = $selIdx
                $State.ProjectScroll = $scroll
                if ($entity) { $State.SelectedProject = $entity }
            }
            "shell-agents" {
                if (!$State.DevelopmentState) {
                    $State.DevelopmentState = Initialize-WorkCtlDevState
                }
                $State.DevelopmentState.SelectedAgentIndex = $selIdx
                $State.DevelopmentState.AgentScroll = $scroll
            }
            "shell-dev-menu" {
                if (!$State.DevelopmentState) {
                    $State.DevelopmentState = Initialize-WorkCtlDevState
                }
                $State.DevelopmentState.SelectedMenuIndex = $selIdx
            }
            "shell-search" {
                $State.SelectedSearchIndex = $selIdx
                $State.SearchScroll = $scroll
                if ($entry.Search) { $State.SearchQuery = $entry.Search }
                elseif ($entry.SearchQuery) { $State.SearchQuery = $entry.SearchQuery }
            }
            "shell-guide" {
                if ($entry.SubsystemState) {
                    $State.GuideState = $entry.SubsystemState
                }
            }
        }

        if ($cat) {
            $State.SelectedCategory = $cat
        }

        return $true
    }
    # Fallback to home if stack is empty
    $State.Screen = "shell-home"
    $State.Dirty = $true
    return $false
}

