param(
    [string]$Stage = 'C:\DroidVM',
    [switch]$Shutdown
)

$ErrorActionPreference = 'Stop'
$flag = Join-Path $Stage 'finalize-online.flag'
$log = Join-Path $Stage 'finalize.log'
$marker = Join-Path $Stage 'FINALIZE.OK'

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format o), $Message
    $line | Tee-Object -FilePath $log -Append
}

if (-not (Test-Path $flag)) {
    exit 0
}

$failures = 0
try {
    Write-Log 'start online finalization'
    Write-Log "user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $driverRoot = Join-Path $Stage 'drivers'
    if (Test-Path $driverRoot) {
        $infs = Get-ChildItem $driverRoot -Recurse -File -Filter '*.inf'
        Write-Log "installing $($infs.Count) driver packages from $driverRoot"
        foreach ($inf in $infs) {
            Write-Log "pnputil add-driver: $($inf.FullName)"
            $output = & pnputil.exe /add-driver $inf.FullName /install 2>&1
            $output | ForEach-Object { Write-Log ([string]$_) }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "driver package failed with exit code ${LASTEXITCODE}: $($inf.FullName)"
                $failures++
            }
        }
    } else {
        Write-Log "driver staging directory not found: $driverRoot"
        $failures++
    }

    Write-Log 'removing non-essential provisioned Appx packages'
    $keep = 'VCLibs|NET\.Native|UI\.Xaml|Store|SecHealth|Photos|Notepad|Terminal|WindowsTerminal'
    Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -notmatch $keep } | ForEach-Object {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
            Write-Log "removed Appx: $($_.DisplayName)"
        } catch {
            Write-Log "Appx removal skipped ($($_.DisplayName)): $($_.Exception.Message)"
        }
    }

    Write-Log 'running DISM component cleanup and ResetBase'
    $dismOutput = & dism.exe /English /Online /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart 2>&1
    $dismOutput | ForEach-Object { Write-Log ([string]$_) }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "DISM cleanup failed with exit code $LASTEXITCODE"
        $failures++
    }

    Write-Log 'disabling hibernation and reserved storage'
    & powercfg.exe /hibernate off 2>&1 | ForEach-Object { Write-Log ([string]$_) }
    & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' /v ShippedWithReserves /t REG_DWORD /d 0 /f 2>&1 | ForEach-Object { Write-Log ([string]$_) }

    Write-Log 'running filesystem TRIM'
    & Optimize-Volume -DriveLetter C -ReTrim -Verbose 4>&1 | ForEach-Object { Write-Log ([string]$_) }

    $driverSummary = & pnputil.exe /enum-drivers 2>&1
    $driverSummary | ForEach-Object { Write-Log ([string]$_) }

    if ($failures -eq 0) {
        Set-Content -LiteralPath $marker -Value 'success' -Encoding ascii
        Write-Log 'success'
    } else {
        Write-Log "completed with $failures failure(s)"
    }
} catch {
    Write-Log "fatal: $($_.Exception.Message)"
    Write-Log ($_ | Out-String)
} finally {
    if ($Shutdown) {
        Write-Log 'shutting down'
        & shutdown.exe /s /t 10 /f
    }
}
