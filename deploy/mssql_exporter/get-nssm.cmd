@echo off
rem ============================================================================
rem  get-nssm.cmd - download nssm.exe INTO THIS FOLDER.
rem
rem  install-service.cmd deliberately refuses to look anywhere else: nssm.exe
rem  must sit next to the application exe so the whole deployment is one
rem  self-contained, relocatable folder. Run this once on a machine that has
rem  internet access, or copy nssm.exe here by hand from
rem  https://nssm.cc/download (use the win64 build).
rem
rem  No Administrator rights needed - this only writes one file.
rem ============================================================================
setlocal EnableExtensions

set "DEST=%~dp0nssm.exe"
set "NSSM_URL=https://nssm.cc/release/nssm-2.24.zip"

if exist "%DEST%" (
    echo [..] nssm.exe already present: %DEST%
    exit /b 0
)

echo [..] Downloading %NSSM_URL%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$tmp = Join-Path $env:TEMP ('nssm-' + [guid]::NewGuid());" ^
  "New-Item -ItemType Directory -Path $tmp | Out-Null;" ^
  "$zip = Join-Path $tmp 'nssm.zip';" ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;" ^
  "Invoke-WebRequest -Uri '%NSSM_URL%' -OutFile $zip -UseBasicParsing;" ^
  "Expand-Archive -Path $zip -DestinationPath $tmp -Force;" ^
  "$exe = Get-ChildItem $tmp -Recurse -Filter nssm.exe | Where-Object { $_.DirectoryName -like '*win64*' } | Select-Object -First 1;" ^
  "if (-not $exe) { throw 'win64\nssm.exe not found inside the archive' };" ^
  "Copy-Item $exe.FullName '%DEST%' -Force;" ^
  "Remove-Item $tmp -Recurse -Force"

if errorlevel 1 (
    echo [ERROR] Download failed. Fetch nssm.cc/download manually and copy
    echo         win64\nssm.exe to: %~dp0
    exit /b 1
)

if not exist "%DEST%" (
    echo [ERROR] nssm.exe was not written to %DEST%
    exit /b 1
)

rem Deliberately not calling "nssm version" here: nssm writes UTF-16 to the
rem console, which turns into spaced-out garbage whenever this script's output
rem is piped or captured.
echo [OK] %DEST%
powershell -NoProfile -Command "$f = Get-Item '%DEST%'; '     {0:N0} bytes, {1}' -f $f.Length, $f.VersionInfo.FileVersion"
echo.
echo Next: run install-service.cmd as Administrator.
exit /b 0
