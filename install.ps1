# .SYNOPSIS
#     One-liner MinGW installer script. Downloads the latest WinLibs MinGW
#     release, extracts it, and adds it to the system PATH.
#
# .DESCRIPTION
#     This script automates the full MinGW setup process:
#
#     USAGE (one-liner from PowerShell):
#         irm https://raw.githubusercontent.com/sabamdarif/win-mingw-installer/main/install.ps1 | iex
#
#     Or run locally:
#         .\install.ps1
#         .\install.ps1 -InstallPath "D:\tools\mingw"
#
# .PARAMETER InstallPath
#     Directory where MinGW will be installed. Defaults to C:\mingw.
#
# .PARAMETER KeepZip
#     If specified, keeps the downloaded zip file after extraction.
#
# .PARAMETER Force
#     If specified, overwrites an existing installation at InstallPath.
#
# .NOTES
#     File Name  : install.ps1
#     Repository : https://github.com/sabamdarif/win-mingw-installer
#     Requires   : PowerShell 5.1+, Windows 10+

[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\mingw',
    [switch]$KeepZip,
    [switch]$Force
)

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Installer needs to be run as Administrator. Attempting to relaunch." -ForegroundColor Yellow
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://raw.githubusercontent.com/sabamdarif/win-mingw-installer/main/install.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    exit 0
}

$ErrorActionPreference = 'Stop'

# ============================================================================
# Configuration
# ============================================================================

$WinLibsOwner = 'brechtsanders'
$WinLibsRepo  = 'winlibs_mingw'
$ApiBase      = 'https://api.github.com'
$UserAgent    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) EasyMinGW-Installer/1.0'

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Step {
    param([string]$Icon, [string]$Message)
    Write-Host "`n  $Icon " -NoNewline -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor White
}

function Write-Detail {
    param([string]$Label, [string]$Value)
    Write-Host "     ${Label}: " -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "     [ok] $Message" -ForegroundColor Green
}

function Write-Err {
    param([string]$Message)
    Write-Host "     [error] $Message" -ForegroundColor Red
}

# ============================================================================
# Banner
# ============================================================================

Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "  |          " -NoNewline -ForegroundColor DarkCyan
Write-Host "Easy MinGW Installer - Quick Setup" -NoNewline -ForegroundColor Cyan
Write-Host "           |" -ForegroundColor DarkCyan
Write-Host "  |     " -NoNewline -ForegroundColor DarkCyan
Write-Host "github.com/sabamdarif/win-mingw-installer" -NoNewline -ForegroundColor DarkGray
Write-Host "          |" -ForegroundColor DarkCyan
Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkCyan

# ============================================================================
# Step 1: Detect System Architecture
# ============================================================================

Write-Step "[i]" "Detecting system architecture..."

$is64Bit = [Environment]::Is64BitOperatingSystem
$arch = if ($is64Bit) { 'x86_64' } else { 'i686' }
$archLabel = if ($is64Bit) { '64-bit' } else { '32-bit' }
$mingwDir = if ($is64Bit) { 'mingw64' } else { 'mingw32' }

Write-Detail "Architecture" "$archLabel ($arch)"

# ============================================================================
# Step 2: Find Latest WinLibs Release
# ============================================================================

Write-Step "[w]" "Fetching latest WinLibs release..."

$headers = @{
    'User-Agent' = $UserAgent
    'Accept'     = 'application/vnd.github.v3+json'
}

# Use GITHUB_TOKEN if available to avoid rate limiting
$ghToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
if ($ghToken) {
    $headers['Authorization'] = "token $ghToken"
}

$releasesUri = "$ApiBase/repos/$WinLibsOwner/$WinLibsRepo/releases"

try {
    $releases = Invoke-RestMethod -Uri $releasesUri -Headers $headers -TimeoutSec 30
}
catch {
    Write-Err "Failed to fetch releases from GitHub API"
    Write-Err $_.Exception.Message
    Write-Host "`n  Tip: If rate-limited, set GITHUB_TOKEN environment variable." -ForegroundColor DarkYellow
    exit 1
}

# Filter: UCRT + POSIX, non-prerelease, sorted by date
$release = $releases |
    Where-Object {
        $_.name -like '*POSIX*' -and
        $_.name -like '*UCRT*' -and
        -not $_.prerelease
    } |
    Sort-Object { [datetime]$_.published_at } -Descending |
    Select-Object -First 1

if (-not $release) {
    Write-Err "No matching WinLibs release found (searching for POSIX + UCRT)"
    Write-Host "     Try setting GITHUB_TOKEN if you are being rate-limited." -ForegroundColor DarkYellow
    exit 1
}

Write-Detail "Release" $release.name
Write-Detail "Tag" $release.tag_name
Write-Detail "Published" ([datetime]$release.published_at).ToString('yyyy-MM-dd')

# ============================================================================
# Step 3: Find Correct Asset
# ============================================================================

Write-Step "[p]" "Finding download for $archLabel..."

# Match pattern: winlibs-<arch>-posix-<exception>-gcc-<ver>-mingw-w64ucrt-<ver>.zip
# For 64-bit: x86_64-posix-seh
# For 32-bit: i686-posix-dwarf
$archPattern = if ($is64Bit) {
    "winlibs-x86_64-posix-seh-gcc-.*-mingw-w64ucrt-.*\.zip$"
} else {
    "winlibs-i686-posix-dwarf-gcc-.*-mingw-w64ucrt-.*\.zip$"
}

$asset = $release.assets |
    Where-Object { $_.name -match $archPattern } |
    Select-Object -First 1

if (-not $asset) {
    Write-Err "No matching asset found for architecture: $arch"
    Write-Host "  Available assets:" -ForegroundColor DarkYellow
    $release.assets | ForEach-Object { Write-Host "    - $($_.name)" -ForegroundColor DarkGray }
    exit 1
}

$downloadUrl = $asset.browser_download_url
$fileName    = $asset.name
$fileSizeMB  = [math]::Round($asset.size / 1MB, 1)

Write-Detail "File" $fileName
Write-Detail "Size" "$fileSizeMB MB"

# ============================================================================
# Step 4: Check Existing Installation
# ============================================================================

$targetDir = Join-Path $InstallPath $mingwDir
$binDir    = Join-Path $targetDir 'bin'

if (Test-Path $targetDir) {
    if ($Force) {
        Write-Step "[d]" "Removing existing installation at $targetDir..."
        Remove-Item -Path $targetDir -Recurse -Force
        Write-Ok "Removed"
    }
    else {
        Write-Err "MinGW already installed at: $targetDir"
        Write-Host "     Use -Force to overwrite, or choose a different -InstallPath" -ForegroundColor DarkYellow
        exit 1
    }
}

# ============================================================================
# Step 5: Download
# ============================================================================

Write-Step "[D]" "Downloading $fileName ($fileSizeMB MB)..."

# Create install directory
if (-not (Test-Path $InstallPath)) {
    New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
}

$zipPath = Join-Path $InstallPath $fileName

try {
    # Start-BitsTransfer is more efficient and has a built-in progress bar
    $bitsParams = @{
        Source      = $downloadUrl
        Destination = $zipPath
        ErrorAction = 'Stop'
    }
    
    # Add auth header if token is present
    if ($ghToken) {
        $bitsParams['Headers'] = @{ 'Authorization' = "token $ghToken" }
    }

    Start-BitsTransfer @bitsParams
}
catch {
    Write-Err "Download failed: $($_.Exception.Message)"
    Write-Host "     Falling back to Invoke-WebRequest..." -ForegroundColor DarkYellow
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
        $ProgressPreference = 'Continue'
    }
    catch {
        Write-Err "Fallback download failed."
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        exit 1
    }
}

$downloadedSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Ok "Downloaded ($downloadedSize MB)"

# ============================================================================
# Step 6: Extract
# ============================================================================

Write-Step "[e]" "Extracting to $InstallPath..."

try {
    Expand-Archive -Path $zipPath -DestinationPath $InstallPath -Force
}
catch {
    Write-Err "Extraction failed: $($_.Exception.Message)"
    exit 1
}

# Verify extraction
if (-not (Test-Path $binDir)) {
    Write-Err "Extraction completed but $binDir not found"
    exit 1
}

Write-Ok "Extracted to $targetDir"

# Clean up zip
if (-not $KeepZip) {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Write-Ok "Cleaned up downloaded archive"
}

# ============================================================================
# Step 7: Add to PATH
# ============================================================================

Write-Step "[c]" "Configuring system PATH..."

$currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')

if ($currentPath -split ';' | Where-Object { $_ -eq $binDir }) {
    Write-Ok "Already in PATH: $binDir"
}
else {
    # Add to User PATH (persistent)
    $newPath = "$binDir;$currentPath"
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Ok "Added to User PATH: $binDir"

    # Also update current session
    $env:Path = "$binDir;$env:Path"
    Write-Ok "Updated current session PATH"
}

# ============================================================================
# Step 8: Verify Installation
# ============================================================================

Write-Step "[v]" "Verifying installation..."

$gccPath = Join-Path $binDir 'gcc.exe'
if (Test-Path $gccPath) {
    try {
        $gccVersion = & $gccPath --version 2>&1 | Select-Object -First 1
        Write-Ok "gcc: $gccVersion"
    }
    catch {
        Write-Ok "gcc.exe found at $gccPath"
    }
}

$gppPath = Join-Path $binDir 'g++.exe'
if (Test-Path $gppPath) {
    try {
        $gppVersion = & $gppPath --version 2>&1 | Select-Object -First 1
        Write-Ok "g++: $gppVersion"
    }
    catch {
        Write-Ok "g++.exe found at $gppPath"
    }
}

$makePath = Join-Path $binDir 'mingw32-make.exe'
if (Test-Path $makePath) {
    Write-Ok "mingw32-make.exe found"
}

$gdbPath = Join-Path $binDir 'gdb.exe'
if (Test-Path $gdbPath) {
    Write-Ok "gdb.exe found"
}

# ============================================================================
# Done
# ============================================================================

Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |            " -NoNewline -ForegroundColor Green
Write-Host "Installation Complete! (o)" -NoNewline -ForegroundColor White
Write-Host "                     |" -ForegroundColor Green
Write-Host "  +----------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Detail "Location" $targetDir
Write-Detail "GCC" ($(if ($null -ne $gccVersion) { $gccVersion } else { 'installed' }))
Write-Host ""
Write-Host "  (!) " -NoNewline -ForegroundColor Yellow
Write-Host "Restart your terminal to use gcc, g++, and other tools." -ForegroundColor White
Write-Host ""
