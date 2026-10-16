#requires -Version 7.0

<#
.SYNOPSIS
    Start an on-demand RSC fileset snapshot without waiting for completion.
.DESCRIPTION
    Resolves the Windows/Linux host, fileset, SLA Domain and Rubrik cluster UUID.
    Requires exact object matches, submits an asynchronous snapshot request,
    and returns RequestId and ClusterUuid for Get-RscFilesetBackupStatus.ps1.
    Does not monitor the backup after submission.
.PARAMETER Hostname
    Windows/Linux host registered in RSC.
.PARAMETER FilesetName
    RSC fileset to protect.
.PARAMETER SlaName
    SLA Domain applied to the on-demand snapshot.
.PARAMETER Quiet
    Suppresses informational messages; the result object is still returned.
.EXAMPLE
    ./Start-RscFilesetBackup.ps1 -Hostname server01.example.com -FilesetName Example-Fileset -SlaName Example-SLA -Quiet
    Submits a snapshot and returns the request information without log messages.
.EXAMPLE
    ./Start-RscFilesetBackup.ps1 -Hostname server01.example.com -FilesetName Example-Fileset -SlaName Example-SLA -WhatIf
    Resolves the objects and shows the proposed operation without submitting it.
.NOTES
    Project: Rubrik RSC fileset automation
    Author: Freddie Jörevall
    Platform: PowerShell 7 / macOS, Linux, Windows
    Dependencies: RubrikSecurityCloud PowerShell module

    Requirements: PowerShell 7+, RubrikSecurityCloud module, authenticated Connect-Rsc session,
                  and RSC permissions to view the objects and create fileset snapshots.
    Design: Separate backup submission from status monitoring. Never guess or substitute
            object names; abort before submission if resolution fails or is ambiguous.
    Output: A PowerShell object containing the asynchronous RequestId and ClusterUuid.
            Request acceptance does not imply backup completion or success.
    Examples use fictional names and the reserved example.com domain.

#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Hostname,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilesetName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SlaName,
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
if ($hostMatches.Count -ne 1) { Stop-Script -Message "Ambiguous Windows host '$Hostname' ($($hostMatches.Count) matches). No backup was started." }
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
$clusterUuid = if ($filesetNode.Cluster -and $filesetNode.Cluster.Id) { 
    $filesetNode.Cluster.Id 
} 
else { 
    $hostNode.AgentPrimaryClusterUuid
}
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

# Return identifiers for a separate status check.
[pscustomobject]@{
    Hostname=$hostObj.Name; FilesetName=$filesetNode.Name; FilesetId=$filesetId
    SlaName=$slaMatches[0].Name; SlaId=$slaId; ClusterUuid=$clusterUuid
    RequestId=$requestId; Status=[string]$odsResponse.Status
}
