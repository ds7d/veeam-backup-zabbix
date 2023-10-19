[Console]::OutputEncoding = New-Object System.Text.Utf8Encoding


Function GetUnixTimeUTC([AllowNull()][Nullable[DateTime]] $ttt) {
    if (!$ttt) { return 0 }
    [int]$unixtime = (get-date -Date $ttt.ToUniversalTime() -UFormat %s).`
    Substring(0,10)
    return $unixtime
}

function GetNumberOfRestorePoints($JobObject) {
    $Type = $JobObject.info.JobType

    if ($Type -eq 'NasBackup') {
        $NasBackup = Get-VBRNASBackup | ? {$_.JobId -eq $JobObject.Id}
        $RestorePoints = Get-VBRNASBackupRestorePoint -NASBackup $NasBackup
        $Grouped = $RestorePoints | Group-Object -property {$_.NASServerName}
    } else {
        $Backup = Get-VBRBackup | ? {$_.JobId -eq $JobObject.Id}
        if ($Backup -ne $null) {
            $RestorePoints = Get-VBRRestorePoint -Backup $Backup -ErrorAction Stop
            $Grouped = $RestorePoints | Group-Object -property {$_.Name}
        }
    }

    $Sorted = $Grouped | Sort-Object -Property Count -Descending
    try
    {
        return $Sorted[-1].Count
    }
    catch
    {
        return 0
    }
}



$AgentJobs = Get-VBRComputerBackupJob

$out_data_json = @{}
$jobs_list = New-Object System.Collections.ArrayList

# FOR EVERY AGENT JOB GATHER BASIC INFO
foreach ($Job in $AgentJobs)
{
# --------------  AGENT JOB LAST SESSION  ---------------------------

# CREATE A VARIABLE IDENTIFYING IF THE JOB IS A POLICY OR NOT
$IsPolicy = $False
if ($Job.Mode -eq 'ManagedByAgent') { $IsPolicy = $True }

# NOT ALL POLICY SESSIONS ARE BACKUPS, LOT OF CONFIG UPDATES THERE
# TO FILTER IT TO JUST ACTUAL BACKUPS THE NAME HAS WILDCARDS ADDED
# https://forums.veeam.com/post434804.html
$JobNameForQuery = $Job.Name
if ($IsPolicy) { $JobNameForQuery = '{0}?*' -f $Job.Name }
try
{
    $Sessions = Get-VBRComputerBackupJobSession -Name $JobNameForQuery -ErrorAction Stop
    $LastSession = $Sessions[0]
    $LastSessionTasks = Get-VBRTaskSession -Session $LastSession
}
catch
{
    #Write-Output "Something threw an exception"
    #Write-Output $_
    $LastSessionTasks = $null
}

# --------------  AGENT JOB ID, NAME, TYPE  -------------------------

$JOB_ID = $Job.Id
$JOB_NAME = $Job.Name
$JOB_DESCRIPTION = $Job.Description

if ($IsPolicy) {
    $JOB_TYPE = 'EpAgentPolicy'
} else {
    $JOB_TYPE = 'EpAgentBackup'
}

# --------------  AGENT JOB START AND STOP TIME  --------------------

$START_TIME_UTC_EPOCH = GetUnixTimeUTC($LastSession.CreationTime)
$STOP_TIME_UTC_EPOCH = GetUnixTimeUTC($LastSession.EndTime)

# --------------  AGENT JOB LAST SESSION RESULT  --------------------

# AGENT JOBS HAVE DIFFERENT RESULT CODES THAN REGULAR JOBS
#     RUNNING=0 | SUCCESS=1 | WARNING=2 | FAILED=3
# THEREFORE RESULT value__ WILL NOT BE USED, INSTEAD A HASHTABLE TRANSLATION

# HASHTABLE THAT EASES TRANSLATION OF RESULTS FROM A WORD TO A NUMBER
# 'NONE' RESULT APPEARS WHEN THE JOB IS RUNNING
###$ResultsTable = @{"Success"=0;"Warning"=1;"Failed"=2;"None"=-1}

# OFFICIAL VBR RESULT CODES: SUCCESS=0 | WARNING=1 | FAILED=2 | RUNNING=-1
# ADDED: DISABLED_OR_NOT_SCHEDULED=99 | RUNNING_FULL_OR_SYNT_FULL_BACKUP=-11
###$LAST_SESSION_RESULT_CODE = $ResultsTable[$LastSession.Result.ToString()]
$LAST_SESSION_RESULT = $LastSession.Result
$JOB_ENABLED = $Job.JobEnabled
$JOB_SCHEDULE_ENABLED = $Job.ScheduleEnabled


# --------------  AGENT JOB DATA SIZE  ------------------------------

$DATA_SIZE = 0

# THIS WORKS FOR FULL VOLUME BACKUPS AND ENTIRE MACHINE BACKUPS
foreach ($Task in $LastSessionTasks) {
    $DATA_SIZE += $Task.Progress.TotalUsedSize
}

# BACKUP MODE WHERE SELECTED FOLDERS ARE BACKED UP LACK CORRECT SIZE INFO
# TO GET AT LEAST ROUGH IDEA IS TO REPORT SIZE OF THE LAST FULL BACKUP - VBK
# IT WILL BE JUST APPROXIMATION AND IT MIGHT BE OLD INFO
if ($Job.BackupType -eq 'SelectedFiles') {
    $AgentBackup = Get-VBRBackup -Name $Job.Name
    $RestorePoints = Get-VBRRestorePoint -Backup $AgentBackup | `
                     Sort-Object -Property CreationTimeUtc -Descending
    $RestorePointsOnlyFull = $RestorePoints | ? {$_.IsFull}

    if ($RestorePointsOnlyFull.count -gt 0) {
        $Storage = $RestorePointsOnlyFull[0].FindStorage()
        $VbkSize = $Storage.Stats.BackupSize
        $DATA_SIZE = [int64]($VbkSize * 1.3)
    }
}

# --------------  GET AGENT JOB BACKUP SZE  -------------------------

$AgentBackup = Get-VBRBackup -Name $Job.Name
try
{
    $RestorePoints = Get-VBRRestorePoint -Backup $AgentBackup -ErrorAction Stop
}
catch
{
    #Write-Output "Something threw an exception"
    #Write-Output $_
    $RestorePoints = $null
}

$BACKUP_SIZE = 0
foreach ($r in $RestorePoints) {
    $Storage = $r.FindStorage()
    $BACKUP_SIZE += $Storage.Stats.BackupSize
}

# --------------  GET NUMBER OF RESTORE POINTS  ---------------------

$NUMBER_OF_RESTORE_POINTS = GetNumberOfRestorePoints $Job

$jobs_list.Add(@{"name"=$JOB_NAME}) |Out-Null

$jobs_json = @{}

$jobs_json.Add("job_id",$JOB_ID)
#$jobs_json.Add("job_name",$JOB_NAME)
$jobs_json.Add("job_description",$JOB_DESCRIPTION)
$jobs_json.Add("job_enabled",$JOB_ENABLED)
$jobs_json.Add("job_schedule",$JOB_SCHEDULE_ENABLED)
$jobs_json.Add("job_result",$LAST_SESSION_RESULT.ToString())# again convert to digit
$jobs_json.Add("job_start_time_timestamp_seconds",$START_TIME_UTC_EPOCH)
$jobs_json.Add("job_end_time_timestamp_seconds",$STOP_TIME_UTC_EPOCH)
$jobs_json.Add("job_data_size_bytes",$DATA_SIZE)
$jobs_json.Add("job_backup_size_bytes",$BACKUP_SIZE)
$jobs_json.Add("job_restore_points_total",$NUMBER_OF_RESTORE_POINTS)


$out_data_json.Add($JOB_NAME,$jobs_json)
$out_data_json_new = @{}
$out_data_json_new.Add("job_info",$out_data_json)
}

$out_data_json_new.Add("jobs",$jobs_list)

$out_data_json = @{}
$out_data_json.Add("data",$out_data_json_new)

$out_data_json| ConvertTo-Json -Depth 10 
