# build.ps1

# 1. Inject the portable Build Tools paths into the current session
$msvc = "C:\BuildTools\VC\Tools\MSVC\14.44.35207\lib\x64"
$ucrt = "C:\BuildTools\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64"
$um   = "C:\BuildTools\Windows Kits\10\Lib\10.0.26100.0\um\x64"
$env:LIB = "$msvc;$ucrt;$um"

# 2. Define the dynamic Windows libraries Raylib and Curl require
$flags = "msvcrt.lib vcruntime.lib ucrt.lib oldnames.lib kernel32.lib user32.lib gdi32.lib winmm.lib shell32.lib advapi32.lib ws2_32.lib crypt32.lib wldap32.lib normaliz.lib secur32.lib /FORCE:MULTIPLE"

# 3. Execute based on the argument passed
if ($args[0] -eq "release") {
    Write-Host "Building optimized release executable (Hiding console)..." -ForegroundColor Green
    # -subsystem:windows hides the terminal window in the final build
    # -o:speed applies max compiler optimizations
    odin build . -out:Fatboy.exe -subsystem:windows -o:speed -extra-linker-flags:"$flags"
} else {
    Write-Host "Running development build..." -ForegroundColor Cyan
    odin run . -extra-linker-flags:"$flags"
}
