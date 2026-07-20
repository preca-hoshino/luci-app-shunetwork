# Build luci-app-shucampus .ipk package
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootFS = Join-Path $ProjectRoot "rootfs"
$BuildDir = Join-Path $ProjectRoot "build"
$PkgName = "luci-app-shucampus"
$Version = "1.0"
$Release = "1"

function Write-TarEntry($bw, $path, $content, $mode = "0100644") {
    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($path)
    if ($nameBytes.Length -gt 100) { throw "Path too long: $path" }

    $header = New-Object byte[] 512
    # Name (bytes 0-99)
    [Array]::Copy($nameBytes, 0, $header, 0, $nameBytes.Length)
    # Mode (bytes 100-107)
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($mode.PadLeft(8, '0')), 0, $header, 100, 8)
    # UID (108-115), GID (116-123)
    "0000000".PadLeft(8,'0') | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 108, 8) }
    "0000000".PadLeft(8,'0') | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 116, 8) }
    # Size (124-135)
    $sizeStr = [Convert]::ToString($content.Length, 8).PadLeft(12, '0')
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes($sizeStr), 0, $header, 124, 12)
    # Mtime (136-147)
    "00000000000" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 136, 12) }
    # Type flag (156): '0' = regular, '5' = directory
    $header[156] = [byte]('0')
    # Magic (257-262)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("ustar"), 0, $header, 257, 5)
    # Version (263-264)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("00"), 0, $header, 263, 2)
    # Owner (265-296)
    "root" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 265, $_.Length) }
    # Group (297-328)
    "root" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 297, $_.Length) }
    # Checksum (148-155): computed as sum of all bytes in header (with checksum bytes treated as spaces)
    Set-TarChecksum $header
    $bw.Write($header, 0, 512)
    if ($content.Length -gt 0) {
        $bw.Write($content, 0, $content.Length)
        $pad = (512 - ($content.Length % 512)) % 512
        if ($pad -gt 0) { $bw.Write([byte[]]::new($pad), 0, $pad) }
    }
}

function Write-TarDirEntry($bw, $path) {
    $header = New-Object byte[] 512
    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($path)
    [Array]::Copy($nameBytes, 0, $header, 0, [Math]::Min($nameBytes.Length, 100))
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("040755".PadLeft(8,'0')), 0, $header, 100, 8)
    "0000000".PadLeft(8,'0') | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 108, 8) }
    "0000000".PadLeft(8,'0') | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 116, 8) }
    "00000000000" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 124, 12) }
    "00000000000" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 136, 12) }
    $header[156] = [byte]('5')
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("ustar"), 0, $header, 257, 5)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("00"), 0, $header, 263, 2)
    "root" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 265, $_.Length) }
    "root" | ForEach-Object { [Array]::Copy([Text.Encoding]::ASCII.GetBytes($_), 0, $header, 297, $_.Length) }
    Set-TarChecksum $header
    $bw.Write($header, 0, 512)
}

function Set-TarChecksum($header) {
    for ($i = 148; $i -lt 156; $i++) { $header[$i] = [byte]' ' }
    $sum = 0
    for ($i = 0; $i -lt 512; $i++) { $sum += $header[$i] }
    $chk = [Convert]::ToString($sum, 8).PadLeft(7, '0') + "`0"
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes($chk), 0, $header, 148, 8)
}

function Write-TarGz($tarPath, $entries) {
    # $entries: array of @{path, content, mode, isdir}
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    foreach ($e in $entries) {
        if ($e.isdir) {
            Write-TarDirEntry $bw $e.path
        } else {
            Write-TarEntry $bw $e.path $e.content $e.mode
        }
    }

    # End of tar: two 512-byte zero blocks
    $bw.Write([byte[]]::new(1024), 0, 1024)
    $bw.Flush()
    $tarBytes = $ms.ToArray()
    $bw.Close()
    $ms.Close()

    # GZip compress
    $fsOut = [System.IO.File]::OpenWrite($tarPath)
    $gzip = New-Object System.IO.Compression.GzipStream($fsOut, [IO.Compression.CompressionMode]::Compress)
    $gzip.Write($tarBytes, 0, $tarBytes.Length)
    $gzip.Close()
    $fsOut.Close()
}

Function Build-DataTarGz {
    param($rootDir, $outPath)
    $entries = @()
    $allFiles = Get-ChildItem -Recurse -File $rootDir | Sort-Object FullName

    $dirsSeen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($rootDir.Length + 1).Replace("\", "/")
        # Add parent directories
        $parent = [System.IO.Path]::GetDirectoryName($rel).Replace("\", "/")
        while ($parent -and $parent -ne "" -and $parent -ne ".") {
            if (-not $dirsSeen.Contains($parent)) {
                $null = $dirsSeen.Add($parent)
                $entries += @{path = "$parent/"; content = [byte[]]@(); mode = ""; isdir = $true }
            }
            $parent = [System.IO.Path]::GetDirectoryName($parent).Replace("\", "/")
        }
        $mode = if ($rel -match "^(etc/init\.d/|usr/bin/)") { "0100755" } else { "0100644" }
        $content = [System.IO.File]::ReadAllBytes($f.FullName)
        $entries += @{path = $rel; content = $content; mode = $mode; isdir = $false }
    }
    Write-TarGz $outPath $entries
}

Function Build-ControlTarGz {
    param($ctrlDir, $outPath)
    $entries = @()
    Get-ChildItem $ctrlDir | Sort-Object Name | ForEach-Object {
        $mode = if ($_.Name -eq "postinst" -or $_.Name -eq "prerm") { "0100755" } else { "0100644" }
        $entries += @{path = $_.Name; content = [byte[]](Get-Content $_.FullName -AsByteStream -Raw); mode = $mode; isdir = $false }
    }
    Write-TarGz $outPath $entries
}

Write-Host "=== Build $PkgName ===" -ForegroundColor Cyan

# Step 1: Prepare build directory
Write-Host "[1/5] Preparing directories..." -ForegroundColor Cyan
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
$dataDir = Join-Path $BuildDir "data"
$ctrlDir = Join-Path $BuildDir "control"
$workDir = Join-Path $BuildDir "ipk"
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
New-Item -ItemType Directory -Path $ctrlDir -Force | Out-Null
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# Step 2: Copy rootfs (skip .po files)
Write-Host "[2/5] Copying files..." -ForegroundColor Cyan
Get-ChildItem -Recurse -File $RootFS | Where-Object { $_.Extension -ne ".po" } | ForEach-Object {
    $rel = $_.FullName.Substring($RootFS.Length + 1)
    $dst = Join-Path $dataDir $rel
    $d = Split-Path $dst -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item $_.FullName $dst
}
$totalBytes = (Get-ChildItem -Recurse -File $dataDir | Measure-Object -Property Length -Sum).Sum
$installedKB = [math]::Max(1, [math]::Ceiling($totalBytes / 1024))

# Step 3: Create control files
Write-Host "[3/5] Writing control files..." -ForegroundColor Cyan
Set-Content -Path (Join-Path $ctrlDir "control") -Encoding ASCII -Value @"
Package: $PkgName
Version: $Version-$Release
Depends: luci-base, curl
Source: package/$PkgName
Section: luci
Priority: optional
Maintainer: Preca
Architecture: all
Installed-Size: $installedKB
Description: Ruijie SAM+ Portal login and keepalive daemon with LuCI
 Manage Shanghai University campus network authentication.

"@

Set-Content -Path (Join-Path $ctrlDir "postinst") -Encoding ASCII -Value @'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    chmod 755 /etc/init.d/shucampus 2>/dev/null
    chmod 755 /usr/bin/shucampus_core.sh 2>/dev/null
    /etc/init.d/shucampus enable 2>/dev/null || true
}
exit 0
'@

# Step 4: Build tar.gz archives manually
Write-Host "[4/5] Building tar.gz archives..." -ForegroundColor Cyan
Build-ControlTarGz $ctrlDir (Join-Path $workDir "control.tar.gz")
Build-DataTarGz $dataDir (Join-Path $workDir "data.tar.gz")
Set-Content -Path (Join-Path $workDir "debian-binary") -Value "2.0`n" -Encoding ASCII

# Step 5: Assemble .ipk (just tar of the 3 files)
Write-Host "[5/5] Assembling .ipk..." -ForegroundColor Cyan
$ipkFile = Join-Path $ProjectRoot "${PkgName}_${Version}-${Release}_all.ipk"
$ipkEntries = @(
    @{path = "debian-binary"; content = [byte[]][Text.Encoding]::ASCII.GetBytes("2.0`n"); mode = "0100644"; isdir = $false },
    @{path = "control.tar.gz"; content = [byte[]](Get-Content (Join-Path $workDir "control.tar.gz") -AsByteStream -Raw); mode = "0100644"; isdir = $false },
    @{path = "data.tar.gz"; content = [byte[]](Get-Content (Join-Path $workDir "data.tar.gz") -AsByteStream -Raw); mode = "0100644"; isdir = $false }
)
Write-TarGz $ipkFile $ipkEntries

# Cleanup
Remove-Item -Recurse -Force $BuildDir

$sizeKB = [math]::Round((Get-Item $ipkFile).Length / 1024, 1)
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Package: $ipkFile" -ForegroundColor Green
Write-Host "Size:    ${sizeKB} KB" -ForegroundColor Green
