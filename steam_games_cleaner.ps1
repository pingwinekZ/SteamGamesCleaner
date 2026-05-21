<#
.SYNOPSIS
    Steam Game Cleaner - Removes extra files not in Steam depot manifests.
.DESCRIPTION
    Parses local depot manifests from Steam's depotcache directory and compares
    them against installed game files. Shows extra files and asks for confirmation
    before deleting. No external dependencies required.
#>

$ErrorActionPreference = "Stop"

function Find-SteamPath {
    $paths = @(
        "$env:ProgramFiles (x86)\Steam",
        "$env:ProgramFiles\Steam"
    )
    foreach ($p in $paths) {
        if (Test-Path "$p\steamapps\libraryfolders.vdf") {
            return (Resolve-Path $p).Path
        }
    }

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq 'Fixed' -or $drive.DriveType -eq 'Removable') {
            $root = $drive.RootDirectory.FullName.TrimEnd('\')
            $candidates = @(
                "$root\Program Files (x86)\Steam",
                "$root\SteamLibrary",
                "$root\Games\SteamLibrary"
            )
            foreach ($c in $candidates) {
                if (Test-Path "$c\steamapps\libraryfolders.vdf") {
                    return (Resolve-Path $c).Path
                }
            }
        }
    }

    Write-Host "`nSteam installation not auto-detected." -ForegroundColor Yellow
    $path = Read-Host "Enter Steam installation path"
    if ($path -and (Test-Path "$path\steamapps")) {
        return (Resolve-Path $path).Path
    }
    return $null
}

function Parse-VdfSimple {
    param([string]$FilePath)
    $result = @{}
    $stack = @($result)
    $currentKey = $null

    Get-Content $FilePath | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^"([^"]+)"\s*$') {
            $currentKey = $matches[1]
        }
        elseif ($line -match '^"([^"]+)"\s+"([^"]*)"') {
            $key = $matches[1]
            $value = $matches[2]
            $stack[-1][$key] = $value
        }
        elseif ($line -eq '{') {
            if ($currentKey) {
                $newObj = @{}
                $stack[-1][$currentKey] = $newObj
                $stack += $newObj
                $currentKey = $null
            }
        }
        elseif ($line -eq '}') {
            if ($stack.Count -gt 1) {
                $stack = $stack[0..($stack.Count - 2)]
            }
        }
    }
    return $result
}

function Get-InstalledGames {
    param(
        [string]$SteamPath,
        [string[]]$LibraryFolders
    )
    $games = @()

    foreach ($folder in $LibraryFolders) {
        $steamapps = Join-Path $folder "steamapps"
        if (-not (Test-Path $steamapps)) { continue }

        Get-ChildItem "$steamapps\appmanifest_*.acf" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            try {
                $data = Parse-VdfSimple $_.FullName
                $appState = $data["AppState"]
                if ($appState) {
                    $appid = [int]$appState["appid"]
                    $name = $appState["name"]
                    $installdir = $appState["installdir"]
                    if ($appid -and $installdir) {
                        $installPath = Join-Path (Join-Path $steamapps "common") $installdir
                        $games += @{
                            AppId       = $appid
                            Name        = $name
                            InstallDir  = $installdir
                            InstallPath = $installPath
                            Library     = $folder
                        }
                    }
                }
            } catch {
                Write-Verbose "Failed to parse $($_.Name): $_"
            }
        }
    }
    return $games
}

function Get-AppDepotIds {
    param(
        [string]$SteamPath,
        [int]$AppId,
        [string[]]$LibraryFolders
    )
    $depotIds = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($folder in $LibraryFolders) {
        $acfPath = Join-Path (Join-Path $folder "steamapps") "appmanifest_$AppId.acf"
        if (Test-Path $acfPath) {
            try {
                $data = Parse-VdfSimple $acfPath
                $appState = $data["AppState"]
                if ($appState["InstalledDepots"]) {
                    foreach ($key in $appState["InstalledDepots"].Keys) {
                        $id = 0
                        if ([int]::TryParse($key, [ref]$id)) {
                            $depotIds.Add($id) | Out-Null
                        }
                    }
                }
                if ($appState["SharedDepots"]) {
                    foreach ($key in $appState["SharedDepots"].Keys) {
                        $id = 0
                        if ([int]::TryParse($key, [ref]$id)) {
                            $depotIds.Add($id) | Out-Null
                        }
                    }
                }
                if ($depotIds.Count -gt 0) { break }
            } catch {
                Write-Verbose "Failed to parse $acfPath`: $_"
            }
        }
    }
    return $depotIds
}

function Read-VarInt {
    param([byte[]]$Data, [ref]$Offset)
    $result = 0
    $shift = 0
    while ($Offset.Value -lt $Data.Length) {
        $byte = $Data[$Offset.Value]
        $Offset.Value++
        $result = $result -bor (($byte -band 0x7F) -shl $shift)
        $shift += 7
        if (($byte -band 0x80) -eq 0) { break }
    }
    return $result
}

function Read-ProtobufString {
    param([byte[]]$Data, [ref]$Offset)
    $length = Read-VarInt $Data ([ref]$Offset)
    $str = [System.Text.Encoding]::UTF8.GetString($Data, $Offset.Value, $length)
    $Offset.Value += $length
    return $str
}

function Read-ProtobufBytes {
    param([byte[]]$Data, [ref]$Offset)
    $length = Read-VarInt $Data ([ref]$Offset)
    $bytes = New-Object byte[] $length
    [System.Array]::Copy($Data, $Offset.Value, $bytes, 0, $length)
    $Offset.Value += $length
    return $bytes
}

function Parse-Manifest {
    param([string]$ManifestPath)
    $files = [System.Collections.Generic.HashSet[string]]::new()
    $encrypted = $false

    try {
        $data = [System.IO.File]::ReadAllBytes($ManifestPath)
    } catch {
        return @{ Files = $files; Encrypted = $true }
    }

    $offset = 0
    $int32 = [System.Text.Encoding]::ASCII

    while ($offset -lt $data.Length - 3) {
        $msgId = [System.BitConverter]::ToUInt32($data, $offset)
        $offset += 4
        $msgSize = [System.BitConverter]::ToUInt32($data, $offset)
        $offset += 4

        if ($msgId -eq 0x32C415AB) { break }

        $msgData = $data[$offset..($offset + $msgSize - 1)]
        $offset += $msgSize

        if ($msgId -eq 0x1F4812BE) {
            $off = 0
            while ($off -lt $msgData.Length) {
                $fieldNum = Read-VarInt $msgData ([ref]$off)
                $fieldType = $fieldNum -band 0x07
                $fieldId = $fieldNum -shr 3
                if ($fieldId -eq 4 -and $fieldType -eq 0) {
                    $val = Read-VarInt $msgData ([ref]$off)
                    if ($val -ne 0) { $encrypted = $true }
                }
                elseif ($fieldType -eq 0) { Read-VarInt $msgData ([ref]$off) | Out-Null }
                elseif ($fieldType -eq 2) {
                    $len = Read-VarInt $msgData ([ref]$off)
                    $off += $len
                }
                else { break }
            }
        }

        if ($msgId -eq 0x71F617D0) {
            $off = 0
            while ($off -lt $msgData.Length) {
                $fieldNum = Read-VarInt $msgData ([ref]$off)
                $fieldType = $fieldNum -band 0x07
                $fieldId = $fieldNum -shr 3

                if ($fieldId -eq 1 -and $fieldType -eq 2) {
                    $fmLength = Read-VarInt $msgData ([ref]$off)
                    $fmEnd = $off + $fmLength
                    $filename = $null

                    while ($off -lt $fmEnd) {
                        $fmFieldNum = Read-VarInt $msgData ([ref]$off)
                        $fmFieldType = $fmFieldNum -band 0x07
                        $fmFieldId = $fmFieldNum -shr 3

                        if ($fmFieldId -eq 1 -and $fmFieldType -eq 2) {
                            $rawName = Read-ProtobufBytes $msgData ([ref]$off)
                            try {
                                $filename = [System.Text.Encoding]::UTF8.GetString($rawName)
                            } catch {
                                $filename = $null
                            }
                        }
                        elseif ($fmFieldType -eq 0) { Read-VarInt $msgData ([ref]$off) | Out-Null }
                        elseif ($fmFieldType -eq 2) {
                            $len = Read-VarInt $msgData ([ref]$off)
                            $off += $len
                        }
                        else { break }
                    }
                    $off = $fmEnd

                    if ($filename -and -not $filename.EndsWith("/")) {
                        $normalized = $filename.Replace("\", "/").ToLowerInvariant()
                        $files.Add($normalized) | Out-Null
                    }
                }
                elseif ($fieldType -eq 0) { Read-VarInt $msgData ([ref]$off) | Out-Null }
                elseif ($fieldType -eq 2) {
                    $len = Read-VarInt $msgData ([ref]$off)
                    $off += $len
                }
                else { break }
            }
        }
    }

    return @{ Files = $files; Encrypted = $encrypted }
}

function Get-ManifestFiles {
    param(
        [string]$SteamPath,
        [int]$AppId,
        [string[]]$LibraryFolders
    )
    $depotcacheDirs = @(
        (Join-Path $SteamPath "depotcache"),
        (Join-Path (Join-Path $SteamPath "config") "depotcache")
    )

    $appDepotIds = Get-AppDepotIds $SteamPath $AppId $LibraryFolders
    if ($appDepotIds.Count -gt 0) {
        Write-Host "INFO: AppID $AppId has $($appDepotIds.Count) depot(s)" -ForegroundColor DarkGray
    }

    $allFiles = [System.Collections.Generic.HashSet[string]]::new()
    $manifestCount = 0
    $depotsWithManifests = [System.Collections.Generic.HashSet[int]]::new()
    $parseErrors = 0

    foreach ($depotcache in $depotcacheDirs) {
        if (-not (Test-Path $depotcache)) { continue }

        Get-ChildItem "$depotcache\*.manifest" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            $baseName = $_.BaseName
            $parts = $baseName -split '_', 2
            if ($parts.Count -ne 2) { return }

            $depotId = 0
            if (-not [int]::TryParse($parts[0], [ref]$depotId)) { return }

            if ($appDepotIds.Count -gt 0 -and $appDepotIds -notcontains $depotId) { return }

            try {
                $result = Parse-Manifest $_.FullName
                $manifestCount++
                $depotsWithManifests.Add($depotId) | Out-Null

                if ($result.Encrypted) {
                    Write-Host "WARNING: $($_.Name): filenames encrypted, skipping" -ForegroundColor Yellow
                    return
                }

                foreach ($f in $result.Files) {
                    $allFiles.Add($f) | Out-Null
                }
            } catch {
                $parseErrors++
                Write-Verbose "Failed to parse $($_.Name): $_"
            }
        }
    }

    Write-Host "INFO: Parsed $manifestCount manifest(s) from $($depotsWithManifests.Count) depot(s), $($allFiles.Count) unique files ($parseErrors errors)" -ForegroundColor DarkGray

    if ($appDepotIds.Count -gt 0) {
        $missing = [System.Collections.Generic.HashSet[int]]::new($appDepotIds)
        $missing.ExceptWith($depotsWithManifests)
        if ($missing.Count -gt 0) {
            Write-Host "WARNING: Missing manifests for $($missing.Count) depot(s)" -ForegroundColor Yellow
        }
    }

    return @{
        Files = $allFiles
        DepotsWithManifests = $depotsWithManifests
        AppDepotIds = $appDepotIds
    }
}

function Get-InstalledFiles {
    param([string]$InstallPath)
    Write-Host "INFO: Scanning installed files in $InstallPath..." -ForegroundColor DarkGray
    $installed = @{}
    $fileCount = 0

    Get-ChildItem -Path $InstallPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $relPath = $_.FullName.Substring($InstallPath.Length + 1).Replace("\", "/")
        $installed[$relPath.ToLowerInvariant()] = $relPath
        $fileCount++
    }

    Write-Host "INFO: Found $fileCount installed files" -ForegroundColor DarkGray
    return $installed
}

function Format-Size {
    param([long]$Bytes)
    $units = @("B", "KB", "MB", "GB", "TB")
    $size = [double]$Bytes
    $unitIndex = 0
    while ($size -ge 1024 -and $unitIndex -lt $units.Length - 1) {
        $size /= 1024
        $unitIndex++
    }
    return "{0:F1} {1}" -f $size, $units[$unitIndex]
}

# Main
Write-Host "=" * 60
Write-Host "Steam Game Cleaner (PowerShell)"
Write-Host "=" * 60

$steamPath = Find-SteamPath
if (-not $steamPath) {
    Write-Host "ERROR: Steam installation not found" -ForegroundColor Red
    exit 1
}
Write-Host "INFO: Steam path: $steamPath" -ForegroundColor DarkGray

$libraryFolders = @()
$lfPath = Join-Path (Join-Path $steamPath "steamapps") "libraryfolders.vdf"
if (Test-Path $lfPath) {
    $lfData = Parse-VdfSimple $lfPath
    $lf = $lfData["libraryfolders"]
    if ($lf) {
        foreach ($key in $lf.Keys) {
            $val = $lf[$key]
            if ($val -is [hashtable] -and $val["path"]) {
                $libraryFolders += $val["path"]
            }
            elseif ($val -is [string] -and $val) {
                $libraryFolders += $val
            }
        }
    }
}
if ($libraryFolders.Count -eq 0) {
    $libraryFolders += $steamPath
}
Write-Host "INFO: Found $($libraryFolders.Count) library folder(s)" -ForegroundColor DarkGray

$games = Get-InstalledGames $steamPath $libraryFolders
if ($games.Count -eq 0) {
    Write-Host "ERROR: No installed games found" -ForegroundColor Red
    exit 1
}
Write-Host "INFO: Found $($games.Count) installed game(s)" -ForegroundColor DarkGray

Write-Host "`nInstalled games:"
for ($i = 0; $i -lt $games.Count; $i++) {
    Write-Host ("  {0,3}. {1} (AppID: {2})" -f ($i + 1), $games[$i].Name, $games[$i].AppId)
}

$choice = Read-Host "`nSelect game (number)"
$idx = 0
if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $games.Count) {
    Write-Host "Invalid selection" -ForegroundColor Red
    exit 1
}
$game = $games[$idx - 1]

Write-Host "`nSelected: $($game.Name) (AppID: $($game.AppId))"
Write-Host "Install path: $($game.InstallPath)"

if (-not (Test-Path $game.InstallPath)) {
    Write-Host "ERROR: Game install path does not exist" -ForegroundColor Red
    exit 1
}

$manifestResult = Get-ManifestFiles $steamPath $game.AppId $libraryFolders
$manifestFiles = $manifestResult.Files
$installedFiles = Get-InstalledFiles $game.InstallPath

$extraFiles = @{}
foreach ($key in $installedFiles.Keys) {
    if (-not $manifestFiles.Contains($key)) {
        $extraFiles[$key] = $installedFiles[$key]
    }
}

$appDepotIds = $manifestResult.AppDepotIds
$depotsWithManifests = $manifestResult.DepotsWithManifests
if ($appDepotIds.Count -gt 0) {
    $missingCount = 0
    foreach ($id in $appDepotIds) {
        if (-not $depotsWithManifests.Contains($id)) { $missingCount++ }
    }
    if ($missingCount -eq $appDepotIds.Count) {
        Write-Host "`nERROR: No depot manifests found for this game. Cannot safely determine extra files." -ForegroundColor Red
        Write-Host "Try updating the game via Steam first, then run this script again." -ForegroundColor Yellow
        exit 1
    }
    elseif ($missingCount -gt $appDepotIds.Count * 0.5) {
        Write-Host "`nWARNING: Missing manifests for $missingCount/$($appDepotIds.Count) depots. Results may be inaccurate." -ForegroundColor Yellow
        $answer = Read-Host "Continue anyway? (yes/no)"
        if ($answer -ne "yes" -and $answer -ne "y") {
            Write-Host "Aborted."
            exit 0
        }
    }
}

if ($extraFiles.Count -eq 0) {
    Write-Host "`nNo extra files found. Game is clean!" -ForegroundColor Green
    exit 0
}

Write-Host "`nFound $($extraFiles.Count) extra file(s) not in Steam manifests"

$extraPaths = @()
$totalSize = 0
foreach ($key in ($extraFiles.Keys | Sort-Object)) {
    $originalPath = $extraFiles[$key]
    $fullPath = Join-Path $game.InstallPath $originalPath
    if (Test-Path $fullPath -PathType Leaf) {
        $size = (Get-Item $fullPath).Length
        $totalSize += $size
        $extraPaths += @{ Full = $fullPath; Rel = $originalPath; Size = $size }
    }
}

Write-Host "Total extra size: $(Format-Size $totalSize)"
Write-Host "`nExtra files (first 50):"
$showCount = [Math]::Min(50, $extraPaths.Count)
for ($i = 0; $i -lt $showCount; $i++) {
    Write-Host "  $($extraPaths[$i].Rel) ($(Format-Size $extraPaths[$i].Size))"
}
if ($extraPaths.Count -gt 50) {
    Write-Host "  ... and $($extraPaths.Count - 50) more"
}

$answer = Read-Host "`nDelete these extra files? (yes/no)"
if ($answer -ne "yes" -and $answer -ne "y") {
    Write-Host "Aborted. No files deleted."
    exit 0
}

Write-Host "`nDeleting extra files..."
$deletedCount = 0
$deletedSize = 0
$failed = @()

foreach ($ep in $extraPaths) {
    try {
        Remove-Item $ep.Full -Force
        $deletedCount++
        $deletedSize += $ep.Size
    } catch {
        $failed += "$($ep.Rel): $_"
    }
}

Write-Host "`nDeleted $deletedCount files ($(Format-Size $deletedSize))"

if ($failed.Count -gt 0) {
    Write-Host "`nFailed to delete $($failed.Count) file(s):"
    $failed | ForEach-Object { Write-Host "  $_" }
}

Write-Host "`nRemoving empty directories..."
$removedDirs = 0
$dirs = Get-ChildItem -Path $game.InstallPath -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
foreach ($dir in $dirs) {
    try {
        if ((Get-ChildItem $dir -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $dir -Force
            $removedDirs++
        }
    } catch {}
}

Write-Host "Removed $removedDirs empty director$(if ($removedDirs -eq 1) { 'y' } else { 'ies' })"
Write-Host "`nDone!" -ForegroundColor Green
