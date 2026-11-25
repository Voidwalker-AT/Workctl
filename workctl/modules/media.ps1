# =================================================================
# WorkCtl v1.5 - Smart Media & Tool Control Plane Subsystem
# Architecture: WorkCtl Control Plane -> External Execution Backends
# =================================================================

$script:WorkCtlMediaConfigFile = "E:\TOOLS\WorkstationControl\config\media.json"
$script:WorkCtlMediaIndexFile  = "E:\TOOLS\WorkstationControl\runtime\media-index.json"
$script:CachedMediaIndex = $null
$script:CachedMediaIndexTime = [datetime]::MinValue

# -------------------------------------------------------------
# SECTION 1: MEDIA CONFIGURATION & ROOTS
# -------------------------------------------------------------

function Get-WorkCtlMediaConfig {
    if (Test-Path -LiteralPath $script:WorkCtlMediaConfigFile) {
        try {
            return (Get-Content -LiteralPath $script:WorkCtlMediaConfigFile -Raw | ConvertFrom-Json)
        } catch {}
    }

    # Built-in defaults
    [PSCustomObject]@{
        version = 1
        roots = @(
            [PSCustomObject]@{ path = "E:\TorlinkDownloads"; label = "Torlink Downloads"; category = "Downloads"; enabled = $true },
            [PSCustomObject]@{ path = "E:\Media"; label = "Media Library"; category = "Library"; enabled = $true },
            [PSCustomObject]@{ path = "C:\Users\hp\Videos"; label = "User Videos & Captures"; category = "Captures"; enabled = $true }
        )
        supportedExtensions = @(".mkv", ".mp4", ".avi", ".mov", ".webm", ".m4v", ".ts")
        cache = [PSCustomObject]@{
            indexPath = "runtime\media-index.json"
            cacheTtlSeconds = 300
            maxFileScanDepth = 4
        }
    }
}

# -------------------------------------------------------------
# SECTION 2: METADATA EXTRACTION ENGINE (FFPROBE + SHELL COM)
# -------------------------------------------------------------

function Get-MediaMetadataFromFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )

    if (!(Test-Path -LiteralPath $FilePath)) {
        return $null
    }

    $item = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if (!$item) { return $null }

    $meta = [ordered]@{
        Path = $item.FullName
        Filename = $item.Name
        Extension = $item.Extension.ToLowerInvariant()
        SizeBytes = $item.Length
        SizeFormatted = "{0:N2} MB" -f ($item.Length / 1MB)
        Modified = $item.LastWriteTimeUtc.ToString("o")
        ModifiedLocal = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        Title = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
        Container = $item.Extension.TrimStart('.').ToUpperInvariant()
        DurationSeconds = [double]0
        DurationFormatted = "-"
        Resolution = "-"
        VideoCodec = "-"
        AudioCodec = "-"
        AudioTracks = @()
        SubtitleTracks = @()
        BitrateKbps = [int]0
        FrameRate = "-"
        Backend = "Filesystem"
    }

    if ($item.Length -ge 1GB) {
        $meta.SizeFormatted = "{0:N2} GB" -f ($item.Length / 1GB)
    }

    # 1. Primary Engine: Sonarr bundled FFprobe
    $ffprobe = "C:\ProgramData\Sonarr\bin\ffprobe.exe"
    if (Test-Path -LiteralPath $ffprobe) {
        try {
            $raw = & $ffprobe -v quiet -print_format json -show_format -show_streams $FilePath
            if ($raw) {
                $probe = $raw | ConvertFrom-Json
                if ($probe -and $probe.format) {
                    $meta.Backend = "FFprobe"

                    if ($probe.format.duration) {
                        $sec = [double]$probe.format.duration
                        $meta.DurationSeconds = [math]::Round($sec, 1)
                        $ts = [timespan]::FromSeconds($sec)
                        if ($ts.TotalHours -ge 1) {
                            $meta.DurationFormatted = "{0:D2}:{1:D2}:{2:D2}" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
                        } else {
                            $meta.DurationFormatted = "{0:D2}:{1:D2}" -f $ts.Minutes, $ts.Seconds
                        }
                    }

                    if ($probe.format.bit_rate) {
                        $meta.BitrateKbps = [int]([double]$probe.format.bit_rate / 1000)
                    }

                    $rawTitle = if ($probe.format.tags -and $probe.format.tags.title) { [string]$probe.format.tags.title } else { "" }
                    if ($rawTitle -and $rawTitle -notmatch "^(www\.|\w+\.(com|org|net|ski|to|in|me|cc))\b") {
                        $meta.Title = $rawTitle.Trim()
                    } else {
                        # Clean title from filename
                        $clean = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                        $clean = $clean -replace "\[.*?\]", ""
                        $clean = $clean -replace "\(.*?\)", ""
                        $clean = $clean -replace "\b(1080p|720p|2160p|4k|bluray|web-dl|webrip|hdtc|dvdrip|remux|x264|x265|hevc|aac|dts|hdrip|hindi|english)\b", ""
                        $clean = $clean -replace "\b\d+(\.\d+)?\s*(gb|mb)\b", ""
                        $clean = $clean -replace "[\._]", " "
                        $clean = $clean.Trim()
                        if ($clean.Length -ge 2) { $meta.Title = $clean }
                    }

                    $audioList = New-Object System.Collections.Generic.List[string]
                    $subList = New-Object System.Collections.Generic.List[string]

                    foreach ($s in @($probe.streams)) {
                        if ($s.codec_type -eq "video" -and $meta.Resolution -eq "-") {
                            $meta.VideoCodec = if ($s.codec_name) { $s.codec_name.ToUpperInvariant() } else { "UNKNOWN" }
                            if ($s.width -and $s.height) {
                                $meta.Resolution = "{0}x{1}" -f $s.width, $s.height
                            }
                            if ($s.r_frame_rate) {
                                $meta.FrameRate = [string]$s.r_frame_rate
                            }
                        } elseif ($s.codec_type -eq "audio") {
                            $cName = if ($s.codec_name) { $s.codec_name.ToUpperInvariant() } else { "AUDIO" }
                            if ($meta.AudioCodec -eq "-") {
                                $meta.AudioCodec = $cName
                            }
                            $lang = if ($s.tags -and $s.tags.language) { [string]$s.tags.language } else { "und" }
                            $audioList.Add("$lang ($cName)")
                        } elseif ($s.codec_type -eq "subtitle") {
                            $sLang = if ($s.tags -and $s.tags.language) { [string]$s.tags.language } else { "und" }
                            $subList.Add($sLang)
                        }
                    }

                    $meta.AudioTracks = $audioList.ToArray()
                    $meta.SubtitleTracks = $subList.ToArray()
                    return [PSCustomObject]$meta
                }
            }
        } catch {}
    }

    # 2. Fallback Engine: Windows Shell COM Properties
    try {
        $shell = New-Object -ComObject Shell.Application
        $dir = $shell.Namespace($item.DirectoryName)
        $fileObj = $dir.ParseName($item.Name)
        if ($fileObj) {
            $meta.Backend = "ShellCOM"
            $durStr = $dir.GetDetailsOf($fileObj, 27)
            if ($durStr) {
                $meta.DurationFormatted = $durStr.Trim()
            }
            $width = $dir.GetDetailsOf($fileObj, 331)
            $height = $dir.GetDetailsOf($fileObj, 329)
            if ($width -and $height) {
                $meta.Resolution = "{0}x{1}" -f $width.Trim(), $height.Trim()
            }
            $codec = $dir.GetDetailsOf($fileObj, 326)
            if ($codec -match "34363248") {
                $meta.VideoCodec = "H264"
            } elseif ($codec) {
                $meta.VideoCodec = $codec.Trim()
            }
            $title = $dir.GetDetailsOf($fileObj, 21)
            if ($title) {
                $meta.Title = $title.Trim()
            }
        }
    } catch {}

    [PSCustomObject]$meta
}

# -------------------------------------------------------------
# SECTION 3: SMART MEDIA CLASSIFICATION
# -------------------------------------------------------------

function Get-MediaClassification {
    param(
        [string]$FilePath,
        [string]$FileName,
        $Metadata,
        [string]$RootCategory = ""
    )

    $lowerPath = $FilePath.ToLowerInvariant()
    $lowerName = $FileName.ToLowerInvariant()

    # 1. Screen recordings / captures
    if ($lowerPath -match "captures" -or $lowerPath -match "screenrec" -or $lowerPath -match "movavi" -or $RootCategory -eq "Captures") {
        return "Captures"
    }

    # 2. TV Series patterns (S01E02, 1x02, Season 1, etc.)
    if ($lowerName -match "s\d{1,2}e\d{1,2}" -or $lowerName -match "\b\d{1,2}x\d{2}\b" -or $lowerPath -match "\\(tv|series|shows)\\" -or $lowerName -match "season\s*\d+") {
        return "TV"
    }

    # 3. Movies patterns (Year pattern 19xx/20xx, typical release tags, duration > 40 min, film dir)
    $hasYear = ($lowerName -match "\b(19\d{2}|20\d{2})\b")
    $hasReleaseTags = ($lowerName -match "\b(1080p|720p|2160p|4k|bluray|web-dl|webrip|hdtc|dvdrip|remux)\b")
    $inMovieDir = ($lowerPath -match "\\(movies?|film)\\" -or $RootCategory -eq "Movies")
    $isFeatureLength = ($Metadata -and $Metadata.DurationSeconds -gt 2400) # > 40 mins

    if ($inMovieDir -or ($hasYear -and ($hasReleaseTags -or $isFeatureLength)) -or ($isFeatureLength -and $hasReleaseTags)) {
        return "Movies"
    }

    # 4. Downloads root
    if ($RootCategory -eq "Downloads" -or $lowerPath -match "torlinkdownloads") {
        # Check if length qualifies as movie
        if ($isFeatureLength -or $hasYear) {
            return "Movies"
        }
        return "Downloads"
    }

    "Other Video"
}

# -------------------------------------------------------------
# SECTION 4: MEDIA INDEXING & CACHING ENGINE
# -------------------------------------------------------------

function Get-WorkCtlMediaIndex {
    param(
        [bool]$ForceRefresh = $false
    )

    $config = Get-WorkCtlMediaConfig
    $ttlSec = if ($config.cache.cacheTtlSeconds) { $config.cache.cacheTtlSeconds } else { 300 }

    # In-memory fast path
    if (!$ForceRefresh -and $script:CachedMediaIndex -ne $null) {
        $age = ([datetime]::UtcNow - $script:CachedMediaIndexTime).TotalSeconds
        if ($age -lt $ttlSec) {
            return $script:CachedMediaIndex
        }
    }

    # Disk cache path
    if (!$ForceRefresh -and (Test-Path -LiteralPath $script:WorkCtlMediaIndexFile)) {
        try {
            $index = Get-Content -LiteralPath $script:WorkCtlMediaIndexFile -Raw | ConvertFrom-Json
            if ($index -and $index.items) {
                $script:CachedMediaIndex = $index
                $script:CachedMediaIndexTime = [datetime]::UtcNow
                return $index
            }
        } catch {}
    }

    # Update index
    Update-WorkCtlMediaIndex -Force $ForceRefresh
}

function Update-WorkCtlMediaIndex {
    param(
        [bool]$Force = $false
    )

    $config = Get-WorkCtlMediaConfig
    $existingItems = @{}

    # Load existing disk index for timestamp comparison
    if (!$Force -and (Test-Path -LiteralPath $script:WorkCtlMediaIndexFile)) {
        try {
            $prev = Get-Content -LiteralPath $script:WorkCtlMediaIndexFile -Raw | ConvertFrom-Json
            if ($prev -and $prev.items) {
                foreach ($it in $prev.items) {
                    $existingItems[$it.Path] = $it
                }
            }
        } catch {}
    }

    $exts = @($config.supportedExtensions)
    $maxDepth = if ($config.cache.maxFileScanDepth) { $config.cache.maxFileScanDepth } else { 4 }
    $updatedItems = New-Object System.Collections.Generic.List[object]

    foreach ($r in @($config.roots)) {
        if (!$r.enabled -or !(Test-Path -LiteralPath $r.path)) {
            continue
        }

        $rootPath = $r.path
        $rootCategory = $r.category

        $files = @(
            Get-ChildItem -LiteralPath $rootPath -File -Recurse -Depth $maxDepth -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLowerInvariant() }
        )

        foreach ($f in $files) {
            $fullPath = $f.FullName
            $lastModUtc = $f.LastWriteTimeUtc.ToString("o")

            # Cache hit: unchanged file
            if ($existingItems.ContainsKey($fullPath) -and $existingItems[$fullPath].Modified -eq $lastModUtc -and $existingItems[$fullPath].SizeBytes -eq $f.Length) {
                $updatedItems.Add($existingItems[$fullPath])
                continue
            }

            # Cache miss or changed: extract metadata
            $meta = Get-MediaMetadataFromFile $fullPath
            if ($meta) {
                $cat = Get-MediaClassification -FilePath $fullPath -FileName $f.Name -Metadata $meta -RootCategory $rootCategory
                
                # Build MD5 item ID
                $md5 = [System.Security.Cryptography.MD5]::Create()
                $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fullPath.ToLowerInvariant()))
                $id = ($hashBytes | ForEach-Object { "{0:x2}" -f $_ }) -join ""

                $itemObj = [PSCustomObject]@{
                    Id = $id
                    Title = $meta.Title
                    Path = $meta.Path
                    Filename = $meta.Filename
                    Extension = $meta.Extension
                    SizeBytes = $meta.SizeBytes
                    SizeFormatted = $meta.SizeFormatted
                    Modified = $meta.Modified
                    ModifiedLocal = $meta.ModifiedLocal
                    Category = $cat
                    RootCategory = $rootCategory
                    Container = $meta.Container
                    DurationSeconds = $meta.DurationSeconds
                    DurationFormatted = $meta.DurationFormatted
                    Resolution = $meta.Resolution
                    VideoCodec = $meta.VideoCodec
                    AudioCodec = $meta.AudioCodec
                    AudioTracks = $meta.AudioTracks
                    SubtitleTracks = $meta.SubtitleTracks
                    BitrateKbps = $meta.BitrateKbps
                    FrameRate = $meta.FrameRate
                    Backend = $meta.Backend
                    Provider = if ($cat -eq "Downloads") { "Torlink" } else { "Local" }
                    Monitored = $false
                }

                $updatedItems.Add($itemObj)
            }
        }
    }

    $itemsArray = $updatedItems.ToArray() | Sort-Object Modified -Descending

    $movies = @($itemsArray | Where-Object { $_.Category -eq "Movies" })
    $tv = @($itemsArray | Where-Object { $_.Category -eq "TV" })
    $captures = @($itemsArray | Where-Object { $_.Category -eq "Captures" })
    $downloads = @($itemsArray | Where-Object { $_.Category -eq "Downloads" })
    $other = @($itemsArray | Where-Object { $_.Category -eq "Other Video" })

    $indexResult = [PSCustomObject]@{
        version = 1
        generatedUtc = [datetime]::UtcNow.ToString("o")
        totalCount = $itemsArray.Count
        moviesCount = $movies.Count
        tvCount = $tv.Count
        capturesCount = $captures.Count
        downloadsCount = $downloads.Count
        otherCount = $other.Count
        items = $itemsArray
    }

    # Persist runtime index
    try {
        $runtimeDir = [System.IO.Path]::GetDirectoryName($script:WorkCtlMediaIndexFile)
        if (!(Test-Path -LiteralPath $runtimeDir)) {
            New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
        }
        $json = $indexResult | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $script:WorkCtlMediaIndexFile -Value $json -Force
    } catch {}

    $script:CachedMediaIndex = $indexResult
    $script:CachedMediaIndexTime = [datetime]::UtcNow

    $indexResult
}

function Get-WorkCtlMediaItemsByCategory {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CategoryName,
        $MediaIndex = $null
    )

    if (!$MediaIndex) {
        $MediaIndex = Get-WorkCtlMediaIndex
    }

    if (!$MediaIndex -or !$MediaIndex.items) {
        return @()
    }

    $all = @($MediaIndex.items)

    switch ($CategoryName) {
        "Movies"          { @($all | Where-Object { $_.Category -eq "Movies" }) }
        "TV"              { @($all | Where-Object { $_.Category -eq "TV" }) }
        "Captures"        { @($all | Where-Object { $_.Category -eq "Captures" }) }
        "Downloads"       { @($all | Where-Object { $_.Category -eq "Downloads" }) }
        "Other Video"     { @($all | Where-Object { $_.Category -eq "Other Video" }) }
        "Recently Added"  { @($all | Sort-Object Modified -Descending | Select-Object -First 20) }
        "Large Files"     { @($all | Sort-Object SizeBytes -Descending | Select-Object -First 20) }
        "All Media"       { $all }
        default           { @($all | Where-Object { $_.Category -ieq $CategoryName }) }
    }
}

# -------------------------------------------------------------
# SECTION 5: VLC PLAYER ADAPTER
# -------------------------------------------------------------

function Test-VLCAvailable {
    $vlc = "C:\Program Files\VideoLAN\VLC\vlc.exe"
    if (Test-Path -LiteralPath $vlc) { return $true }
    $vlc32 = "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe"
    if (Test-Path -LiteralPath $vlc32) { return $true }
    $cmd = Get-Command vlc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $true }
    return $false
}

function Get-VLCInfo {
    $path = "C:\Program Files\VideoLAN\VLC\vlc.exe"
    if (!(Test-Path -LiteralPath $path)) {
        $path = "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe"
    }
    if (!(Test-Path -LiteralPath $path)) {
        $cmd = Get-Command vlc.exe -ErrorAction SilentlyContinue
        if ($cmd) { $path = $cmd.Source }
    }

    $available = Test-Path -LiteralPath $path
    [PSCustomObject]@{
        Available = $available
        Path = if ($available) { $path } else { $null }
        Version = if ($available) { "3.0.x" } else { $null }
        DefaultPlayer = $true
    }
}

function Start-VLCMedia {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MediaPath
    )

    if (!(Test-Path -LiteralPath $MediaPath)) {
        return [PSCustomObject]@{
            Success = $false
            Error = "Media file not found: $MediaPath"
            PID = $null
        }
    }

    $vlcInfo = Get-VLCInfo
    if (!$vlcInfo.Available) {
        return [PSCustomObject]@{
            Success = $false
            Error = "VLC executable not found."
            PID = $null
        }
    }

    try {
        # Launch VLC safely and asynchronously (non-blocking)
        $proc = Start-Process -FilePath $vlcInfo.Path -ArgumentList @("`"$MediaPath`"") -PassThru -WindowStyle Normal
        [PSCustomObject]@{
            Success = $true
            Error = $null
            PID = $proc.Id
            MediaPath = $MediaPath
            Player = "VLC"
        }
    } catch {
        [PSCustomObject]@{
            Success = $false
            Error = $_.Exception.Message
            PID = $null
        }
    }
}

# -------------------------------------------------------------
# SECTION 6: SONARR AUTOMATION ADAPTER
# -------------------------------------------------------------

function Get-SonarrConfigInternal {
    $cfgPath = "C:\ProgramData\Sonarr\config.xml"
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            [xml]$xml = Get-Content -LiteralPath $cfgPath -Raw
            return [PSCustomObject]@{
                Port = if ($xml.Config.Port) { [int]$xml.Config.Port } else { 8989 }
                ApiKey = [string]$xml.Config.ApiKey
                AuthMethod = [string]$xml.Config.AuthenticationMethod
                DataPath = "C:\ProgramData\Sonarr"
                BinPath = "C:\ProgramData\Sonarr\bin\Sonarr.Console.exe"
            }
        } catch {}
    }
    [PSCustomObject]@{
        Port = 8989
        ApiKey = ""
        AuthMethod = "None"
        DataPath = "C:\ProgramData\Sonarr"
        BinPath = "C:\ProgramData\Sonarr\bin\Sonarr.Console.exe"
    }
}

function Test-SonarrRunning {
    $procs = @(Get-Process -Name "*sonarr*" -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        return $true
    }

    # Check TCP port 8989
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect("127.0.0.1", 8989, $null, $null)
        $wait = $ar.AsyncWaitHandle.WaitOne(200, $false)
        if ($wait -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
    } catch {}

    return $false
}

function Start-SonarrProcess {
    if (Test-SonarrRunning) {
        return [PSCustomObject]@{ Success = $true; AlreadyRunning = $true; PID = (Get-Process -Name "*sonarr*" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id) }
    }

    $bin = "C:\ProgramData\Sonarr\bin\Sonarr.Console.exe"
    if (!(Test-Path -LiteralPath $bin)) {
        $bin = "C:\ProgramData\Sonarr\bin\Sonarr.exe"
    }
    if (!(Test-Path -LiteralPath $bin)) {
        return [PSCustomObject]@{ Success = $false; Error = "Sonarr executable not found at C:\ProgramData\Sonarr\bin" }
    }

    try {
        $proc = Start-Process -FilePath $bin -ArgumentList "/data=`"C:\ProgramData\Sonarr`"" -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 800
        [PSCustomObject]@{
            Success = $true
            AlreadyRunning = $false
            PID = $proc.Id
        }
    } catch {
        [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}

function Stop-SonarrProcess {
    $procs = @(Get-Process -Name "*sonarr*" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        return [PSCustomObject]@{ Success = $true; StoppedCount = 0 }
    }

    $stopped = 0
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $stopped++
        } catch {}
    }

    [PSCustomObject]@{ Success = $true; StoppedCount = $stopped }
}

function Invoke-SonarrApi {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Endpoint,
        [int]$TimeoutSec = 3
    )

    $cfg = Get-SonarrConfigInternal
    if (!$cfg.ApiKey) {
        return $null
    }

    $url = "http://localhost:$($cfg.Port)/api/v3/$($Endpoint.TrimStart('/'))"
    try {
        $headers = @{ "X-Api-Key" = $cfg.ApiKey }
        $res = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $res
    } catch {
        return $null
    }
}

function Get-WorkCtlMediaTaxonomy {
    return @(
        "DISCOVER",
        "AUTOMATE",
        "DOWNLOAD",
        "IMPORT_ORGANIZE",
        "METADATA",
        "PLAY",
        "DISK_IMAGE_MOUNT"
    )
}

function Get-WorkCtlMediaToolCapabilities {
    param([string]$ToolName)
    switch -Regex ($ToolName) {
        "(?i)mounter|wincdemu" {
            return [PSCustomObject]@{
                ToolName = "WinCDEmu / Mounter"
                TaxonomyCategory = "DISK_IMAGE_MOUNT"
                Description = "Independent optical disk image utility (ISO, CUE, BIN mounting and drive unmounting)."
                IsAvailable = $true
            }
        }
        "(?i)sonarr" {
            return [PSCustomObject]@{
                ToolName = "Sonarr"
                TaxonomyCategory = "AUTOMATE"
                SecondaryCategories = @("IMPORT_ORGANIZE", "METADATA")
                Description = "Episode calendar, season management, release monitoring, metadata tracking, and series reorganization."
                IsAvailable = $true
            }
        }
        "(?i)qbittorrent" {
            return [PSCustomObject]@{
                ToolName = "qBittorrent"
                TaxonomyCategory = "DOWNLOAD"
                Description = "Native BitTorrent client. API = DISABLED (WebUI disabled in configuration)."
                IsAvailable = $true
            }
        }
        "(?i)torlink" {
            return [PSCustomObject]@{
                ToolName = "Torlink"
                TaxonomyCategory = "DOWNLOAD"
                Description = "Standalone CLI torrent downloader with local WebTorrent daemon engine."
                IsAvailable = $true
            }
        }
        "(?i)ffprobe" {
            return [PSCustomObject]@{
                ToolName = "FFprobe"
                TaxonomyCategory = "METADATA"
                Description = "Binary stream inspector extracting audio/video codecs, bitrates, resolutions, durations."
                IsAvailable = $true
            }
        }
        "(?i)vlc" {
            return [PSCustomObject]@{
                ToolName = "VLC Media Player"
                TaxonomyCategory = "PLAY"
                Description = "High-performance playback engine launched directly from WorkCtl."
                IsAvailable = $true
            }
        }
        default {
            return [PSCustomObject]@{
                ToolName = $ToolName
                TaxonomyCategory = "OTHER"
                Description = "Uncategorized media tool."
                IsAvailable = $false
            }
        }
    }
}

function Get-SonarrStatus {
    $proc = Get-Process -Name "*sonarr*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $running = ($null -ne $proc)
    $cfg = Get-SonarrConfigInternal

    if (!$running) {
        return [PSCustomObject]@{
            Installed = (Test-Path -LiteralPath $cfg.BinPath)
            Running = $false
            Connected = $false
            Version = "4.0.19.2979"
            Branch = "main"
            Port = $cfg.Port
            WebUrl = "http://localhost:$($cfg.Port)"
            SeriesCount = 0
            QueueCount = 0
            HealthStatus = "OFFLINE"
            OperationalState = "STOPPED"
            IsAvailableForDownload = $false
            IndexersCount = 0
            DownloadClientsCount = 0
            RootFoldersCount = 0
        }
    }

    $sys = Invoke-SonarrApi "system/status"
    $connected = ($sys -ne $null)

    $seriesCount = 0
    $rootCount = 0
    $indexersCount = 0
    $downloadClientsCount = 0
    $queueCount = 0
    $healthIssues = 0

    if ($connected) {
        try {
            $sList = Invoke-SonarrApi "series"
            if ($sList) { $seriesCount = @($sList).Count }
        } catch {}
        try {
            $rList = Invoke-SonarrApi "rootfolder"
            if ($rList) { $rootCount = @($rList).Count }
        } catch {}
        try {
            $iList = Invoke-SonarrApi "indexer"
            if ($iList) { $indexersCount = @($iList).Count }
        } catch {}
        try {
            $dList = Invoke-SonarrApi "downloadclient"
            if ($dList) { $downloadClientsCount = @($dList).Count }
        } catch {}
        try {
            $qList = Invoke-SonarrApi "queue"
            if ($qList -and $qList.totalRecords) { $queueCount = [int]$qList.totalRecords }
        } catch {}
        try {
            $hList = Invoke-SonarrApi "health"
            if ($hList) { $healthIssues = @($hList).Count }
        } catch {}
    }

    $opState = if (!$connected) {
        "ERROR (API UNREACHABLE)"
    } elseif ($indexersCount -eq 0 -or $downloadClientsCount -eq 0) {
        "PARTIALLY CONFIGURED"
    } else {
        "OPERATIONAL"
    }

    [PSCustomObject]@{
        Installed = $true
        Running = $true
        Connected = $connected
        ProcessId = if ($proc) { $proc.Id } else { $null }
        ProcessName = if ($proc) { $proc.ProcessName } else { "" }
        Version = if ($sys) { $sys.version } else { "4.0.19.2979" }
        Branch = if ($sys) { $sys.branch } else { "main" }
        Port = $cfg.Port
        WebUrl = "http://localhost:$($cfg.Port)"
        AppName = if ($sys) { $sys.appName } else { "Sonarr" }
        OS = if ($sys) { $sys.operatingSystem } else { "Windows" }
        Runtime = if ($sys) { "$($sys.runtimeName) $($sys.runtimeVersion)" } else { ".NET 6.0" }
        IsAdmin = if ($sys) { [bool]$sys.isAdmin } else { $false }
        OperationalState = $opState
        IsAvailableForDownload = ($opState -eq "OPERATIONAL")
        SeriesCount = $seriesCount
        RootFoldersCount = $rootCount
        IndexersCount = $indexersCount
        DownloadClientsCount = $downloadClientsCount
        QueueCount = $queueCount
        HealthIssuesCount = $healthIssues
        HealthStatus = if ($connected) { "ONLINE" } else { "UNREACHABLE" }
    }
}

function Get-SonarrHealth {
    if (!(Test-SonarrRunning)) { return @() }
    $h = Invoke-SonarrApi "health"
    if ($h) { return @($h) }
    @()
}

function Get-SonarrLibrary {
    if (!(Test-SonarrRunning)) {
        return [PSCustomObject]@{ TotalSeries = 0; MonitoredSeries = 0; TotalEpisodes = 0; Series = @() }
    }

    $s = Invoke-SonarrApi "series"
    if (!$s) {
        return [PSCustomObject]@{ TotalSeries = 0; MonitoredSeries = 0; TotalEpisodes = 0; Series = @() }
    }

    $seriesList = @($s)
    $monitored = @($seriesList | Where-Object { $_.monitored }).Count

    [PSCustomObject]@{
        TotalSeries = $seriesList.Count
        MonitoredSeries = $monitored
        Series = $seriesList
    }
}

function Get-SonarrQueue {
    if (!(Test-SonarrRunning)) { return @() }
    $q = Invoke-SonarrApi "queue"
    if ($q -and $q.records) {
        return @($q.records)
    }
    @()
}

function Get-SonarrStorage {
    if (!(Test-SonarrRunning)) { return @() }
    $d = Invoke-SonarrApi "diskspace"
    if ($d) { return @($d) }
    @()
}

function Open-SonarrWebUI {
    $cfg = Get-SonarrConfigInternal
    Start-Process -FilePath "http://localhost:$($cfg.Port)" | Out-Null
}

# -------------------------------------------------------------
# SECTION 7: TORLINK DOWNLOAD ADAPTER
# -------------------------------------------------------------

function Get-TorlinkInfo {
    $dir = "E:\Workspace\Tools\torlink"
    $cli = Join-Path $dir "dist\cli.cjs"
    $index = Join-Path $dir "dist\index.js"
    $available = (Test-Path -LiteralPath $cli) -and (Test-Path -LiteralPath $index)

    [PSCustomObject]@{
        Available = $available
        Directory = $dir
        CliPath = $cli
        DaemonPath = $index
        Version = "1.6.0"
        DefaultPort = 9161
        DownloadDir = "E:\TorlinkDownloads"
    }
}

function Test-TorlinkRunning {
    # Check TCP 9161 first
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect("127.0.0.1", 9161, $null, $null)
        $wait = $ar.AsyncWaitHandle.WaitOne(200, $false)
        if ($wait -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
    } catch {}

    # Check for Torlink node process
    $nodeProcs = @(Get-Process -Name "node" -ErrorAction SilentlyContinue)
    foreach ($p in $nodeProcs) {
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue
            if ($cim.CommandLine -and ($cim.CommandLine -like "*torl*")) {
                return $true
            }
        } catch {}
    }

    return $false
}

function Get-TorlinkStatus {
    $info = Get-TorlinkInfo
    $running = Test-TorlinkRunning

    $daemonConnected = $false
    $daemonData = $null

    if ($running) {
        try {
            $res = Invoke-RestMethod -Uri "http://127.0.0.1:9161/status" -TimeoutSec 1 -ErrorAction Stop
            if ($res) {
                $daemonConnected = $true
                $daemonData = $res
            }
        } catch {}
    }

    $dlCount = 0
    if (Test-Path -LiteralPath $info.DownloadDir) {
        $dlCount = (Get-ChildItem -LiteralPath $info.DownloadDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    [PSCustomObject]@{
        Available = $info.Available
        Running = $running
        DaemonConnected = $daemonConnected
        Version = $info.Version
        Port = $info.DefaultPort
        DownloadDir = $info.DownloadDir
        DownloadFilesCount = $dlCount
        DaemonData = $daemonData
    }
}

function Start-TorlinkCLI {
    $info = Get-TorlinkInfo
    if (!$info.Available) {
        return [PSCustomObject]@{ Success = $false; Error = "Torlink not found." }
    }

    try {
        # Launch interactive TUI in external console window
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "start", "`"Torlink`"", "node", "`"$($info.CliPath)`"") -WorkingDirectory $info.Directory | Out-Null
        [PSCustomObject]@{ Success = $true; Error = $null }
    } catch {
        [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}

# -------------------------------------------------------------
# SECTION 8: NORMALIZED DOWNLOAD MODEL
# -------------------------------------------------------------

function Get-WorkCtlDownloads {
    $allDownloads = New-Object System.Collections.Generic.List[object]

    # 1. Sonarr Queue Downloads
    $sQueue = Get-SonarrQueue
    foreach ($q in $sQueue) {
        $dlBytes = [int64]$q.size - [int64]$q.sizeleft
        $totalBytes = [int64]$q.size
        $pct = if ($totalBytes -gt 0) { [math]::Round(($dlBytes / $totalBytes) * 100, 1) } else { 0 }

        $allDownloads.Add(
            [PSCustomObject]@{
                Provider = "Sonarr"
                Id = [string]$q.id
                Name = [string]$q.title
                Type = "TV"
                Progress = $pct
                DownloadedBytes = $dlBytes
                TotalBytes = $totalBytes
                DownloadedFormatted = "{0:N1} MB" -f ($dlBytes / 1MB)
                TotalFormatted = "{0:N1} MB" -f ($totalBytes / 1MB)
                SpeedFormatted = "-"
                ETA = [string]$q.timeleft
                State = switch ($q.status.ToLowerInvariant()) {
                    "downloading" { "DOWNLOADING" }
                    "paused"      { "PAUSED" }
                    "completed"   { "COMPLETED" }
                    "failed"      { "FAILED" }
                    default       { $q.status.ToUpperInvariant() }
                }
                Destination = [string]$q.outputPath
            }
        )
    }

    # 2. Torlink Daemon Downloads
    $tStatus = Get-TorlinkStatus
    if ($tStatus.DaemonData -and $tStatus.DaemonData.downloads) {
        foreach ($td in $tStatus.DaemonData.downloads) {
            $allDownloads.Add(
                [PSCustomObject]@{
                    Provider = "Torlink"
                    Id = [string]$td.id
                    Name = [string]$td.name
                    Type = "Torrent"
                    Progress = [math]::Round([double]$td.progress * 100, 1)
                    DownloadedBytes = [int64]0
                    TotalBytes = [int64]0
                    DownloadedFormatted = "-"
                    TotalFormatted = "-"
                    SpeedFormatted = "{0:N1} KB/s" -f ([double]$td.speed / 1024)
                    ETA = "-"
                    State = switch ($td.status.ToLowerInvariant()) {
                        "downloading" { "DOWNLOADING" }
                        "paused"      { "PAUSED" }
                        "seeding"     { "SEEDING" }
                        default       { $td.status.ToUpperInvariant() }
                    }
                    Destination = $tStatus.DownloadDir
                }
            )
        }
    }

    # 3. Local Torlink Downloads Directory (Completed Items)
    if (Test-Path "E:\TorlinkDownloads") {
        $completedFiles = Get-ChildItem "E:\TorlinkDownloads" -File -ErrorAction SilentlyContinue
        foreach ($cf in $completedFiles) {
            $allDownloads.Add(
                [PSCustomObject]@{
                    Provider = "Torlink"
                    Id = $cf.Name
                    Name = $cf.Name
                    Type = "File"
                    Progress = 100.0
                    DownloadedBytes = $cf.Length
                    TotalBytes = $cf.Length
                    DownloadedFormatted = "{0:N2} GB" -f ($cf.Length / 1GB)
                    TotalFormatted = "{0:N2} GB" -f ($cf.Length / 1GB)
                    SpeedFormatted = "-"
                    ETA = "Done"
                    State = "COMPLETED"
                    Destination = $cf.FullName
                }
            )
        }
    }

    $allDownloads.ToArray()
}

# -------------------------------------------------------------
# SECTION 9: MEDIA TUI STATE & NAVIGATION
# -------------------------------------------------------------

function Initialize-MediaAppState {
    [PSCustomObject]@{
        Screen = "media-home"
        PreviousScreen = "media-home"
        SelectedSection = 0 # 0=Library, 1=Automation, 2=DownloadTools, 3=Players
        SelectedCategoryIndex = 0
        SelectedMediaIndex = 0
        MediaScroll = 0
        CurrentCategory = "Movies"
        SelectedMediaItem = $null
        Search = ""
        Filter = "ALL"
        CachedMediaIndex = $null
        CachedResSnapshot = $null
        SonarrStatus = $null
        TorlinkStatus = $null
        VLCInfo = $null
        Dirty = $true
        Running = $true
    }
}

function Get-MediaCategoryNames {
    @("Movies", "TV", "Captures", "Downloads", "Other Video", "Recently Added", "Large Files", "All Media")
}

# -------------------------------------------------------------
# SECTION 10: MEDIA TUI SCREEN FRAME BUILDERS
# -------------------------------------------------------------

function New-MediaTelemetryLine($ResSnapshot) {
    $width = Get-WorkCtlWindowWidth
    $margin = Get-WorkCtlMargin

    if ($ResSnapshot) {
        if ($width -ge 90) {
            New-UiLine @(
                (New-UiSegment $margin "DarkGray"),
                (New-UiSegment "CPU  " "DarkGray"),
                (New-UiSegment ("{0,5:N1}%" -f $ResSnapshot.CPU.UsagePercent) "Green"),
                (New-UiSegment "     RAM  " "DarkGray"),
                (New-UiSegment ("{0:N2} / {1:N2} GB" -f $ResSnapshot.Memory.UsedGB, $ResSnapshot.Memory.TotalGB) "Green"),
                (New-UiSegment "     GPU  " "DarkGray"),
                (New-UiSegment ("{0:N0}%  {1:N0}C" -f $ResSnapshot.GPU.UsagePercent, $ResSnapshot.GPU.TemperatureC) "Green")
            )
        } else {
            New-UiLine @(
                (New-UiSegment $margin "DarkGray"),
                (New-UiSegment "CPU " "DarkGray"),
                (New-UiSegment ("{0:N0}%" -f $ResSnapshot.CPU.UsagePercent) "Green"),
                (New-UiSegment "  RAM " "DarkGray"),
                (New-UiSegment ("{0:N1}/{1:N1}G" -f $ResSnapshot.Memory.UsedGB, $ResSnapshot.Memory.TotalGB) "Green"),
                (New-UiSegment "  GPU " "DarkGray"),
                (New-UiSegment ("{0:N0}% {1:N0}C" -f $ResSnapshot.GPU.UsagePercent, $ResSnapshot.GPU.TemperatureC) "Green")
            )
        }
    } else {
        New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment "Hardware telemetry initializing..." "Yellow")
        )
    }
}

function New-MediaHomeFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin

    # 1. Header
    $f.Add((New-WorkCtlHeaderLine @("MEDIA")))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry
    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    $idx = $State.CachedMediaIndex
    $cats = Get-MediaCategoryNames

    # 3. Section: LIBRARY
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment "LOCAL MEDIA LIBRARY" "Magenta")
        ))
    )
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment ("-" * [math]::Min(66, $width - 8)) "DarkGray")
        ))
    )

    for ($i = 0; $i -lt $cats.Count; $i++) {
        $cName = $cats[$i]
        $sel = ($State.SelectedSection -eq 0 -and $State.SelectedCategoryIndex -eq $i)
        $marker = if ($sel) { ">" } else { " " }
        $bg = if ($sel) { "DarkCyan" } else { "Black" }

        $count = 0
        if ($idx) {
            $count = switch ($cName) {
                "Movies"         { $idx.moviesCount }
                "TV"             { $idx.tvCount }
                "Captures"       { $idx.capturesCount }
                "Downloads"      { $idx.downloadsCount }
                "Other Video"    { $idx.otherCount }
                "Recently Added" { [math]::Min(20, $idx.totalCount) }
                "Large Files"    { [math]::Min(20, $idx.totalCount) }
                "All Media"      { $idx.totalCount }
                default          { 0 }
            }
        }

        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin "DarkGray"),
                (New-UiSegment (" {0} " -f $marker) "White" $bg),
                (New-UiSegment ("{0,-22}" -f $cName) "White" $bg),
                (New-UiSegment ("{0,4} items" -f $count) "Cyan" $bg),
                (New-UiSegment " " "White" $bg)
            ))
        )
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Section: AUTOMATION & TOOLS
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment "CONTROL PLANE BACKENDS" "Magenta")
        ))
    )
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment ("-" * [math]::Min(66, $width - 8)) "DarkGray")
        ))
    )

    # Sonarr Row (Section 1)
    $sonarrSel = ($State.SelectedSection -eq 1)
    $sMarker = if ($sonarrSel) { ">" } else { " " }
    $sBg = if ($sonarrSel) { "DarkCyan" } else { "Black" }
    $sStatus = $State.SonarrStatus
    $sText = if ($sStatus -and $sStatus.Running) { "RUNNING" } else { "STOPPED" }
    $sColor = if ($sText -eq "RUNNING") { "Green" } else { "Yellow" }
    $sDetail = if ($sStatus -and $sStatus.Running) { "Port: 8989 | API: Connected" } else { "Port: 8989 | Offline" }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment (" {0} " -f $sMarker) "White" $sBg),
            (New-UiSegment "Sonarr TV Automation     " "White" $sBg),
            (New-UiSegment ("{0,-10}" -f $sText) $sColor $sBg),
            (New-UiSegment ("   {0}" -f $sDetail) "DarkGray" $sBg),
            (New-UiSegment " " "White" $sBg)
        ))
    )

    # Torlink Row (Section 2)
    $torlinkSel = ($State.SelectedSection -eq 2)
    $tMarker = if ($torlinkSel) { ">" } else { " " }
    $tBg = if ($torlinkSel) { "DarkCyan" } else { "Black" }
    $tStatus = $State.TorlinkStatus
    $tText = if ($tStatus -and $tStatus.Running) { "RUNNING" } else { "STOPPED" }
    $tColor = if ($tText -eq "RUNNING") { "Green" } else { "DarkGray" }
    $tDetail = if ($tStatus) { "{0} completed files" -f $tStatus.DownloadFilesCount } else { "On-demand" }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment (" {0} " -f $tMarker) "White" $tBg),
            (New-UiSegment "Torlink Downloader       " "White" $tBg),
            (New-UiSegment ("{0,-10}" -f $tText) $tColor $tBg),
            (New-UiSegment ("   {0}" -f $tDetail) "DarkGray" $tBg),
            (New-UiSegment " " "White" $tBg)
        ))
    )

    # VLC Player Row (Section 3)
    $vlcSel = ($State.SelectedSection -eq 3)
    $vMarker = if ($vlcSel) { ">" } else { " " }
    $vBg = if ($vlcSel) { "DarkCyan" } else { "Black" }
    $vInfo = $State.VLCInfo
    $vText = if ($vInfo -and $vInfo.Available) { "AVAILABLE" } else { "NOT FOUND" }
    $vColor = if ($vText -eq "AVAILABLE") { "Green" } else { "Red" }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment (" {0} " -f $vMarker) "White" $vBg),
            (New-UiSegment "VLC Media Player         " "White" $vBg),
            (New-UiSegment ("{0,-10}" -f $vText) $vColor $vBg),
            (New-UiSegment "   Default playback engine" "DarkGray" $vBg),
            (New-UiSegment " " "White" $vBg)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 5. Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "TAB";     Label = "Section" },
                @{ Key = "UP/DOWN"; Label = "Move" },
                @{ Key = "ENTER";   Label = "Open" },
                @{ Key = "/";       Label = "Search" },
                @{ Key = "R";       Label = "Scan Library" },
                @{ Key = "D";       Label = "Downloads" },
                @{ Key = "?";       Label = "Help" },
                @{ Key = "Q";       Label = "Exit" }
            ) `
            -RightText "WORKCTL MEDIA"
        )
    )

    $f.ToArray()
}

function New-MediaCategoryFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin
    $catName = $State.CurrentCategory

    # 1. Header
    $f.Add((New-WorkCtlHeaderLine @("MEDIA", $catName)))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry
    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Table Header
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment " TITLE                           TYPE      DURATION    RES          SIZE       MODIFIED" "DarkGray")
        ))
    )
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment ("-" * [math]::Min($width - 8, 88)) "DarkGray")
        ))
    )

    # 4. Rows
    $items = @(Get-WorkCtlMediaItemsByCategory $catName $State.CachedMediaIndex)
    $viewHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 15)

    if ($items.Count -eq 0) {
        $State.SelectedMediaIndex = 0
        $State.MediaScroll = 0
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "   No media files indexed in this category." "Yellow"))))
        for ($i = 1; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    } else {
        if ($State.SelectedMediaIndex -ge $items.Count) {
            $State.SelectedMediaIndex = $items.Count - 1
        }
        if ($State.SelectedMediaIndex -lt 0) {
            $State.SelectedMediaIndex = 0
        }

        $vp = Get-WorkCtlViewport -Total $items.Count -Selected $State.SelectedMediaIndex -Height $viewHeight -CurrentOffset $State.MediaScroll
        $State.MediaScroll = $vp.Offset

        for ($i = $vp.Offset; $i -le $vp.End; $i++) {
            $it = $items[$i]
            $sel = ($i -eq $State.SelectedMediaIndex)

            $bg = if ($sel) { "DarkCyan" } else { "Black" }
            $marker = if ($sel) { ">" } else { " " }

            $titleDisp = if ($it.Title.Length -gt 30) { $it.Title.Substring(0, 27) + "..." } else { $it.Title }

            $f.Add(
                (New-UiLine @(
                    (New-UiSegment $margin "DarkGray"),
                    (New-UiSegment (" {0} " -f $marker) "White" $bg),
                    (New-UiSegment ("{0,-31}" -f $titleDisp) "White" $bg),
                    (New-UiSegment ("{0,-9}" -f $it.Category) "Cyan" $bg),
                    (New-UiSegment ("{0,-11}" -f $it.DurationFormatted) "Yellow" $bg),
                    (New-UiSegment ("{0,-12}" -f $it.Resolution) "Green" $bg),
                    (New-UiSegment ("{0,9}  " -f $it.SizeFormatted) "White" $bg),
                    (New-UiSegment ("{0,-16}" -f $it.ModifiedLocal) "DarkGray" $bg),
                    (New-UiSegment " " "White" $bg)
                ))
            )
        }

        $rendered = $vp.End - $vp.Offset + 1
        for ($i = $rendered; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    }

    # 5. Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $posText = if ($items.Count -gt 0) { "{0}/{1}" -f ($State.SelectedMediaIndex + 1), $items.Count } else { "0/0" }

    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DOWN"; Label = "Move" },
                @{ Key = "ENTER";   Label = "Details" },
                @{ Key = "P";       Label = "Play in VLC" },
                @{ Key = "O";       Label = "Open Folder" },
                @{ Key = "/";       Label = "Search" },
                @{ Key = "B/ESC";   Label = "Back" }
            ) `
            -RightText $posText
        )
    )

    $f.ToArray()
}

function New-MediaDetailFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin
    $m = $State.SelectedMediaItem

    if (!$m) {
        $f.Add((New-WorkCtlHeaderLine @("MEDIA", "DETAIL")))
        $f.Add((New-WorkCtlSeparatorLine))
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "No media item selected." "Yellow"))))
        return $f.ToArray()
    }

    # 1. Header with full breadcrumbs
    $f.Add((New-WorkCtlHeaderLine @("MEDIA", $m.Category, $m.Title)))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry
    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Status Card
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "STATUS" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Title          " "DarkGray"), (New-UiSegment $m.Title "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Type           " "DarkGray"), (New-UiSegment $m.Category "Cyan"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Filename       " "DarkGray"), (New-UiSegment $m.Filename "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Size           " "DarkGray"), (New-UiSegment $m.SizeFormatted "Green"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Location       " "DarkGray"), (New-UiSegment $m.Path "DarkGray"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Modified       " "DarkGray"), (New-UiSegment $m.ModifiedLocal "DarkGray"))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Video & Audio Specs
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "MEDIA SPECIFICATIONS" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Resolution     " "DarkGray"), (New-UiSegment $m.Resolution "Green"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Video Codec    " "DarkGray"), (New-UiSegment $m.VideoCodec "Yellow"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Duration       " "DarkGray"), (New-UiSegment $m.DurationFormatted "Cyan"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Audio Codec    " "DarkGray"), (New-UiSegment $m.AudioCodec "Yellow"))))

    $audioText = if ($m.AudioTracks -and $m.AudioTracks.Count -gt 0) { ($m.AudioTracks -join ", ") } else { "None / Undetected" }
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Audio Tracks   " "DarkGray"), (New-UiSegment $audioText "White"))))

    $subText = if ($m.SubtitleTracks -and $m.SubtitleTracks.Count -gt 0) { ($m.SubtitleTracks -join ", ") } else { "None / Undetected" }
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Subtitles      " "DarkGray"), (New-UiSegment $subText "White"))))

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Metadata Source" "DarkGray"), (New-UiSegment $m.Backend "DarkCyan"))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 5. Automation & Player
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "CONTROL PLANE" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Provider       " "DarkGray"), (New-UiSegment $m.Provider "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Default Player " "DarkGray"), (New-UiSegment "VLC Media Player" "Green"))))

    $f.Add((New-UiLine @((New-UiSegment ""))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  [!] Press 'P' to launch VLC. WorkCtl remains the primary controller." "DarkCyan"))))

    # Pad lines
    $curLines = $f.Count
    $targetHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 3)
    for ($i = $curLines; $i -lt $targetHeight; $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 6. Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "P";     Label = "Play in VLC" },
                @{ Key = "O";     Label = "Open Folder" },
                @{ Key = "B/ESC"; Label = "Back" }
            ) `
            -RightText "MEDIA DETAIL"
        )
    )

    $f.ToArray()
}

function New-SonarrAutomationFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $margin = Get-WorkCtlMargin

    $f.Add((New-WorkCtlHeaderLine @("MEDIA", "AUTOMATION", "SONARR")))
    $f.Add((New-WorkCtlSeparatorLine))

    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    $st = Get-SonarrStatus

    # 1. System Status Card
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "SONARR SYSTEM STATUS" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $runColor = if ($st.Running) { "Green" } else { "Yellow" }
    $runText = if ($st.Running) { "RUNNING" } else { "STOPPED" }
    $connText = if ($st.Connected) { "CONNECTED" } else { "DISCONNECTED" }
    $connColor = if ($st.Connected) { "Green" } else { "Yellow" }

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Process State  " "DarkGray"), (New-UiSegment $runText $runColor))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  API v3 State   " "DarkGray"), (New-UiSegment $connText $connColor))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Version        " "DarkGray"), (New-UiSegment $st.Version "Cyan"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Web UI         " "DarkGray"), (New-UiSegment $st.WebUrl "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Data Directory " "DarkGray"), (New-UiSegment "C:\ProgramData\Sonarr" "DarkGray"))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 2. Library & Queue Summary
    $lib = Get-SonarrLibrary
    $queue = Get-SonarrQueue

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "TV AUTOMATION METRICS" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Total Series   " "DarkGray"), (New-UiSegment ("{0} series" -f $lib.TotalSeries) "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Monitored      " "DarkGray"), (New-UiSegment ("{0} series" -f $lib.MonitoredSeries) "Green"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Active Queue   " "DarkGray"), (New-UiSegment ("{0} items" -f $queue.Count) "Yellow"))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Health Warnings
    $health = Get-SonarrHealth
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "SYSTEM HEALTH" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    if ($health.Count -eq 0) {
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  [OK] No health warnings or errors reported." "Green"))))
    } else {
        foreach ($h in ($health | Select-Object -First 4)) {
            $hCol = if ($h.type -eq "error") { "Red" } else { "Yellow" }
            $hMsg = if ($h.message.Length -gt 60) { $h.message.Substring(0, 57) + "..." } else { $h.message }
            $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("  [{0}] {1}" -f $h.type.ToUpperInvariant(), $hMsg) $hCol))))
        }
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Storage Drives
    $disks = Get-SonarrStorage
    if ($disks.Count -gt 0) {
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "STORAGE DRIVES" "Magenta"))))
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))
        foreach ($d in ($disks | Select-Object -First 3)) {
            $freeGB = [math]::Round($d.freeSpace / 1GB, 1)
            $totalGB = [math]::Round($d.totalSpace / 1GB, 1)
            $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("  Drive {0,-6} Free: {1,6} GB / {2,6} GB" -f $d.path, $freeGB, $totalGB) "White"))))
        }
    }

    # Pad
    $curLines = $f.Count
    $targetHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 3)
    for ($i = $curLines; $i -lt $targetHeight; $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # Footer
    $actionToggle = if ($st.Running) { "Stop Service" } else { "Start Service" }
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "S";     Label = $actionToggle },
                @{ Key = "O";     Label = "Open Web UI" },
                @{ Key = "R";     Label = "Refresh API" },
                @{ Key = "B/ESC"; Label = "Back" }
            ) `
            -RightText "SONARR ADAPTER"
        )
    )

    $f.ToArray()
}

function New-TorlinkFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $margin = Get-WorkCtlMargin

    $f.Add((New-WorkCtlHeaderLine @("MEDIA", "TOOLS", "TORLINK")))
    $f.Add((New-WorkCtlSeparatorLine))

    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    $tst = Get-TorlinkStatus

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "TORLINK STATUS" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $runText = if ($tst.Running) { "RUNNING" } else { "STOPPED" }
    $runCol = if ($tst.Running) { "Green" } else { "Yellow" }
    $daemonText = if ($tst.DaemonConnected) { "CONNECTED (Port 9161)" } else { "OFFLINE" }

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Process State  " "DarkGray"), (New-UiSegment $runText $runCol))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Daemon API     " "DarkGray"), (New-UiSegment $daemonText "Cyan"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Version        " "DarkGray"), (New-UiSegment $tst.Version "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Download Root  " "DarkGray"), (New-UiSegment $tst.DownloadDir "White"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  Completed Files" "DarkGray"), (New-UiSegment ("{0} files on disk" -f $tst.DownloadFilesCount) "Green"))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "AVAILABLE DOWNLOADS" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    if (Test-Path $tst.DownloadDir) {
        $files = @(Get-ChildItem -LiteralPath $tst.DownloadDir -File | Select-Object -First 5)
        if ($files.Count -eq 0) {
            $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  No files currently in download folder." "Yellow"))))
        } else {
            foreach ($fl in $files) {
                $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("  * {0,-40}  {1,8:N2} MB" -f $fl.Name, ($fl.Length/1MB)) "White"))))
            }
        }
    }

    # Pad
    $curLines = $f.Count
    $targetHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 3)
    for ($i = $curLines; $i -lt $targetHeight; $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "L";     Label = "Launch TUI" },
                @{ Key = "O";     Label = "Open Downloads" },
                @{ Key = "R";     Label = "Refresh" },
                @{ Key = "B/ESC"; Label = "Back" }
            ) `
            -RightText "TORLINK ADAPTER"
        )
    )

    $f.ToArray()
}

function New-MediaDownloadsFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $margin = Get-WorkCtlMargin
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)

    $f.Add((New-WorkCtlHeaderLine @("MEDIA", "DOWNLOADS")))
    $f.Add((New-WorkCtlSeparatorLine))

    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    $dls = @(Get-WorkCtlDownloads)

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment " PROVIDER   NAME                                 STATE        PROGRESS   SIZE" "DarkGray")
        ))
    )
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment ("-" * [math]::Min($width - 8, 80)) "DarkGray")
        ))
    )

    if ($dls.Count -eq 0) {
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  No active or completed downloads recorded." "Yellow"))))
    } else {
        foreach ($d in ($dls | Select-Object -First 15)) {
            $nameDisp = if ($d.Name.Length -gt 35) { $d.Name.Substring(0, 32) + "..." } else { $d.Name }
            $stateCol = switch ($d.State) {
                "COMPLETED"   { "Green" }
                "DOWNLOADING" { "Yellow" }
                "PAUSED"      { "DarkGray" }
                default       { "Cyan" }
            }

            $f.Add(
                (New-UiLine @(
                    (New-UiSegment $margin "DarkGray"),
                    (New-UiSegment (" {0,-10} " -f $d.Provider) "Cyan"),
                    (New-UiSegment ("{0,-36}" -f $nameDisp) "White"),
                    (New-UiSegment ("{0,-12}" -f $d.State) $stateCol),
                    (New-UiSegment ("{0,5:N1}%   " -f $d.Progress) "White"),
                    (New-UiSegment ("{0,9}" -f $d.TotalFormatted) "White")
                ))
            )
        }
    }

    # Pad
    $curLines = $f.Count
    $targetHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 3)
    for ($i = $curLines; $i -lt $targetHeight; $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "R";     Label = "Refresh" },
                @{ Key = "O";     Label = "Open Downloads" },
                @{ Key = "B/ESC"; Label = "Back" }
            ) `
            -RightText "DOWNLOADS"
        )
    )

    $f.ToArray()
}

function New-MediaSearchFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $margin = Get-WorkCtlMargin
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $query = $State.Search

    $f.Add((New-WorkCtlHeaderLine @("MEDIA", "SEARCH")))
    $f.Add((New-WorkCtlSeparatorLine))

    $f.Add((New-MediaTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    $matches = @()
    if ($State.CachedMediaIndex -and $State.CachedMediaIndex.items -and $query) {
        $matches = @(
            $State.CachedMediaIndex.items | Where-Object {
                $_.Title -like "*$query*" -or $_.Filename -like "*$query*" -or $_.VideoCodec -like "*$query*"
            }
        )
    }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment "QUERY: " "DarkGray"),
            (New-UiSegment ("[{0}]" -f $query) "Yellow"),
            (New-UiSegment ("     MATCHES: {0} found" -f $matches.Count) "Cyan")
        ))
    )
    $f.Add((New-UiLine @((New-UiSegment ""))))

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment " TITLE                           CATEGORY    DURATION    RES          SIZE" "DarkGray")
        ))
    )
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin "DarkGray"),
            (New-UiSegment ("-" * [math]::Min($width - 8, 80)) "DarkGray")
        ))
    )

    $viewHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 15)

    if ($matches.Count -eq 0) {
        $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  No media items matching search query." "Yellow"))))
        for ($i = 1; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    } else {
        if ($State.SelectedMediaIndex -ge $matches.Count) {
            $State.SelectedMediaIndex = $matches.Count - 1
        }
        if ($State.SelectedMediaIndex -lt 0) {
            $State.SelectedMediaIndex = 0
        }

        $vp = Get-WorkCtlViewport -Total $matches.Count -Selected $State.SelectedMediaIndex -Height $viewHeight -CurrentOffset $State.MediaScroll
        $State.MediaScroll = $vp.Offset

        for ($i = $vp.Offset; $i -le $vp.End; $i++) {
            $it = $matches[$i]
            $sel = ($i -eq $State.SelectedMediaIndex)

            $bg = if ($sel) { "DarkCyan" } else { "Black" }
            $marker = if ($sel) { ">" } else { " " }
            $titleDisp = if ($it.Title.Length -gt 30) { $it.Title.Substring(0, 27) + "..." } else { $it.Title }

            $f.Add(
                (New-UiLine @(
                    (New-UiSegment $margin "DarkGray"),
                    (New-UiSegment (" {0} " -f $marker) "White" $bg),
                    (New-UiSegment ("{0,-31}" -f $titleDisp) "White" $bg),
                    (New-UiSegment ("{0,-11}" -f $it.Category) "Cyan" $bg),
                    (New-UiSegment ("{0,-11}" -f $it.DurationFormatted) "Yellow" $bg),
                    (New-UiSegment ("{0,-12}" -f $it.Resolution) "Green" $bg),
                    (New-UiSegment ("{0,9} " -f $it.SizeFormatted) "White" $bg),
                    (New-UiSegment " " "White" $bg)
                ))
            )
        }

        $rendered = $vp.End - $vp.Offset + 1
        for ($i = $rendered; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    }

    $f.Add((New-WorkCtlSeparatorLine))
    $posText = if ($matches.Count -gt 0) { "{0}/{1}" -f ($State.SelectedMediaIndex + 1), $matches.Count } else { "0/0" }

    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DOWN"; Label = "Move" },
                @{ Key = "ENTER";   Label = "Details" },
                @{ Key = "P";       Label = "Play in VLC" },
                @{ Key = "B/ESC";   Label = "Back" }
            ) `
            -RightText $posText
        )
    )

    $f.ToArray()
}

function New-MediaHelpFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $margin = Get-WorkCtlMargin

    $f.Add((New-WorkCtlHeaderLine @("MEDIA", "HELP")))
    $f.Add((New-WorkCtlSeparatorLine))

    $f.Add((New-UiLine @((New-UiSegment ""))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "WORKCTL MEDIA CONTROL PLANE - SHORTCUTS AND USAGE" "Cyan"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment ("-" * 66) "DarkGray"))))

    $shortcuts = @(
        @{ Key = "UP / DOWN"; Desc = "Navigate highlighted category, media item, or control backend" },
        @{ Key = "ENTER";     Desc = "Open highlighted category, media details, or backend view" },
        @{ Key = "P";         Desc = "Launch VLC Media Player with the exact highlighted video file" },
        @{ Key = "O";         Desc = "Open media container folder in Windows File Explorer" },
        @{ Key = "/";         Desc = "Initiate instant cross-category search across library" },
        @{ Key = "R";         Desc = "Trigger smart incremental scan of configured media roots" },
        @{ Key = "D";         Desc = "Open normalized downloads view (Torlink + Sonarr queue)" },
        @{ Key = "S";         Desc = "Toggle Sonarr service process on/off" },
        @{ Key = "L";         Desc = "Launch interactive Torlink TUI in external console" },
        @{ Key = "B / ESC";   Desc = "Navigate backwards one hierarchical level" },
        @{ Key = "Q";         Desc = "Cleanly exit WorkCtl Media Control Plane" }
    )

    foreach ($sc in $shortcuts) {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin "DarkGray"),
                (New-UiSegment ("  {0,-12}" -f $sc.Key) "Yellow"),
                (New-UiSegment $sc.Desc "White")
            ))
        )
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "ARCHITECTURE NOTE:" "Magenta"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  WorkCtl acts as the central control plane. Playback and automation" "DarkGray"))))
    $f.Add((New-UiLine @((New-UiSegment $margin "DarkGray"), (New-UiSegment "  are delegated to dedicated external execution engines (VLC, Sonarr, Torlink)." "DarkGray"))))

    # Pad
    $curLines = $f.Count
    $targetHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 3)
    for ($i = $curLines; $i -lt $targetHeight; $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "B/ESC"; Label = "Back" }
            ) `
            -RightText "HELP"
        )
    )

    $f.ToArray()
}

# -------------------------------------------------------------
# SECTION 11: KEY INPUT HANDLER
# -------------------------------------------------------------

function Handle-MediaKeyInput($State, $KeyInfo) {
    if (!$KeyInfo) { return }

    $cats = Get-MediaCategoryNames

    switch ($KeyInfo.Key) {
        "UpArrow" {
            switch ($State.Screen) {
                "media-home" {
                    if ($State.SelectedSection -eq 0) {
                        if ($State.SelectedCategoryIndex -gt 0) {
                            $State.SelectedCategoryIndex--
                        }
                    } else {
                        $State.SelectedSection--
                        if ($State.SelectedSection -eq 0) {
                            $State.SelectedCategoryIndex = $cats.Count - 1
                        }
                    }
                    $State.Dirty = $true
                }
                "media-category" {
                    if ($State.SelectedMediaIndex -gt 0) {
                        $State.SelectedMediaIndex--
                        $State.Dirty = $true
                    }
                }
                "media-search" {
                    if ($State.SelectedMediaIndex -gt 0) {
                        $State.SelectedMediaIndex--
                        $State.Dirty = $true
                    }
                }
            }
        }

        "DownArrow" {
            switch ($State.Screen) {
                "media-home" {
                    if ($State.SelectedSection -eq 0) {
                        if ($State.SelectedCategoryIndex -lt ($cats.Count - 1)) {
                            $State.SelectedCategoryIndex++
                        } else {
                            $State.SelectedSection = 1 # move to Automation
                        }
                    } elseif ($State.SelectedSection -lt 3) {
                        $State.SelectedSection++
                    }
                    $State.Dirty = $true
                }
                "media-category" {
                    $items = @(Get-WorkCtlMediaItemsByCategory $State.CurrentCategory $State.CachedMediaIndex)
                    if ($State.SelectedMediaIndex -lt ($items.Count - 1)) {
                        $State.SelectedMediaIndex++
                        $State.Dirty = $true
                    }
                }
                "media-search" {
                    $query = $State.Search
                    $matches = @()
                    if ($State.CachedMediaIndex -and $State.CachedMediaIndex.items) {
                        $matches = @($State.CachedMediaIndex.items | Where-Object { $_.Title -like "*$query*" -or $_.Filename -like "*$query*" })
                    }
                    if ($State.SelectedMediaIndex -lt ($matches.Count - 1)) {
                        $State.SelectedMediaIndex++
                        $State.Dirty = $true
                    }
                }
            }
        }

        "Tab" {
            if ($State.Screen -eq "media-home") {
                $State.SelectedSection = ($State.SelectedSection + 1) % 4
                $State.Dirty = $true
            }
        }

        "RightArrow" {
            if ($State.Screen -eq "media-home") {
                $State.SelectedSection = ($State.SelectedSection + 1) % 4
                $State.Dirty = $true
            }
        }

        "LeftArrow" {
            if ($State.Screen -eq "media-home") {
                $State.SelectedSection = ($State.SelectedSection + 3) % 4
                $State.Dirty = $true
            }
        }

        "Enter" {
            switch ($State.Screen) {
                "media-home" {
                    if ($State.SelectedSection -eq 0) {
                        $State.CurrentCategory = $cats[$State.SelectedCategoryIndex]
                        $State.SelectedMediaIndex = 0
                        $State.MediaScroll = 0
                        $State.PreviousScreen = "media-home"
                        $State.Screen = "media-category"
                        $State.Dirty = $true
                    } elseif ($State.SelectedSection -eq 1) {
                        $State.PreviousScreen = "media-home"
                        $State.Screen = "media-sonarr"
                        $State.Dirty = $true
                    } elseif ($State.SelectedSection -eq 2) {
                        $State.PreviousScreen = "media-home"
                        $State.Screen = "media-torlink"
                        $State.Dirty = $true
                    } elseif ($State.SelectedSection -eq 3) {
                        # VLC info or launch
                        $vlc = Get-VLCInfo
                        if ($vlc.Available) {
                            Start-Process -FilePath $vlc.Path | Out-Null
                        }
                    }
                }
                "media-category" {
                    $items = @(Get-WorkCtlMediaItemsByCategory $State.CurrentCategory $State.CachedMediaIndex)
                    if ($items.Count -gt 0 -and $State.SelectedMediaIndex -lt $items.Count) {
                        $State.SelectedMediaItem = $items[$State.SelectedMediaIndex]
                        $State.PreviousScreen = "media-category"
                        $State.Screen = "media-detail"
                        $State.Dirty = $true
                    }
                }
                "media-search" {
                    $query = $State.Search
                    $matches = @()
                    if ($State.CachedMediaIndex -and $State.CachedMediaIndex.items) {
                        $matches = @($State.CachedMediaIndex.items | Where-Object { $_.Title -like "*$query*" -or $_.Filename -like "*$query*" })
                    }
                    if ($matches.Count -gt 0 -and $State.SelectedMediaIndex -lt $matches.Count) {
                        $State.SelectedMediaItem = $matches[$State.SelectedMediaIndex]
                        $State.PreviousScreen = "media-search"
                        $State.Screen = "media-detail"
                        $State.Dirty = $true
                    }
                }
            }
        }

        "P" { # Play in VLC
            if ($State.Screen -eq "media-category") {
                $items = @(Get-WorkCtlMediaItemsByCategory $State.CurrentCategory $State.CachedMediaIndex)
                if ($items.Count -gt 0 -and $State.SelectedMediaIndex -lt $items.Count) {
                    $target = $items[$State.SelectedMediaIndex]
                    Start-VLCMedia $target.Path | Out-Null
                }
            } elseif ($State.Screen -eq "media-detail" -and $State.SelectedMediaItem) {
                Start-VLCMedia $State.SelectedMediaItem.Path | Out-Null
            } elseif ($State.Screen -eq "media-search") {
                $query = $State.Search
                $matches = @($State.CachedMediaIndex.items | Where-Object { $_.Title -like "*$query*" -or $_.Filename -like "*$query*" })
                if ($matches.Count -gt 0 -and $State.SelectedMediaIndex -lt $matches.Count) {
                    Start-VLCMedia $matches[$State.SelectedMediaIndex].Path | Out-Null
                }
            }
        }

        "O" { # Open Folder or Web UI
            if ($State.Screen -eq "media-sonarr") {
                Open-SonarrWebUI
            } elseif ($State.Screen -eq "media-torlink") {
                $tInfo = Get-TorlinkInfo
                if (Test-Path $tInfo.DownloadDir) {
                    Start-Process "explorer.exe" -ArgumentList "`"$($tInfo.DownloadDir)`"" | Out-Null
                }
            } elseif ($State.Screen -eq "media-category") {
                $items = @(Get-WorkCtlMediaItemsByCategory $State.CurrentCategory $State.CachedMediaIndex)
                if ($items.Count -gt 0 -and $State.SelectedMediaIndex -lt $items.Count) {
                    $dir = [System.IO.Path]::GetDirectoryName($items[$State.SelectedMediaIndex].Path)
                    Start-Process "explorer.exe" -ArgumentList "`"$dir`"" | Out-Null
                }
            } elseif ($State.Screen -eq "media-detail" -and $State.SelectedMediaItem) {
                $dir = [System.IO.Path]::GetDirectoryName($State.SelectedMediaItem.Path)
                Start-Process "explorer.exe" -ArgumentList "`"$dir`"" | Out-Null
            } elseif ($State.Screen -eq "media-downloads") {
                if (Test-Path "E:\TorlinkDownloads") {
                    Start-Process "explorer.exe" -ArgumentList "`"E:\TorlinkDownloads`"" | Out-Null
                }
            }
        }

        "S" { # Start/Stop Service Toggle
            if ($State.Screen -eq "media-sonarr") {
                if (Test-SonarrRunning) {
                    Stop-SonarrProcess | Out-Null
                } else {
                    Start-SonarrProcess | Out-Null
                }
                Start-Sleep -Milliseconds 400
                $State.SonarrStatus = Get-SonarrStatus
                $State.Dirty = $true
            }
        }

        "L" { # Launch Torlink interactive TUI
            if ($State.Screen -eq "media-torlink") {
                Start-TorlinkCLI | Out-Null
            }
        }

        "A" { # Automation view (Sonarr)
            if ($State.Screen -eq "media-home") {
                $State.PreviousScreen = "media-home"
                $State.Screen = "media-sonarr"
                $State.Dirty = $true
            }
        }

        "T" { # Torlink view
            if ($State.Screen -eq "media-home") {
                $State.PreviousScreen = "media-home"
                $State.Screen = "media-torlink"
                $State.Dirty = $true
            }
        }

        "D" { # Downloads view
            if ($State.Screen -eq "media-home") {
                $State.PreviousScreen = "media-home"
                $State.Screen = "media-downloads"
                $State.Dirty = $true
            }
        }

        "R" { # Refresh / Scan Library
            $State.CachedMediaIndex = Update-WorkCtlMediaIndex -Force $true
            $State.SonarrStatus = Get-SonarrStatus
            $State.TorlinkStatus = Get-TorlinkStatus
            $State.Dirty = $true
        }

        "Escape" {
            switch ($State.Screen) {
                "media-detail" {
                    $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "media-category" }
                    $State.Dirty = $true
                }
                "media-category" {
                    $State.Screen = "media-home"
                    $State.Dirty = $true
                }
                "media-sonarr" {
                    $State.Screen = "media-home"
                    $State.Dirty = $true
                }
                "media-torlink" {
                    $State.Screen = "media-home"
                    $State.Dirty = $true
                }
                "media-downloads" {
                    $State.Screen = "media-home"
                    $State.Dirty = $true
                }
                "media-search" {
                    $State.Search = ""
                    $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "media-home" }
                    $State.Dirty = $true
                }
                "media-help" {
                    $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "media-home" }
                    $State.Dirty = $true
                }
                "media-home" {
                    $State.Running = $false
                }
            }
        }

        "B" {
            switch ($State.Screen) {
                "media-detail"    { $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "media-category" }; $State.Dirty = $true }
                "media-category"  { $State.Screen = "media-home"; $State.Dirty = $true }
                "media-sonarr"    { $State.Screen = "media-home"; $State.Dirty = $true }
                "media-torlink"   { $State.Screen = "media-home"; $State.Dirty = $true }
                "media-downloads" { $State.Screen = "media-home"; $State.Dirty = $true }
                "media-search"    { $State.Search = ""; $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "media-home" }; $State.Dirty = $true }
                "media-help"      { $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "media-home" }; $State.Dirty = $true }
                "media-home"      { $State.Running = $false }
            }
        }

        "Q" {
            $State.Running = $false
            $State.ExitRequested = $true
        }

        "Oem2" { # '/' or '?'
            if ($KeyInfo.KeyChar -eq "?") {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "media-help"
                $State.Dirty = $true
            } else {
                $res = Read-WorkCtlSearchInput -CurrentQuery $State.Search
                if (!$res.Cancelled) {
                    $State.Search = $res.Query
                    $State.SelectedMediaIndex = 0
                    $State.MediaScroll = 0
                    $State.PreviousScreen = $State.Screen
                    if ($res.Query) {
                        $State.Screen = "media-search"
                    } else {
                        $State.Screen = "media-home"
                    }
                }
                $State.Dirty = $true
            }
        }

        default {
            if ($KeyInfo.KeyChar -eq "?") {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "media-help"
                $State.Dirty = $true
            }
        }
    }
}

# -------------------------------------------------------------
# SECTION 12: CANONICAL TUI EVENT LOOP
# -------------------------------------------------------------

function Watch-WorkCtlMedia {
    param(
        [switch]$Embedded,
        [string]$InitialScreen = "",
        [switch]$TestMode,
        [object[]]$SyntheticKeys = @()
    )

    $worker = $null
    if (Get-Command Start-PTTelemetryWorker -ErrorAction SilentlyContinue) {
        $worker = Start-PTTelemetryWorker -IntervalMs 1500
    }

    $state = Initialize-MediaAppState
    $state.CachedMediaIndex = Get-WorkCtlMediaIndex
    $state.SonarrStatus = Get-SonarrStatus
    $state.TorlinkStatus = Get-TorlinkStatus
    $state.VLCInfo = Get-VLCInfo

    if ($InitialScreen) {
        $state.PreviousScreen = "media-home"
        $state.Screen = $InitialScreen
    }

    if (!$Embedded) {
        Start-WorkCtlUI
    } else {
        $script:UiPreviousFrame = @()
    }

    # Flush any stray keystrokes from launch
    try {
        while ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
        }
    } catch {}

    $keyQueue = New-Object System.Collections.Generic.Queue[object]
    if ($SyntheticKeys -and $SyntheticKeys.Count -gt 0) {
        foreach ($k in $SyntheticKeys) {
            $keyQueue.Enqueue($k)
        }
    }

    try {
        while ($state.Running) {
            # Update telemetry from worker
            if ($worker -and $worker.Sync -and $worker.Sync.Snapshot) {
                $state.CachedResSnapshot = $worker.Sync.Snapshot
            }

            # Render frame if dirty
            if ($state.Dirty) {
                $frame = switch ($state.Screen) {
                    "media-home"      { New-MediaHomeFrame $state }
                    "media-category"  { New-MediaCategoryFrame $state }
                    "media-detail"    { New-MediaDetailFrame $state }
                    "media-sonarr"    { New-SonarrAutomationFrame $state }
                    "media-torlink"   { New-TorlinkFrame $state }
                    "media-downloads" { New-MediaDownloadsFrame $state }
                    "media-search"    { New-MediaSearchFrame $state }
                    "media-help"      { New-MediaHelpFrame $state }
                    default           { New-MediaHomeFrame $state }
                }

                Write-WorkCtlDiffFrame -Frame $frame
                $state.Dirty = $false
            }

            if ($TestMode -and $keyQueue.Count -eq 0) {
                break
            }

            # Input poll (20ms timeout)
            $key = $null
            if ($keyQueue.Count -gt 0) {
                $key = $keyQueue.Dequeue()
            } else {
                $key = Read-WorkCtlKey -TimeoutMs 20
            }

            if ($key -ne $null) {
                Handle-MediaKeyInput $state $key
                continue
            }

            # Window resize detection
            $curW = Get-WorkCtlWindowWidth
            $curH = Get-WorkCtlWindowHeight
            if ($curW -ne $script:UiLastWidth -or $curH -ne $script:UiLastHeight) {
                $script:UiLastWidth = $curW
                $script:UiLastHeight = $curH
                $state.Dirty = $true
            }
        }

        return $state

    } finally {
        if ($worker) {
            Stop-PTTelemetryWorker $worker
        }
        if (!$Embedded) {
            Stop-WorkCtlUI
        }
    }
}
