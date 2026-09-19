param(
    [switch]$Console
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

# MSVC and Windows SDK libraries used by the Windows build.
$msvc = "C:\BuildTools\VC\Tools\MSVC\14.44.35207\lib\x64"
$ucrt = "C:\BuildTools\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64"
$um   = "C:\BuildTools\Windows Kits\10\Lib\10.0.26100.0\um\x64"
$env:LIB = "$msvc;$ucrt;$um"

$flags = "msvcrt.lib vcruntime.lib ucrt.lib oldnames.lib kernel32.lib user32.lib gdi32.lib winmm.lib shell32.lib advapi32.lib ws2_32.lib crypt32.lib wldap32.lib normaliz.lib secur32.lib /FORCE:MULTIPLE"

$subsystem = "windows"
if ($Console) {
    $subsystem = "console"
}

Write-Host "Building Fatboy.exe ($subsystem, optimized)..." -ForegroundColor Green
& odin build . `
    -out:Fatboy.exe `
    "-subsystem:$subsystem" `
    -o:speed `
    "-extra-linker-flags:$flags"

if ($LASTEXITCODE -ne 0) {
    throw "Odin build failed with exit code $LASTEXITCODE."
}

Write-Host "Build complete: $PSScriptRoot\Fatboy.exe" -ForegroundColor Green
Write-Host "The custom font is embedded in the executable." -ForegroundColor DarkGray
