[CmdletBinding()]
param(
    [string]$InnoSetupCompiler = "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $scriptDir "..\..")
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$distDir = Join-Path $projectRoot "dist\windows"
$issPath = Join-Path $scriptDir "lancom.iss"

if (-not (Test-Path $InnoSetupCompiler)) {
    throw "Inno Setup compiler not found at '$InnoSetupCompiler'. Install Inno Setup 6 or pass -InnoSetupCompiler."
}

$versionLine = Select-String -Path $pubspecPath -Pattern '^version:\s*([^\s]+)' | Select-Object -First 1
if (-not $versionLine) {
    throw "Unable to read app version from pubspec.yaml."
}

$version = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]

Push-Location $projectRoot
try {
    flutter build windows --release

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null

    & $InnoSetupCompiler $issPath "/DMyAppVersion=$version" "/DMyOutputDir=$distDir"
}
finally {
    Pop-Location
}

Write-Host "Windows installer created in $distDir"
