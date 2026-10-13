#requires -Version 7.0

<#
This script creates an Fileset backup in Rubrik RSC.
The parameters needed are hostname, fileset name and SLA name.
Hostname can be either, hostname, FQDN or IP address (hostname, if DNS search domain has been set in CDM/Edge/CCES)
The script reliese on Powershell 7.x
 
F.jorevall 2026-10-13

Install Rubrik Security Cloud powershell
Install-Module -Name RubrikSecurityCloud

Install service account file: (Windows)
Set-RscServiceAccountFile -InputFilePath .\my-authenication-file.json -OutputFilePath C:\Users\<user>\Documents\PowerShell\rubrik-powershell-sdk\rsc_service_account_default.xml

Install service account file: (MacOS)
Set-RscServiceAccountFile -InputFilePath ./my-authenication-file.json

get-help <rubrik cmd> -full will give online help for the command.
Online information regarding the Rubrik RSC powershell extension can be found here : https://developer.rubrik.com/SDKs-and-Tools/PowerShell/
#>

<#
.SYNOPSIS
    Start and monitor an RSC Windows fileset on-demand snapshot.
.DESCRIPTION
    Requires an authenticated Connect-Rsc session. Exact matches are mandatory;
    invalid names stop execution. Supports -Quiet and -WhatIf.
.EXAMPLE
    ./Start-RscFilesetBackup.ps1 -Hostname my.server.local -FilesetName my-fileset-001 -SlaName my-sla-001 -Quiet
.EXAMPLE
    ./Start-RscFilesetBackup.ps1 -Hostname my.server.local -FilesetName my-fileset-001 -SlaName my-sla-001 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Hostname,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilesetName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SlaName,
    [ValidateRange(1,3600)][int]$IntervalSeconds = 15,
    [ValidateRange(1,1440)][int]$TimeoutMinutes = 120,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}
function Stop-Script {
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$ExitCode = 1
    )
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $ExitCode
}

function Get-QueryPayload {
    param($Response, [string]$Field)
    if ($null -eq $Response) { return $null }
    if ($Response.PSObject.Properties['data']) {
        return $Response.data.$Field
    }
    if ($Response.PSObject.Properties[$Field]) {
        return $Response.$Field
    }
    return $Response
}

# Are we connected to Rubrik RSC?
try {
    $v = Get-RscVersion
    Write-Log "Connected to RSC. ServerVersion = $($v.ServerVersion)"
} catch {
    Stop-Script -Message "Not connected to RSC. Run Connect-Rsc first."
}

Write-Log ''
Write-Log 'Rubrik RSC - Windows Fileset Backup'
Write-Log '-----------------------------------'
Write-Log "Hostname       : $Hostname"
Write-Log "Fileset        : $FilesetName"
Write-Log "SLA Domain     : $SlaName"

# Resolve SLA by exact name.
$slaMatches = @(Get-RscSla -Name $SlaName | Where-Object { $_.Name -eq $SlaName })
if ($slaMatches.Count -eq 0) {
    Stop-Script -Message "SLA Domain '$SlaName' was not found. No backup was started."
}
if ($slaMatches.Count -ne 1) {
    Stop-Script -Message "Ambiguous SLA '$SlaName' ($($slaMatches.Count) matches). No backup was started."
}

$slaId = $slaMatches[0].Id
if (-not $slaId) { 
    Stop-Script -Message "SLA '$SlaName' has no ID." 
}
Write-Log "SLA ID         : $slaId"

# Resolve host, allowing an exact short-name match, never a partial-name match.
$hostMatches = @(Get-RscHost -Name $Hostname -OsType Windows | Where-Object {
    $_.Name -eq $Hostname -or $_.Name.Split('.')[0] -eq $Hostname
})
if ($hostMatches.Count -eq 0) {
    Stop-Script -Message "Windows host '$Hostname' was not found. No backup was started."
}
if ($hostMatches.Count -ne 1) { 
    Stop-Script -Message "Ambiguous Windows host '$Hostname' ($($hostMatches.Count) matches). No backup was started." 
}
$hostObj = $hostMatches[0]
Write-Log "RSC host       : $($hostObj.Name)"
Write-Log "Host ID        : $($hostObj.Id)"

$hostQuery = @'
query PhysicalHostFilesets($hostRoot: HostRoot!, $filter: [Filter!]!) {
  physicalHosts(hostRoot: $hostRoot, filter: $filter) {
    nodes {
      id
      name
      agentPrimaryClusterUuid
      descendantConnection(typeFilter: [WindowsFileset]) {
        nodes {
          id
          name
          objectType
          cluster { id name }
        }
      }
    }
  }
}
'@
$hostVars = @{
    hostRoot = 'WINDOWS_HOST_ROOT'
    filter = @(
        @{ field = 'NAME'; texts = @($hostObj.Name) },
        @{ field = 'IS_RELIC'; texts = @('false') },
        @{ field = 'IS_REPLICATED'; texts = @('false') }
    )
}
Write-Log 'Resolving fileset and Rubrik cluster...'
$hostResult = Invoke-Rsc -GqlQuery $hostQuery -Var $hostVars
$hostConnection = Get-QueryPayload -Response $hostResult -Field 'physicalHosts'
$hostNodes = @($hostConnection.Nodes | Where-Object { $_.Name -eq $hostObj.Name })
if ($hostNodes.Count -ne 1) { 
    Stop-Script -Message "Expected one matching physicalHosts node for '$($hostObj.Name)', found $($hostNodes.Count)." 
}
$hostNode = $hostNodes[0]
$filesetNodes = @($hostNode.DescendantConnection.Nodes)
$filesetMatches = @($filesetNodes | Where-Object { $_.Name -eq $FilesetName })
if ($filesetMatches.Count -eq 0) {
    Stop-Script -Message "Fileset '$FilesetName' was not found on host '$($hostObj.Name)'. No backup was started."
}
if ($filesetMatches.Count -ne 1) {
    Stop-Script -Message "Ambiguous fileset '$FilesetName' ($($filesetMatches.Count) matches). No backup was started." 
}
$filesetNode = $filesetMatches[0]
$filesetId = $filesetNode.Id
if (-not $filesetId) {
    Stop-Script -Message "Fileset '$FilesetName' has no ID." 
}
$clusterUuid = if ($filesetNode.Cluster -and $filesetNode.Cluster.Id) { $filesetNode.Cluster.Id } else { $hostNode.AgentPrimaryClusterUuid }
if (-not $clusterUuid) {
    Stop-Script -Message "Could not resolve cluster UUID for fileset '$FilesetName'." 
}
if ($clusterUuid -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
    Stop-Script -Message "Resolved cluster ID '$clusterUuid' is not a UUID. No backup was started." 
}
Write-Log "Fileset ID     : $filesetId"
Write-Log "Cluster UUID   : $clusterUuid"

# -WhatIf and -Confirm are handled by ShouldProcess.
$target = "$($hostObj.Name) / $($filesetNode.Name) (cluster $clusterUuid)"
if (-not $PSCmdlet.ShouldProcess($target, "Create on-demand snapshot with SLA '$SlaName'")) {
    return [pscustomobject]@{
        Hostname=$hostObj.Name; FilesetName=$filesetNode.Name; FilesetId=$filesetId
        SlaName=$slaMatches[0].Name; SlaId=$slaId; ClusterUuid=$clusterUuid
        RequestId=$null; Status='NOT_STARTED'; Progress=$null; StartTime=$null; EndTime=$null
    }
}

$odsMutation = @'
mutation TakeFilesetSnapshotMutation($config: BaseOnDemandSnapshotConfigInput!, $id: String!, $userNote: String) {
  createFilesetSnapshot(input: { config: $config, id: $id, userNote: $userNote }) {
    id
    status
  }
}
'@
$odsVars = @{
    id=$filesetId
    config=@{ slaId=$slaId }
    userNote="On-demand PowerShell backup: $($hostObj.Name) / $FilesetName"
}
Write-Log 'Triggering on-demand snapshot...'
$odsResult = Invoke-Rsc -GqlQuery $odsMutation -Var $odsVars
$odsResponse = Get-QueryPayload -Response $odsResult -Field 'createFilesetSnapshot'
if (-not $odsResponse -or -not $odsResponse.Id) {
    Stop-Script -Message 'Snapshot mutation returned no request ID.' 
}
$requestId = [string]$odsResponse.Id
Write-Log "Request ID     : $requestId"
Write-Log "Initial status : $($odsResponse.Status)"

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
$statusVars = @{ input=@{ clusterUuid=$clusterUuid; id=$requestId } }
$terminalStates = @('SUCCEEDED','FAILED','CANCELED','CANCELLED')
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
Write-Log 'Monitoring snapshot...'
while ($true) {
    if ((Get-Date) -ge $deadline) { 
        Stop-Script -Message "Timed out after $TimeoutMinutes minutes. Request ID: $requestId" 
    }
    $statusResult = Invoke-Rsc -GqlQuery $statusQuery -Var $statusVars
    $job = Get-QueryPayload -Response $statusResult -Field 'filesetRequestStatus'
    if (-not $job) { 
        Stop-Script -Message "No status returned for request '$requestId'." 
    }
    $status = [string]$job.Status
    if ([string]::IsNullOrWhiteSpace($status)) { 
        Stop-Script -Message "Empty status returned for request '$requestId'." 
    }
    Write-Log ("[{0}] Status: {1} | Progress: {2}%" -f (Get-Date -Format 'HH:mm:ss'), $status, $job.Progress)
    if ($status -in $terminalStates) {
        break 
    }
    Start-Sleep -Seconds $IntervalSeconds
}
Write-Log "Final status   : $status"
Write-Log "Start time     : $($job.StartTime)"
Write-Log "End time       : $($job.EndTime)"
if ($status -ne 'SUCCEEDED') { 
    Stop-Script -Message "Fileset backup ended with status '$status'. Request ID: $requestId" 
}
[pscustomobject]@{
    Hostname=$hostObj.Name; FilesetName=$filesetNode.Name; FilesetId=$filesetId
    SlaName=$slaMatches[0].Name; SlaId=$slaId; ClusterUuid=$clusterUuid
    RequestId=$requestId; Status=$status; Progress=$job.Progress
    StartTime=$job.StartTime; EndTime=$job.EndTime; NodeId=$job.NodeId
}
