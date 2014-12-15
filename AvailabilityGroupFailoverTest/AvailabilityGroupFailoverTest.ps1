[CmdletBinding(SupportsShouldProcess=$true)]
Param
(
    [Parameter(Mandatory=$false,
			   ValueFromPipeline=$true,
			   ValueFromPipelineByPropertyName=$true,
			   HelpMessage="Path to a file with a json string representing the desired fail-over configuration.")]
	[string]$jsonFilePath,
    [Parameter(Mandatory=$false,
			   ValueFromPipeline=$true,
			   ValueFromPipelineByPropertyName=$true,
			   HelpMessage="A json string representing the desired fail-over configuration.")]
	[string]$jsonString
)

function Get-AGState ()
{
    return Invoke-Sqlcmd -Query "SELECT replica_server_name
        , AG.name AS [AG_Name], HAGS.primary_replica
        , availability_mode_desc, failover_mode_desc
        FROM sys.availability_replicas AR
        INNER JOIN sys.dm_hadr_availability_group_states HAGS
        INNER JOIN sys.availability_groups AG ON AG.group_id = HAGS.group_id
            ON HAGS.group_id = AR.group_id;" -ServerInstance "$selectedNode";
}

function Get-DatabaseSyncStates([string]$AG, [string]$Server)
{
    return Invoke-Sqlcmd -Query "select DB_NAME(database_id) [Database]
        , ST.synchronization_state_desc [SyncState]
        FROM sys.dm_hadr_database_replica_states ST
        INNER JOIN sys.availability_groups AG ON AG.group_id = ST.group_id
        INNER JOIN sys.availability_replicas AR ON AR.replica_id = ST.replica_id
        WHERE AG.name = `'$AG`'
	        AND AR.replica_server_name = `'$Server`';" -ServerInstance "$Server";
}

function ValidateTargetReplicaConfiguration()
{
    [string[]]$primaries = $targetConfig.Replicas | Where-Object {$_.isPrimary -like "true"}
    if($primaries.Count -ne 1)
    {
        throw "There must be one, and only one, primary in the configuration.";
    }

    [string[]]$syncReplicas = $targetConfig.Replicas | Where-Object {$_.AvailabilityMode -like "SynchronousCommit"}
    if($syncReplicas.Count -gt 3)
    {
        throw "The requested configuration exceeds the maximum of three synchronous replicas which can be in an Availability Group configuration.";
    }

    if(($targetConfig.Replicas.Count -gt 5) -and ($majorSQLVersion -lt 12))
    {
        throw "The requested configuration exceeds the maximum of five replicas which can be in an Availability Group configuration for a SQL Server version below 12.";
    }
    
    if(($targetConfig.Replicas.Count -gt 9) -and ($majorSQLVersion -ge 12))
    {
        throw "The requested configuration exceeds the maximum of nine replicas which can be in an Availability Group configuration for a SQL Server version of 12 or greater.";
    }
}

#Error handling
$ErrorActionPreference = "Stop";
Trap {
  $err = $_.Exception
  while ( $err.InnerException )
    {
    $err = $err.InnerException
    write-output $err.Message
    };
  }

$totalScriptSteps = 13;
$currentStep = 0;

#Load dependencies
$currentStep++;
Write-Progress -Activity "Loading dependencies." -Status "Importing SQLPS module." -PercentComplete ($currentStep/$totalScriptSteps*100);
Import-Module SQLPS -DisableNameChecking;

#Validate input / load jsonString
$currentStep++;
Write-Progress -Activity "Validating input." -Status "Checking parameter requirements." -PercentComplete ($currentStep/$totalScriptSteps*100);

if ((!$jsonString) -and ($jsonFilePath))
{
    if(!(Test-Path $jsonFilePath))
    {
        throw "Invalid file path. ($jsonFilePath)";
    }
    $jsonString = Get-Content $jsonFilePath
}
elseif (!$jsonString)
{
    throw "You must input a JSON file path or a JSON string.";
}

#Load JSON
Write-Progress -Activity "Validating input." -Status "Loading JSON." -PercentComplete (3/$totalScriptSteps*100);
$targetConfig = $jsonString | ConvertFrom-Json;
$currentStep++;
Write-Progress -Activity "Validating input." -Status "Validating target replica configuration." -PercentComplete (/$totalScriptSteps*100);
ValidateTargetReplicaConfiguration;

#Build server object
$currentStep++;
Write-Progress -Activity "Validating input." -Status "Testing server connection." -PercentComplete ($currentStep/$totalScriptSteps*100);
$selectedNode = ($targetConfig.Replicas | Where-Object {$_.isPrimary -like "true"})[0].Name;
$newPrimaryReplicaName = $selectedNode;
if($newPrimaryReplicaName -notcontains "\")
{
    $newPrimaryReplicaName += "\DEFAULT";
}

$connStr = "Data Source=$selectedNode;Initial Catalog=master;Integrated Security=SSPI;MultiSubnetFailover=True;";
$sqlConn = New-Object ("System.Data.SqlClient.SqlConnection") $connStr;
$svrConn = New-Object ("Microsoft.SqlServer.Management.Common.ServerConnection") $sqlConn;
$destServer = New-Object ("Microsoft.SqlServer.Management.Smo.Server") $svrConn;

# Test connection
# Connection is not established when the objects are built.
# Instead, you need to process a query for a connection to be created.
# We check the version number as a light weight method of checking the connection.
$majorSQLVersion = $destServer.Version.Major;
if($majorSQLVersion -eq $null)
{
    throw  "Could not establish connection to $newPrimaryReplicaName."
}

$currentStep++;
Write-Progress -Activity "Validating input." -Status "Retrieving current Availability Group state." -PercentComplete ($currentStep/$totalScriptSteps*100);
$AGState = Get-AGState;
Write-Host -Object "Current Availability Group state:" -ForegroundColor Green -BackgroundColor Black;
$AGState | Format-Table;
Write-Host -Object "---------------------------------" -ForegroundColor Green -BackgroundColor Black;

if($AGState -eq $null)
{
    throw "Failed to retrieve Availability Group state from $newPrimaryReplicaName";
}

[string]$currentPrimaryReplica = $AGState[0].primary_replica;
if($currentPrimaryReplica -notcontains "\")
{
    $currentPrimaryReplica += "\DEFAULT";
}

if($currentPrimaryReplica -eq "$newPrimaryReplicaName")
{
    throw "$newPrimaryReplicaName is already the primary replica.";
}

# Failover prep
# You cannot have more than 3 synchronous commit replicas at one time.
# But we want to maintain synchronous commit replicas during the fail-over, if possible.
# So, we set just enough to async so that we can set our fail-over replica to synchronous.
$currentStep++;
Write-Progress -Activity "Failover preparation." -Status "Pre-configuring async replicas to avoid hitting synchronous commit limit during fail-over." -PercentComplete ($currentStep/$totalScriptSteps*100);
[string]$AGname = $AGState[0].AG_Name;
[string[]]$syncReplicas = $AGState | Where-Object {$_.availability_mode_desc -like "SYNCHRONOUS_COMMIT"};
$count = 0;
while($syncReplicas.Count -ge 3)
{
    [string]$asyncReplicaName = ($targetConfig.Replicas | Where-Object {$_.Name -notlike ($currentPrimaryReplica.Replace('\DEFAULT',''))} `
         | Sort-Object AvailabilityMode, Name)[$count].Name;
    Set-SqlAvailabilityReplica -AvailabilityMode "AsynchronousCommit" -FailoverMode "Manual" `
        -Path "SQLSERVER:\Sql\$currentPrimaryReplica\AvailabilityGroups\$AGname\AvailabilityReplicas\$asyncReplicaName";

    $count++;
    $AGState = Get-AGState;
    [string[]]$syncReplicas = $AGState | Where-Object {$_.availability_mode_desc -like "SYNCHRONOUS_COMMIT"};
}

$currentStep++;
Write-Progress -Activity "Failover preparation." -Status "Setting new primary target replica to synchronous commit to achieve zero data loss during fail-over." -PercentComplete ($currentStep/$totalScriptSteps*100);
$tempName = $newPrimaryReplicaName.Replace('\DEFAULT','');
Set-SqlAvailabilityReplica -AvailabilityMode "SynchronousCommit" -FailoverMode "Manual" `
    -Path "SQLSERVER:\Sql\$currentPrimaryReplica\AvailabilityGroups\$AGname\AvailabilityReplicas\$tempName";

#wait for new primary to sync up
$currentStep++;
Write-Progress -Activity "Failover preparation." -Status "Verifying that data synchronization is complete." -PercentComplete ($currentStep/$totalScriptSteps*100);
[System.Data.DataRow[]]$synchronizingDatabases = (Get-DatabaseSyncStates -AG $AGname -Server $tempName) | Where-Object {$_.SyncState -like "SYNCHRONIZING"};
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
$currentStep++;
while($synchronizingDatabases.Count -gt 0)
{
    $currentTime = $stopWatch.Elapsed;
    $elapsedTime = [string]::Format("Elapsed time: {0:d2}:{1:d2}:{2:d2}", $CurrentTime.hours, $CurrentTime.minutes, $CurrentTime.seconds)
    Write-Progress -Activity "Waiting for databases to synchronize." -Status $elapsedTime -PercentComplete ($currentStep/$totalScriptSteps*100);
    Start-Sleep -s 2;
    $synchronizingDatabases = (Get-DatabaseSyncStates -AG $AGname -Server $tempName) | Where-Object {$_.SyncState -like "SYNCHRONIZING"};
}    
$stopWatch.Stop();

# Failover
$to = $newPrimaryReplicaName.Replace('\DEFAULT','');
$from = $currentPrimaryReplica.Replace('\DEFAULT','');
$currentStep++;
Write-Progress -Activity "Failover." -Status "Failing over, without data loss, from $from to $to." -PercentComplete ($currentStep/$totalScriptSteps*100);
Switch-SqlAvailabilityGroup -Path "SQLSERVER:\Sql\$newPrimaryReplicaName\AvailabilityGroups\$AGname";

#Final Configuration

# Set availability and failover modes
# Sort ASC by AvailabilityMode so that Async is before Sync.
# This prevents us from adding a 4th sync replica before we establish the asyncs
$currentStep++;
Write-Progress -Activity "Final configuration." -Status "Set all replicas availability mode and failover mode to match target configuration." -PercentComplete ($currentStep/$totalScriptSteps*100);
foreach($replica in ($targetConfig.Replicas | Sort-Object AvailabilityMode))
{
    [string]$newAvailabilityMode = $replica.AvailabilityMode;
    [string]$newFailoverMode = $replica.FailoverMode;
    [string]$replicaName = $replica.Name;
    Set-SqlAvailabilityReplica -AvailabilityMode $newAvailabilityMode -FailoverMode $newFailoverMode `
        -Path "SQLSERVER:\Sql\$newPrimaryReplicaName\AvailabilityGroups\$AGname\AvailabilityReplicas\$replicaName";
}

$currentStep++;
Write-Progress -Activity "State review." -Status "Getting Availability Group state for review." -PercentComplete ($currentStep/$totalScriptSteps*100);
Write-Host -Object "Final Availability Group state:" -ForegroundColor Green -BackgroundColor Black;
Get-AGState | Format-Table;
Write-Host -Object "---------------------------------" -ForegroundColor Green -BackgroundColor Black;

