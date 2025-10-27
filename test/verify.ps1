<#
PowerShell verification script for Blue/Green Nginx failover.
Reads environment variables from .env if present, otherwise uses process env.

Exits with code 0 on success, 1 on failure.
#>
param()

Set-StrictMode -Version Latest

function Load-DotEnv {
    $envFile = Join-Path (Get-Location) '.env'
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -and -not $_.StartsWith('#')) {
                $parts = $_ -split '='; if ($parts.Length -ge 2) {
                    $name = $parts[0].Trim(); $value = ($parts[1..($parts.Length-1)] -join '=').Trim();
                    if ($name) { Set-Item -Path Env:$name -Value $value }
                }
            }
        }
    }
}

function Fail($msg) {
    Write-Error $msg
    exit 1
}

# Wait for service to be ready
function Wait-ForService($url, $maxAttempts = 30, $sleepSec = 2) {
    Write-Host "Waiting for service at $url..."
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec 2 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                Write-Host "Service is ready!"
                return $true
            }
        } catch {
            Write-Host "Attempt $i/$maxAttempts: Service not ready yet..."
        }
        Start-Sleep -Seconds $sleepSec
    }
    return $false
}

Load-DotEnv

# Default to blue if not set
$activePool = if ($env:ACTIVE_POOL) { $env:ACTIVE_POOL.ToLower() } else { 'blue' }
if ($activePool -ne 'blue' -and $activePool -ne 'green') { Fail "ACTIVE_POOL must be 'blue' or 'green' (got '$activePool')" }

# ports
$publicUrl = 'http://localhost:8080'
$bluePort = 8081
$greenPort = 8082

$activePort = if ($activePool -eq 'blue') { $bluePort } else { $greenPort }
$backupPool = if ($activePool -eq 'blue') { 'green' } else { 'blue' }

$releaseIdBlue = $env:RELEASE_ID_BLUE
$releaseIdGreen = $env:RELEASE_ID_GREEN

# Wait for services to be ready
if (-not (Wait-ForService "$publicUrl/healthz")) {
    Fail "Timeout waiting for Nginx to be ready"
}
if (-not (Wait-ForService "http://localhost:$activePort/healthz")) {
    Fail "Timeout waiting for active app (port $activePort) to be ready"
}

Write-Host "Active pool: $activePool (direct port $activePort), backup: $backupPool"

function HttpGet($url, $timeout=8) {
    try {
        $resp = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec $timeout -UseBasicParsing -ErrorAction Stop
        return @{
            Success = $true
            Response = $resp
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function HttpPost($url, $timeout=8) {
    try {
        $resp = Invoke-WebRequest -Uri $url -Method POST -TimeoutSec $timeout -UseBasicParsing -ErrorAction Stop
        return @{
            Success = $true
            Response = $resp
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

# Baseline checks
Write-Host "Performing baseline checks against $publicUrl/version (expecting pool: $activePool)"
for ($i=1; $i -le 5; $i++) {
    Write-Host "Baseline request #$i..."
    $result = HttpGet "$publicUrl/version"
    if (-not $result.Success) { 
        Fail "Baseline request #$i failed: $($result.Error)" 
    }
    $r = $result.Response
    
    if ($r.StatusCode -ne 200) { 
        Fail "Baseline request #$i returned non-200: $($r.StatusCode)" 
    }
    
    # More detailed header checking
    if (-not $r.Headers.ContainsKey('X-App-Pool')) {
        Fail "Baseline request #$i missing X-App-Pool header"
    }
    if (-not $r.Headers.ContainsKey('X-Release-Id')) {
        Fail "Baseline request #$i missing X-Release-Id header"
    }
    
    $appPool = $r.Headers['X-App-Pool']
    $releaseId = $r.Headers['X-Release-Id']
    
    if ($appPool -ne $activePool) { 
        Fail "Baseline request #$i wrong pool header: $appPool (expected $activePool)" 
    }
    
    if ($activePool -eq 'blue') { 
        if ($releaseId -ne $releaseIdBlue) { 
            Fail "Baseline request #$i wrong release id: $releaseId (expected $releaseIdBlue)" 
        } 
    }
    if ($activePool -eq 'green') { 
        if ($releaseId -ne $releaseIdGreen) { 
            Fail "Baseline request #$i wrong release id: $releaseId (expected $releaseIdGreen)" 
        } 
    }
    Write-Host "Request #$i successful - pool: $appPool, release: $releaseId"
    Start-Sleep -Milliseconds 500
}
Write-Host "Baseline checks passed."

# Start chaos on active direct port
$chaosUrl = "http://localhost:$activePort/chaos/start?mode=error"
Write-Host "Starting chaos on active app: $chaosUrl"
$cr = HttpPost $chaosUrl
if (-not $cr.Success) { 
    Write-Warning "Chaos start request failed (non-fatal): $($cr.Error)" 
} else { 
    Write-Host "Chaos started." 
}

# Run loop for up to 10s to collect responses
$durationSec = 10
$endTime = (Get-Date).AddSeconds($durationSec)
$total = 0
$backupCount = 0

Write-Host "Starting failover test loop for ${durationSec}s..."
while ((Get-Date) -lt $endTime) {
    $result = HttpGet "$publicUrl/version" 8
    if (-not $result.Success) {
        Write-Host "Request failed: $($result.Error)"
        continue
    }
    $resp = $result.Response
    if ($resp.StatusCode -ne 200) { 
        Fail "During failover loop received non-200: $($resp.StatusCode)" 
    }
    
    if (-not $resp.Headers.ContainsKey('X-App-Pool')) {
        Write-Warning "Response missing X-App-Pool header"
        continue
    }
    
    $pool = $resp.Headers['X-App-Pool']
    if ($pool -eq $backupPool) { 
        $backupCount++ 
        Write-Host "Got response from backup pool ($backupPool)"
    } else {
        Write-Host "Got response from active pool ($activePool)"
    }
    $total++
    Start-Sleep -Milliseconds 500
}

# Stop chaos
$chaosStop = "http://localhost:$activePort/chaos/stop"
Write-Host "Stopping chaos on active app: $chaosStop"
$sr = HttpPost $chaosStop
if (-not $sr.Success) { 
    Write-Warning "Chaos stop request failed: $($sr.Error)" 
} else { 
    Write-Host "Chaos stopped." 
}

if ($total -eq 0) { Fail "No requests made during failover loop" }
$percent = ($backupCount / $total) * 100
Write-Host "Requests during failover loop: $total, responses from backup ($backupPool): $backupCount (${[math]::Round($percent,2)}%)"

if ($percent -lt 95) { Fail "Failover unsuccessful: only $([math]::Round($percent,2))% responses from backup (need >=95%)" }

Write-Host "Failover verification passed."
exit 0
