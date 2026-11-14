param([string]$Avd = 'LifePages_Pixel_API_36')
$ErrorActionPreference = 'Stop'
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$emulator = Join-Path $sdk 'emulator\emulator.exe'
$adb = Join-Path $sdk 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $emulator)) { throw 'Install Android Emulator with SDK Manager first.' }
& $emulator -accel-check
if ($LASTEXITCODE -ne 0) { throw 'Hardware acceleration is unavailable. Check Windows Hypervisor Platform and virtualization.' }
$avds = & $emulator -list-avds
if ($avds -notcontains $Avd) { throw "Missing AVD: $Avd. Create it using docs/ANDROID_DEVELOPMENT.md." }
Start-Process -FilePath $emulator -ArgumentList @('-avd', $Avd, '-memory', '2048', '-gpu', 'auto') -WindowStyle Normal
Write-Host 'Waiting for emulator (up to 3 minutes)...'
$ready = $false
for ($attempt = 0; $attempt -lt 90; $attempt++) {
    $devices = & $adb devices
    $serial = ($devices | Where-Object { $_ -match '^emulator-\d+\s+device$' } | Select-Object -First 1) -split '\s+'
    if ($serial[0]) {
        $boot = & $adb -s $serial[0] shell getprop sys.boot_completed 2>$null
        if ($boot -match '1') { $ready = $true; break }
    }
    Start-Sleep -Seconds 2
}
if (-not $ready) { throw 'Emulator did not boot within 3 minutes. Inspect Device Manager.' }
Write-Host "Ready: $($serial[0]). Select this device in VS Code and press F5."
