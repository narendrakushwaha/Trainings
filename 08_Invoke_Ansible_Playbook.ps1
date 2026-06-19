# ============================================================
# Invoke-AnsiblePlaybook.ps1
# Trigger an Ansible Job Template via AWX / Ansible Tower API
# with extra_vars parameters.
# ============================================================

# ── Configuration ───────────────────────────────────────────
$TowerUrl       = "https://your-tower-host"   # No trailing slash
$JobTemplateId  = 42                           # AWX Job Template ID
$TowerUser      = "admin"
$TowerPassword  = "yourpassword"

# Extra vars to pass to the playbook (key/value pairs)
$ExtraVars = @{
    env          = "production"
    app_version  = "2.5.1"
    deploy_user  = "deployer"
    rollback     = $false
}

# ── Helper: Ignore self-signed certs (dev/lab only) ─────────
# Comment this block out in production environments
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
[System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

# ── Step 1: Build Basic Auth header ─────────────────────────
$credPair  = "${TowerUser}:${TowerPassword}"
$encodedCreds = [System.Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes($credPair)
)
$Headers = @{
    Authorization  = "Basic $encodedCreds"
    "Content-Type" = "application/json"
}

# ── Step 2: Build the request body ──────────────────────────
# extra_vars must be sent as a JSON-encoded STRING, not a nested object
$ExtraVarsJson = $ExtraVars | ConvertTo-Json -Compress

$Body = @{
    extra_vars = $ExtraVarsJson
} | ConvertTo-Json

# ── Step 3: Launch the job ───────────────────────────────────
$LaunchUrl = "$TowerUrl/api/v2/job_templates/$JobTemplateId/launch/"

Write-Host "Launching job template $JobTemplateId ..." -ForegroundColor Cyan

try {
    $Response = Invoke-RestMethod `
        -Uri         $LaunchUrl `
        -Method      POST `
        -Headers     $Headers `
        -Body        $Body `
        -ErrorAction Stop

    $JobId  = $Response.job
    $JobUrl = "$TowerUrl/api/v2/jobs/$JobId/"
    Write-Host "Job launched! Job ID: $JobId" -ForegroundColor Green
    Write-Host "Job URL : $JobUrl"
}
catch {
    Write-Error "Failed to launch job: $_"
    exit 1
}

# ── Step 4: Poll until the job finishes ─────────────────────
$PollIntervalSec = 10
$TimeoutSec      = 600   # 10 minutes max
$Elapsed         = 0
$TerminalStates  = @("successful", "failed", "error", "canceled")

Write-Host "`nPolling job status every ${PollIntervalSec}s (timeout ${TimeoutSec}s)..."

do {
    Start-Sleep -Seconds $PollIntervalSec
    $Elapsed += $PollIntervalSec

    try {
        $JobStatus = Invoke-RestMethod `
            -Uri     $JobUrl `
            -Method  GET `
            -Headers $Headers `
            -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not fetch status (retrying): $_"
        continue
    }

    $Status   = $JobStatus.status
    $Started  = $JobStatus.started
    $Finished = $JobStatus.finished

    Write-Host "[$Elapsed s] Status: $Status"

    if ($Status -in $TerminalStates) { break }

} while ($Elapsed -lt $TimeoutSec)

# ── Step 5: Final result ─────────────────────────────────────
Write-Host ""
if ($Status -eq "successful") {
    Write-Host "SUCCESS  Job $JobId completed successfully." -ForegroundColor Green
}
elseif ($Status -in @("failed", "error")) {
    Write-Host "FAILURE  Job $JobId ended with status: $Status" -ForegroundColor Red
    exit 1
}
elseif ($Status -eq "canceled") {
    Write-Host "CANCELED Job $JobId was canceled." -ForegroundColor Yellow
    exit 2
}
else {
    Write-Warning "Timed out after ${TimeoutSec}s. Last status: $Status"
    exit 3
}

# ── Step 6 (optional): Fetch the job's stdout log ────────────
$StdoutUrl = "$TowerUrl/api/v2/jobs/$JobId/stdout/?format=txt"
Write-Host "`nFetching job output from: $StdoutUrl"

try {
    $Log = Invoke-RestMethod `
        -Uri     $StdoutUrl `
        -Method  GET `
        -Headers $Headers `
        -ErrorAction Stop

    Write-Host "`n===== Ansible Output =====" -ForegroundColor DarkCyan
    Write-Host $Log
}
catch {
    Write-Warning "Could not retrieve job output: $_"
}