# Install Rubrik Security Cloud powershell
# Install-Module -Name RubrikSecurityCloud
# Install service account file
# Set-RscServiceAccountFile -InputFilePath .\auth01.json -OutputFilePath C:\Users\<user>\Documents\PowerShell\rubrik-powershell-sdk\rsc_service_account_default.xml
# get-help <rubrik cmd> -full will give online help for the command.
# Online ifnroamtion regarding the Rubrik RSC powershell extension can be found here : https://developer.rubrik.com/SDKs-and-Tools/PowerShell/

Import-Module RubrikSecurityCloud

#  Connect to RSC (assumes you’ve already set your service account file)
Connect-RSC

# Get the RSC cluster object
$src_host_name = "src.host.fqdn"
$dst_host_name = "dst.host.fqdn"
$myDb = "AdventureWorks2016"
$lmdbname = $myDb + "_live_mount"
$sinstance = "MSSQLSERVER"
$tinstance = "MSSQLSERVER"

write-host("Getting the MSSQL Source Instance")

# Get MSSQL instance objects for source and target hosts
$sourceInstance = (
    	Get-RscMssqlInstance -HostName $src_host_name | Where-Object Name -eq $sinstance
	    )

write-host("Getting the MSSQL Destination Instance")

$targetInstance = (
    	Get-RscMssqlInstance -HostName $dst_host_name | Where-Object Name -eq $tinstance
	    )

# Check is the live_mount name is already in use

$existingLM = Get-RscMssqlLiveMount |
    Where-Object {
        $_.MountedDatabaseName -eq $lmdbname
        }

if ($existingLM) {
    Write-Host "Live Mount $lmdbname already exists"
    Disconnect-Rsc
    exit
    }

# Get the MSSQL database object (NOT just the name string)

write-host("Getting the MSSQL database object")

#Using Get-RscMssqlDatabaseRecoverableRanges it will provide available snpashots and log backups.
#Get-RscMssqlDatabaseRecoverableRanges -RscMssqlDatabase $myDb                      
#Get-RscMssqlDatabaseRecoverableRanges field profile: DEFAULT
#
#BeginTime           EndTime             IsMountAllowed Status
#---------           -------             -------------- ------
#2026-06-18 13:24:22 2026-06-18 13:24:22           True OK
#2026-06-19 01:24:23 2026-06-22 23:16:50           True OK

# First entry is the first full backup
# Second entry is database backup and logbackups
# So for the second entry,  you can use for example (2026-06-22T13:45:05.000Z) this is UTZ time.
# it will first livemount the closeset database snapshot, and then restore logbackup up to the desire date/time.

# Get the database object
$database = Get-RscMssqlDatabase -Name $myDb -RscMssqlInstance $sourceInstance

# List available snapshots.
Write-host("List available snapshots for $myDb")
$recoverpoints = Get-RscMssqlDatabaseRecoverableRanges -RscMssqlDatabase $database
$recoverpoints

# Get the intended recovery point.
write-host("Getting the MSSQ recovery point")

# This is the way to get the time/date for the latest database snapshot.
#$recoveryDateTime = Get-RscMssqlDatabaseRecoveryPoint -RscMssqlDatabase $database -Latest

# Get recovery point based on time/date
$mydate = "2026-06-22T14:05:05.000Z"
$recoveryDateTime = Get-RscMssqlDatabaseRecoveryPoint -RscMssqlDatabase $database -RestoreTime $mydate

write-host($recoveryDateTime)

# Build the parameter hashtable and call New-RscMssqlLiveMount

write-host("Mounting $myDb on host $dst_host_name as $lmdbname ")
$newRscMssqlLiveMount = @{
    RscMssqlDatabase   = $database
    MountedDatabaseName = $lmdbname
    TargetMssqlInstance = $targetInstance
    RecoveryDateTime    = $recoveryDateTime
    }

$rscRequest = New-RscMssqlLiveMount @newRscMssqlLiveMount

write-host($rscRequest)
$rscRequest | Format-List *

# To unmount the live mount, then the following cmd can be used.
# $themount = Get-RscMssqlLiveMount -MountedDatabaseName AdventureWorks2016_live_mount
# Remove-RscMssqlLiveMount -MssqlLiveMount $themount

Disconnect-Rsc
