<#
.SYNOPSIS
    Restores deleted Active Directory user accounts (AD Recycle Bin) from a list.

.DESCRIPTION
    Reads identifiers from a .txt (one per line, '#' comments allowed) or .csv file,
    finds the matching deleted user object, and restores it with Restore-ADObject.

    - Skips users that already exist as live objects.
    - Skips ambiguous entries (several deleted matches) unless -PickNewest is set.
    - Skips entries that would collide with a live sAMAccountName or UPN.
    - Rejects values containing LDAP wildcard or special characters.
    - Writes a result CSV log (also under -WhatIf) and exits 1 if anything failed.

    Requires: ActiveDirectory module, AD Recycle Bin enabled, and rights to restore
    objects (Reanimate Tombstones plus write access to the target OU).
    Run with -WhatIf first.

.NOTES
    Project: Bulk restore of AD users from the AD Recycle Bin.
    Author: Freddie Jörevall
    Platform: PowerShell / Windows
    Dependencies: Microsoft ActiveDirectort PowerShell module

.PARAMETER ListPath
    Path to the .txt or .csv list.

.PARAMETER Attribute
    Attribute the list values match against: sAMAccountName (default),
    userPrincipalName, or mail.

.PARAMETER CsvColumn
    Column to read when ListPath is a .csv. Default: the value of -Attribute.

.PARAMETER Delimiter
    CSV delimiter. Default ','. Use ';' for semicolon exports.

.PARAMETER TargetPath
    Optional DN of an OU/container to restore into. Needed when the original
    parent OU is itself deleted. Default: last known parent.

.PARAMETER PickNewest
    When several deleted objects match one entry, restore the one with the latest
    whenChanged. Without this switch such entries are logged as Ambiguous and skipped.

.PARAMETER DisableOnRestore
    Disable each account immediately after it is restored. Restore-ADObject cannot
    restore an object in a disabled state, so this is a second write right after the
    restore (a brief window of seconds exists where the account is in its old state).
    If the disable fails, the entry is logged as Failed with the account left restored.

.PARAMETER Server
    Optional domain controller. If omitted, one writable DC is discovered and used
    for the whole run.

.PARAMETER Credential
    Optional credential.

.PARAMETER LogPath
    Result CSV path. Default: .\Restore-ADUsers_<timestamp>.csv

.EXAMPLE
    .\Restore-ADUsersFromList.ps1 -ListPath .\users.txt -WhatIf

.EXAMPLE
    .\Restore-ADUsersFromList.ps1 -ListPath .\users.csv -CsvColumn Login -Delimiter ';' -TargetPath 'OU=Restored,DC=corp,DC=local'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ListPath,

    [ValidateSet('sAMAccountName', 'userPrincipalName', 'mail')]
    [string]$Attribute = 'sAMAccountName',

    [string]$CsvColumn,

    [string]$Delimiter = ',',

    [string]$TargetPath,

    [switch]$PickNewest,

    [switch]$DisableOnRestore,

    [string]$Server,

    [pscredential]$Credential,

    [string]$LogPath = (Join-Path $PWD.Path ("Restore-ADUsers_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date)))
)

Import-Module ActiveDirectory -ErrorAction Stop

$adParams = @{}
if ($Credential) { $adParams.Credential = $Credential }
if (-not $Server) {
    $dcLookup = @{ Discover = $true; Writable = $true; ErrorAction = 'Stop' }
    if ($Credential) { $dcLookup.Credential = $Credential }
    $Server = (Get-ADDomainController @dcLookup).HostName | Select-Object -First 1
}
$adParams.Server = $Server
Write-Host "Using domain controller: $Server"

# Recycle Bin must be enabled, otherwise deleted objects keep almost no attributes.
$rb = Get-ADOptionalFeature -Filter "name -eq 'Recycle Bin Feature'" @adParams
if (-not $rb -or -not $rb.EnabledScopes) {
    throw 'AD Recycle Bin is not enabled in this forest. Restore-ADObject cannot recover full user objects.'
}

if ($TargetPath) {
    $target = Get-ADObject -Identity $TargetPath -Properties objectClass @adParams -ErrorAction Stop
    if ($target.ObjectClass -notin 'organizationalUnit', 'container', 'domainDNS') {
        throw "TargetPath must be an OU or container, got '$($target.ObjectClass)'."
    }
}

$domainDn = (Get-ADDomain @adParams).DistinguishedName
$deletedBase = "CN=Deleted Objects,$domainDn"

# Load the list (UTF8 so names with accents survive Windows PowerShell 5.1)
$ext = [IO.Path]::GetExtension($ListPath).ToLowerInvariant()
if ($ext -eq '.csv') {
    $col = if ($CsvColumn) { $CsvColumn } else { $Attribute }
    $rows = @(Import-Csv -LiteralPath $ListPath -Delimiter $Delimiter -Encoding UTF8)
    if ($rows.Count -eq 0) { throw "CSV '$ListPath' is empty." }
    if ($rows[0].PSObject.Properties.Name -notcontains $col) {
        throw "Column '$col' not found in CSV. Columns: $($rows[0].PSObject.Properties.Name -join ', ')"
    }
    $raw = $rows | ForEach-Object { $_.$col }
}
else {
    $raw = Get-Content -LiteralPath $ListPath -Encoding UTF8
}

# Trim, drop blanks and comments, de-duplicate case-insensitively
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$items = New-Object System.Collections.Generic.List[string]
foreach ($r in $raw) {
    $v = "$r".Trim()
    if ($v -and -not $v.StartsWith('#') -and $seen.Add($v)) { $items.Add($v) }
}
if ($items.Count -eq 0) { throw 'No identifiers found in the list.' }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param($Id, $Status, $Detail, $Guid = '', $Dn = '')
    $results.Add([pscustomobject]@{
        Identifier = $Id; Status = $Status; Detail = $Detail; ObjectGUID = $Guid; DN = $Dn
    })
    $color = switch ($Status) {
        'Restored' { 'Green' } 'WhatIf' { 'Cyan' } { $_ -in 'Skipped', 'Ambiguous', 'Conflict', 'Declined' } { 'Yellow' } default { 'Red' }
    }
    Write-Host ("[{0}] {1}: {2}" -f $Status, $Id, $Detail) -ForegroundColor $color
}

foreach ($id in $items) {
    try {
        # Reject LDAP wildcard/special characters: a '*' would match several accounts.
        if ($id -match '[*()\\\x00]') {
            Add-Result $id 'Failed' 'Value contains a wildcard or special character (* ( ) \ NUL). Fix the list entry.'
            continue
        }
        $safe = $id.Replace("'", "''")

        # Already live?
        $live = Get-ADUser -Filter "$Attribute -eq '$safe'" @adParams -ErrorAction Stop
        if ($live) {
            Add-Result $id 'Skipped' 'A live account with this value already exists.' '' $live.DistinguishedName
            continue
        }

        $deleted = @(Get-ADObject -IncludeDeletedObjects -SearchBase $deletedBase -SearchScope OneLevel @adParams -ErrorAction Stop `
            -Filter "objectClass -eq 'user' -and $Attribute -eq '$safe'" `
            -Properties lastKnownParent, whenChanged, sAMAccountName, userPrincipalName, mail |
            Where-Object { $_.sAMAccountName -and -not $_.sAMAccountName.EndsWith('$') })

        if ($deleted.Count -eq 0) {
            Add-Result $id 'NotFound' 'No deleted user object matches (not deleted, past deleted-object lifetime, or wrong value).'
            continue
        }

        if ($deleted.Count -gt 1 -and -not $PickNewest) {
            $guids = ($deleted | ForEach-Object { $_.ObjectGUID }) -join ' '
            Add-Result $id 'Ambiguous' "$($deleted.Count) deleted matches, skipped (use -PickNewest). GUIDs: $guids"
            continue
        }

        $pick = $deleted | Sort-Object whenChanged -Descending | Select-Object -First 1
        $note = if ($deleted.Count -gt 1) { "$($deleted.Count) deleted matches, newest picked (changed $($pick.whenChanged)). " } else { '' }

        # Collision checks against live objects
        if ($pick.sAMAccountName) {
            $c = Get-ADUser -Filter "sAMAccountName -eq '$($pick.sAMAccountName.Replace("'", "''"))'" @adParams -ErrorAction Stop
            if ($c) {
                Add-Result $id 'Conflict' "sAMAccountName '$($pick.sAMAccountName)' is used by a live account." $pick.ObjectGUID $c.DistinguishedName
                continue
            }
        }
        if ($pick.userPrincipalName) {
            $c = Get-ADUser -Filter "userPrincipalName -eq '$($pick.userPrincipalName.Replace("'", "''"))'" @adParams -ErrorAction Stop
            if ($c) {
                Add-Result $id 'Conflict' "UPN '$($pick.userPrincipalName)' is used by a live account." $pick.ObjectGUID $c.DistinguishedName
                continue
            }
        }

        $restoreParams = @{ Identity = $pick.ObjectGUID.ToString(); Confirm = $false; ErrorAction = 'Stop' } + $adParams
        if ($TargetPath) { $restoreParams.TargetPath = $TargetPath }
        $dest = if ($TargetPath) { $TargetPath } else { $pick.lastKnownParent }

        if ($WhatIfPreference) {
            $dis = if ($DisableOnRestore) { ' and disable' } else { '' }
            Add-Result $id 'WhatIf' ($note + "Would restore$dis to $dest.") $pick.ObjectGUID
        }
        elseif ($PSCmdlet.ShouldProcess("$id ($($pick.ObjectGUID))", "Restore-ADObject to $dest")) {
            Restore-ADObject @restoreParams
            $new = Get-ADObject -Identity $pick.ObjectGUID.ToString() @adParams -ErrorAction Stop
            if ($DisableOnRestore) {
                try {
                    Disable-ADAccount -Identity $pick.ObjectGUID.ToString() -Confirm:$false -ErrorAction Stop @adParams
                    Add-Result $id 'Restored' ($note + 'Restored and disabled.') $pick.ObjectGUID $new.DistinguishedName
                }
                catch {
                    Add-Result $id 'Failed' ($note + "Restored but DISABLE FAILED, account is still in its old state: $($_.Exception.Message)") $pick.ObjectGUID $new.DistinguishedName
                }
            }
            else {
                Add-Result $id 'Restored' ($note + 'Restored.') $pick.ObjectGUID $new.DistinguishedName
            }
        }
        else {
            Add-Result $id 'Declined' 'Not restored (confirmation declined).' $pick.ObjectGUID
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'parent|no such object') {
            $msg += ' (If the original parent OU is deleted, rerun with -TargetPath. A live object with the same CN in the target also causes this.)'
        }
        Add-Result $id 'Failed' $msg
    }
}

try {
    $results | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false -ErrorAction Stop
    Write-Host "`nLog written to $LogPath"
}
catch {
    Write-Warning "Could not write log to ${LogPath}: $($_.Exception.Message)"
}

$results | Group-Object Status | Sort-Object Name |
    ForEach-Object { Write-Host ("{0,-10} {1}" -f $_.Name, $_.Count) }

if ($results | Where-Object { $_.Status -eq 'Failed' }) { exit 1 }
