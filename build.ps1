param(
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'release',
    [switch]$Run
)

$ErrorActionPreference = 'Stop'

$RootDir = $PSScriptRoot
$WinDir = Join-Path $RootDir 'windows'
$ResDir = Join-Path $WinDir 'Resources'
$OutDir = Join-Path $RootDir 'build\YacineTV-Windows'

# 1. Discover Swift for Windows toolchain & runtime
$SwiftToolchainBin = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Swift\Toolchains" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'usr\bin' } |
    Where-Object { Test-Path (Join-Path $_ 'swift.exe') } |
    Select-Object -First 1

$SwiftRuntimeBin = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'usr\bin' } |
    Where-Object { Test-Path (Join-Path $_ 'swiftCore.dll') } |
    Select-Object -First 1

$SwiftSdk = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Swift\Platforms" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'Windows.platform\Developer\SDKs\Windows.sdk' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if (-not $SwiftToolchainBin) {
    $cmd = Get-Command swift.exe -ErrorAction SilentlyContinue
    if ($cmd) { $SwiftToolchainBin = Split-Path $cmd.Source -Parent }
}
if (-not $SwiftToolchainBin) {
    throw 'Swift for Windows toolchain not found. Install Swift 6.x via winget (Swift.Toolchain).'
}
if (-not $env:SDKROOT -and $SwiftSdk) {
    $env:SDKROOT = $SwiftSdk
}
$env:PATH = "$SwiftToolchainBin;$SwiftRuntimeBin;$env:PATH"

Write-Host "Using Swift: $(& swift --version | Select-Object -First 1)"

# 2. Find Python 3 (skipping empty WindowsApps alias)
$PythonExe = Get-Command python.exe -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -notlike '*\Microsoft\WindowsApps\*' -and (Get-Item $_.Source).Length -gt 10000 } |
    Select-Object -ExpandProperty Source -First 1

if (-not $PythonExe) {
    $PythonExe = Get-ChildItem -Path @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "$env:ProgramFiles\Python3*\python.exe",
        "C:\Python3*\python.exe"
    ) -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName -First 1
}
if (-not $PythonExe) {
    throw 'Python 3 executable not found.'
}

# 3. Ensure WebView2 C++ SDK is extracted
$Wv2Include = Join-Path $WinDir '.deps\webview2\build\native\include\WebView2.h'
if (-not (Test-Path $Wv2Include)) {
    Write-Host 'Downloading Microsoft.Web.WebView2 1.0.4314.35 SDK...'
    $depsDir = Join-Path $WinDir '.deps\webview2'
    New-Item -ItemType Directory -Force -Path $depsDir | Out-Null
    $nupkg = Join-Path $depsDir 'webview2.nupkg'
    $zip = Join-Path $depsDir 'webview2.zip'
    Invoke-WebRequest -Uri 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4314.35/microsoft.web.webview2.1.0.4314.35.nupkg' -OutFile $nupkg
    Copy-Item -Force $nupkg $zip
    Expand-Archive -Force -Path $zip -DestinationPath $depsDir
    Remove-Item -Force $zip, $nupkg -ErrorAction SilentlyContinue
}

# 4. Generate Windows .ico & .res icon resources
Write-Host 'Generating Windows icons and resource binary...'
& $PythonExe (Join-Path $WinDir 'scripts\make_icons.py')
$RcExe = Join-Path $SwiftToolchainBin 'llvm-rc.exe'
$ResOut = Join-Path $ResDir 'YacineTV.res'
Push-Location $ResDir
try {
    & $RcExe /FO $ResOut (Join-Path $ResDir 'YacineTV.rc')
    if ($LASTEXITCODE -ne 0) { throw 'Failed compiling YacineTV.rc' }
} finally {
    Pop-Location
}

# Sync light/dark brand PNGs into ui/
Copy-Item -Force (Join-Path $RootDir 'assets\AppBrand-Default.png') (Join-Path $RootDir 'ui\AppBrand-Default.png')
Copy-Item -Force (Join-Path $RootDir 'assets\AppBrand-Dark.png') (Join-Path $RootDir 'ui\AppBrand-Dark.png')

# 5. Build SwiftPM package
Write-Host "Building YacineTV ($Configuration) with Swift..."
Push-Location $WinDir
try {
    & swift build -c $Configuration
    if ($LASTEXITCODE -ne 0) { throw "swift build -c $Configuration failed." }
    $BinDir = (& swift build -c $Configuration --show-bin-path | Select-Object -Last 1).Trim()
} finally {
    Pop-Location
}

$BuiltExe = Join-Path $BinDir 'YacineTV.exe'
if (-not (Test-Path $BuiltExe)) {
    throw "Built executable missing at $BuiltExe"
}

# 6. Assemble portable output folder under build\YacineTV-Windows
Write-Host "Packaging $OutDir..."
if (Test-Path $OutDir) {
    Remove-Item -Recurse -Force $OutDir
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'backend') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'ui') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'Resources') | Out-Null

Copy-Item -Force $BuiltExe (Join-Path $OutDir 'YacineTV.exe')
Copy-Item -Force (Join-Path $RootDir 'backend\server.py') (Join-Path $OutDir 'backend\server.py')
Copy-Item -Recurse -Force (Join-Path $RootDir 'ui\*') (Join-Path $OutDir 'ui\')
Copy-Item -Force (Join-Path $ResDir 'AppIcon-Default.ico') (Join-Path $OutDir 'Resources\AppIcon-Default.ico')
Copy-Item -Force (Join-Path $ResDir 'AppIcon-Dark.ico') (Join-Path $OutDir 'Resources\AppIcon-Dark.ico')

# 7. Bundle transitive Swift & VC++ runtime DLLs so YacineTV.exe launches standalone
if ($SwiftRuntimeBin) {
    $ReadObj = Join-Path $SwiftToolchainBin 'llvm-readobj.exe'
    $AvailableDlls = @{}
    Get-ChildItem -Path $SwiftRuntimeBin -Filter '*.dll' | ForEach-Object {
        $AvailableDlls[$_.Name.ToLowerInvariant()] = $_.FullName
    }

    $Visited = New-Object 'System.Collections.Generic.HashSet[string]'
    $Queue = New-Object 'System.Collections.Generic.Queue[string]'
    $Queue.Enqueue((Join-Path $OutDir 'YacineTV.exe'))

    while ($Queue.Count -gt 0) {
        $binary = $Queue.Dequeue()
        $imports = & $ReadObj --coff-imports $binary 2>$null
        foreach ($line in $imports) {
            if ($line -match '^\s*Name:\s*(.+\.dll)\s*$') {
                $dllLower = $Matches[1].Trim().ToLowerInvariant()
                if ($AvailableDlls.ContainsKey($dllLower) -and $Visited.Add($dllLower)) {
                    $srcDll = $AvailableDlls[$dllLower]
                    $dstDll = Join-Path $OutDir (Split-Path $srcDll -Leaf)
                    Copy-Item -Force $srcDll $dstDll
                    $Queue.Enqueue($dstDll)
                }
            }
        }
    }
}

Write-Host "Package ready at: $OutDir\YacineTV.exe"

if ($Run) {
    Start-Process -FilePath (Join-Path $OutDir 'YacineTV.exe')
}
