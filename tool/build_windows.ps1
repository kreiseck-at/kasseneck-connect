# Baut die Windows-Binary und, falls Inno Setup vorhanden ist, den Installer.
#
#   powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1
#
# Ergebnis:
#   build\kasseneck-connect-windows-x64.exe
#   build\KasseneckConnect-<version>-windows-x64-setup.exe  (nur mit Inno Setup)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$dart = if ($env:DART) { $env:DART } else { 'dart' }
$out = 'build\kasseneck-connect-windows-x64.exe'

New-Item -ItemType Directory -Force -Path 'build' | Out-Null
& $dart pub get
& $dart compile exe bin\kasseneck_connect.dart -o $out
if ($LASTEXITCODE -ne 0) { throw "dart compile exe ist fehlgeschlagen." }

Write-Host "Fertig: $out"

# Version aus der pubspec.yaml lesen — sie steht auch im Installer.
$version = (Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()

# Inno Setup ist optional: ohne ihn bleibt es bei der nackten Binary.
$iscc = @(
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
  Write-Warning 'Inno Setup (ISCC.exe) nicht gefunden — der Installer wird nicht gebaut.'
  exit 0
}

& $iscc "/DAppVersion=$version" 'tool\installer\windows\KasseneckConnect.iss'
if ($LASTEXITCODE -ne 0) { throw "Inno Setup ist fehlgeschlagen." }

Write-Host "Fertig: build\KasseneckConnect-$version-windows-x64-setup.exe"
