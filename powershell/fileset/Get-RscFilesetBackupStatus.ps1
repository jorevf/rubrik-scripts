#requires -Version 7.0

<#
.SYNOPSIS
    Check or monitor the status of an RSC fileset snapshot request.
.DESCRIPTION
    Queries filesetRequestStatus for a previously submitted asynchronous request.
    By default performs one check and returns a detailed status object.
    -Monitor polls until a terminal state or timeout. -Quiet returns only a Boolean:
    $true for SUCCEEDED and $false for all other reported states.
.PARAMETER RequestId
    Asynchronous request ID returned by Start-RscFilesetBackup.ps1.
.PARAMETER ClusterUuid
    Rubrik cluster UUID returned by Start-RscFilesetBackup.ps1.
.PARAMETER Monitor
    Polls repeatedly until the request finishes or the timeout is reached.
.PARAMETER Quiet
    Returns only $true if the snapshot succeeded; otherwise $false.
.PARAMETER IntervalSeconds
    Polling interval in seconds when -Monitor is specified (default 15).
.PARAMETER TimeoutMinutes
    Maximum monitoring duration in minutes (default 120).
.EXAMPLE
    $job = ./Start-RscFilesetBackup.ps1 -Hostname server01.example.com -FilesetName Example-Fileset -SlaName Example-SLA -Quiet
    ./Get-RscFilesetBackupStatus.ps1 -RequestId $job.RequestId -ClusterUuid $job.ClusterUuid
    Checks the submitted request once and returns its current status.
.EXAMPLE
    ./Get-RscFilesetBackupStatus.ps1 -RequestId $job.RequestId -ClusterUuid $job.ClusterUuid -Monitor -IntervalSeconds 15
    Polls until the request reaches a terminal state or times out.
.EXAMPLE
    $ok = ./Get-RscFilesetBackupStatus.ps1 -RequestId $job.RequestId -ClusterUuid $job.ClusterUuid -Quiet
    Returns $true only when the request status is SUCCEEDED.
.NOTES
    Project: Rubrik RSC fileset automation
    Author: Freddie Jörevall
    Platform: PowerShell 7 / macOS, Linux, Windows
    Dependencies: RubrikSecurityCloud PowerShell module
  
    Requirements: PowerShell 7+, RubrikSecurityCloud module, authenticated Connect-Rsc session,
                  and RSC permissions to query fileset request status.
    Design: Status checking is independent of snapshot submission; the caller can
            query the request from a later session using RequestId and ClusterUuid.
    Output: Detailed status object by default; Boolean with -Quiet.
            In -Quiet mode, running, failed and cancelled requests all return $false;
            use normal mode to distinguish these states. Errors and timeouts exit nonzero.
    Examples use fictional names and the reserved example.com domain.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequestId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClusterUuid,
    [switch]$Monitor,
    [switch]$Quiet,
    [ValidateRange(1,3600)][int]$IntervalSeconds = 15,
    [ValidateRange(1,1440)][int]$TimeoutMinutes = 120
)

$ErrorActionPreference = 'Stop'

function Stop-Script {
    param([Parameter(Mandatory)][string]$Message, [int]$ExitCode = 1)
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $ExitCode
}

if ($ClusterUuid -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
    Stop-Script -Message "ClusterUuid '$ClusterUuid' is not a UUID."
}

$statusQuery = @'
query CheckJobStatus($input: GetFilesetAsyncRequestStatusInput!) {
  filesetRequestStatus(input: $input) {
    status
    startTime
    endTime
    nodeId
    progress
  }
}
'@
$statusVars = @{ input = @{ clusterUuid = $ClusterUuid; id = $RequestId } }
$terminalStates = @('SUCCEEDED', 'FAILED', 'CANCELED', 'CANCELLED')
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

try {
    do {
        $response = Invoke-Rsc -GqlQuery $statusQuery -Var $statusVars
        if ($null -eq $response) { Stop-Script -Message 'Empty response from filesetRequestStatus.' }

        $job = $response
        if ($response.PSObject.Properties['data']) {
            $job = $response.data.filesetRequestStatus
        }
        elseif ($response.PSObject.Properties['filesetRequestStatus']) {
            $job = $response.filesetRequestStatus
        }

        if ($null -eq $job -or [string]::IsNullOrWhiteSpace([string]$job.Status)) {
            Stop-Script -Message "No valid status for request '$RequestId'."
        }

        $status = [string]$job.Status
        if (-not $Quiet) {
            Write-Host ("[{0}] Status: {1} | Progress: {2}%" -f `
                (Get-Date -Format 'HH:mm:ss'), $status, $job.Progress)
        }

        if (-not $Monitor -or $status -in $terminalStates) { break }
        if ((Get-Date) -ge $deadline) {
            Stop-Script -Message "Timed out after $TimeoutMinutes minutes. Request ID: $RequestId"
        }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)
}
catch {
    Stop-Script -Message $_.Exception.Message
}

if ($Quiet) {
    # Success only. A running, failed or cancelled backup is false.
    return ($status -eq 'SUCCEEDED')
}

[pscustomobject]@{
    RequestId   = $RequestId
    ClusterUuid = $ClusterUuid
    Status      = $status
    Completed   = ($status -in $terminalStates)
    Succeeded   = ($status -eq 'SUCCEEDED')
    Progress    = $job.Progress
    StartTime   = $job.StartTime
    EndTime     = $job.EndTime
    NodeId      = $job.NodeId
}
