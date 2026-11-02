# Guide - run the app on the phone (wireless adb) with hot reload.
#
# Usage, from the app/ directory:
#   .\run_phone.ps1              # OSM fallback map
#   .\run_phone.ps1 -GoogleMaps  # Google Maps engine (needs secrets.properties)
#
# Inside the flutter run session:
#   r = hot reload   R = hot restart   q = quit (app keeps running on 'd')
#
# The backend must already be running on this PC (backend/ : uvicorn ...).
# The app reaches it at http://127.0.0.1:8000 via an `adb reverse` tunnel,
# which this script (re)creates every time - wireless adb drops reset it.

param(
    [switch]$GoogleMaps,
    [string]$BackendUrl = "http://127.0.0.1:8000"
)

$ErrorActionPreference = "Stop"

# 1) Flutter on PATH (per-shell; the SDK lives outside the system PATH here)
$env:Path += ";C:\Users\TASSNEEM\flutter\bin"

# 2) Locate the phone (wireless adb serials rotate; match any adb-* device)
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$serial = & $adb devices |
    Select-String "^(adb-\S+)\s+device$" |
    ForEach-Object { $_.Matches[0].Groups[1].Value } |
    Select-Object -First 1

if (-not $serial) {
    Write-Host "No wireless device found. On the phone: Settings > Developer options" -ForegroundColor Yellow
    Write-Host "> Wireless debugging, then pair/connect. Re-run this script after." -ForegroundColor Yellow
    exit 1
}
Write-Host "Device: $serial" -ForegroundColor Cyan

# 3) Tunnel phone localhost:8000 -> this PC's backend
& $adb -s $serial reverse tcp:8000 tcp:8000 | Out-Null
$backendPort = ([Uri]$BackendUrl).Port
if ($backendPort -ne 8000) {
    & $adb -s $serial reverse tcp:$backendPort tcp:$backendPort | Out-Null
}
Write-Host "Tunnel: device tcp:$backendPort -> host tcp:$backendPort" -ForegroundColor Cyan

# 4) Run with hot reload attached
$defines = @("--dart-define=BACKEND_URL=$BackendUrl")
if ($GoogleMaps) {
    $defines += "--dart-define=USE_GOOGLE_MAPS=true"
    if (-not (Test-Path "android\secrets.properties")) {
        Write-Host "Warning: android\secrets.properties missing - Google map will be blank." -ForegroundColor Yellow
        Write-Host "Copy Secrets.properties.example and set GOOGLE_MAPS_API_KEY." -ForegroundColor Yellow
    }
}

flutter run -d $serial @defines
