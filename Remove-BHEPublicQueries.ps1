#Requires -Version 5.1
<#
.SYNOPSIS
Preview or delete public saved queries owned by one BloodHound application user.
.DESCRIPTION
Omit OwnerUserId for interactive user/query selection. With OwnerUserId, preview
is the default. -Delete requires -BackupPath and supports -WhatIf/-Confirm.
Authenticate with an administrator API token ID/key, or an existing bearer JWT.
OwnerUserId is the BloodHound application user's UUID, not an AD object ID.
Use -EnvFile for literal BHE_URL/BHE_TOKEN_ID/BHE_TOKEN_KEY settings.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [uri]$BaseUrl,
    [string]$EnvFile,
    [guid]$OwnerUserId,
    [string]$TokenId = $env:BHE_TOKEN_ID,
    [string]$TokenKey = $env:BHE_TOKEN_KEY,
    [string]$BearerToken = $env:BHE_BEARER_TOKEN,
    [switch]$Delete,
    [string]$BackupPath,
    [ValidateRange(1, 1000)][int]$PageSize = 100,
    [ValidateRange(1, 100000)][int]$MaxQueries = 10000,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read configuration as data only: no dot-sourcing, command evaluation, or expansion.
$fileSettings = @{}
if ($PSBoundParameters.ContainsKey('EnvFile')) {
    if ([string]::IsNullOrWhiteSpace($EnvFile)) { throw 'EnvFile cannot be empty.' }
    $envPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
    $lines = [IO.File]::ReadAllLines($envPath, [Text.Encoding]::UTF8)
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            throw "Invalid env file syntax on line $lineNumber. Expected NAME=value."
        }
        $name = $Matches[1].ToUpperInvariant()
        $value = $Matches[2].Trim()
        if ($name -notin @('BHE_URL','BHE_TOKEN_ID','BHE_TOKEN_KEY','BHE_BEARER_TOKEN')) {
            throw "Unsupported setting on env file line $lineNumber."
        }
        if ($fileSettings.ContainsKey($name)) { throw "Duplicate setting on env file line $lineNumber." }
        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            $quote = $value.Substring(0,1)
            if ($value.Length -lt 2 -or -not $value.EndsWith($quote)) {
                throw "Unclosed quoted value on env file line $lineNumber."
            }
            $value = $value.Substring(1,$value.Length-2)
        }
        $fileSettings[$name] = $value
    }
}
# Precedence per setting: explicit parameter > env file > process environment.
if (-not $PSBoundParameters.ContainsKey('BaseUrl')) {
    $urlValue = if ($fileSettings.ContainsKey('BHE_URL')) { $fileSettings['BHE_URL'] } else { $env:BHE_URL }
    if ([string]::IsNullOrWhiteSpace($urlValue)) { throw 'Supply BaseUrl, or BHE_URL in the env file/process environment.' }
    $parsedUrl = $null
    if (-not [uri]::TryCreate($urlValue, [UriKind]::Absolute, [ref]$parsedUrl)) {
        throw 'BHE_URL must be an absolute tenant URL (HTTPS, or HTTP on loopback).'
    }
    $BaseUrl = $parsedUrl
}
if (-not $PSBoundParameters.ContainsKey('TokenId') -and $fileSettings.ContainsKey('BHE_TOKEN_ID')) {
    $TokenId = $fileSettings['BHE_TOKEN_ID']
}
if (-not $PSBoundParameters.ContainsKey('TokenKey') -and $fileSettings.ContainsKey('BHE_TOKEN_KEY')) {
    $TokenKey = $fileSettings['BHE_TOKEN_KEY']
}
if (-not $PSBoundParameters.ContainsKey('BearerToken') -and $fileSettings.ContainsKey('BHE_BEARER_TOKEN')) {
    $BearerToken = $fileSettings['BHE_BEARER_TOKEN']
}
if ($null -eq $BaseUrl -or -not $BaseUrl.IsAbsoluteUri -or
    ($BaseUrl.Scheme -ne 'https' -and -not ($BaseUrl.Scheme -eq 'http' -and $BaseUrl.IsLoopback)) -or
    $BaseUrl.AbsolutePath -ne '/' -or
    $BaseUrl.Query -or $BaseUrl.Fragment -or $BaseUrl.UserInfo) {
    throw 'BaseUrl must be a tenant origin using HTTPS, or HTTP on loopback (localhost, 127.0.0.1, or [::1]), with no path, query, fragment, or credentials.'
}
$interactive = -not $PSBoundParameters.ContainsKey('OwnerUserId')
if (-not $interactive -and $OwnerUserId -eq [guid]::Empty) { throw 'OwnerUserId cannot be the empty UUID.' }
if ($interactive -and $Delete) { throw 'Omit -Delete in interactive mode; choose deletion from the menu.' }
$hasBearer = -not [string]::IsNullOrWhiteSpace($BearerToken)
$hasId = -not [string]::IsNullOrWhiteSpace($TokenId)
$hasKey = -not [string]::IsNullOrWhiteSpace($TokenKey)
if (($hasBearer -and ($hasId -or $hasKey)) -or
    (-not $hasBearer -and (-not $hasId -or -not $hasKey))) {
    throw 'Supply either TokenId plus TokenKey, or BearerToken, exclusively.'
}
if ($Delete -and -not $WhatIfPreference -and [string]::IsNullOrWhiteSpace($BackupPath)) {
    throw '-Delete requires -BackupPath. An existing file will never be overwritten.'
}

function Get-Hmac {
    param([byte[]]$Key, [AllowEmptyCollection()][byte[]]$Data)
    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $Key)
    try { return ,$hmac.ComputeHash($Data) } finally { $hmac.Dispose() }
}

function Invoke-BHERequest {
    param([ValidateSet('GET','DELETE')][string]$Method, [string]$ApiPath)
    $headers = @{ Accept = 'application/json' }
    if ($hasBearer) { $headers.Authorization = "Bearer $BearerToken" }
    else {
        $utf8 = [Text.Encoding]::UTF8
        $date = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $operation = Get-Hmac $utf8.GetBytes($TokenKey) $utf8.GetBytes($Method + $ApiPath)
        $hour = Get-Hmac $operation $utf8.GetBytes($date.Substring(0,13))
        $signature = Get-Hmac $hour ([byte[]]@())
        $headers.Authorization = "bhesignature $TokenId"
        $headers.RequestDate = $date
        $headers.Signature = [Convert]::ToBase64String($signature)
    }
    # No redirects or automatic DELETE retries; network failures can have uncertain outcomes.
    $response = Invoke-WebRequest -UseBasicParsing -Method $Method -Uri ($BaseUrl.AbsoluteUri.TrimEnd('/') + $ApiPath) -Headers $headers -TimeoutSec $TimeoutSeconds -MaximumRedirection 0
    if ($Method -eq 'DELETE') {
        if ([int]$response.StatusCode -ne 204) { throw "Unexpected DELETE status: $($response.StatusCode)" }
        return
    }
    return ($response.Content | ConvertFrom-Json)
}

function Get-PublicQueries {
    $queries = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $skip = 0
    $total = $null
    do {
        # Some server versions rewrite user_id to user_sq.id in SQL filters.
        # Fetch only public queries, then apply the exact owner filter locally.
        $page = Invoke-BHERequest GET "/api/v2/saved-queries?scope=public&sort_by=id&skip=$skip&limit=$PageSize"
        if ($null -eq $page -or $null -eq $page.PSObject.Properties['count'] -or
            $null -eq $page.PSObject.Properties['data'] -or $null -eq $page.data -or
            [string]$page.count -notmatch '^\d+$') { throw 'Unexpected saved-query response; stopping.' }
        if ($null -eq $total) { $total = [long]$page.count }
        if ([long]$page.count -ne $total) { throw 'Query count changed during pagination. Run preview again.' }
        if ($total -gt $MaxQueries) { throw "Found $total public queries to scan, exceeding MaxQueries=$MaxQueries. No queries deleted." }
        $items = @($page.data)
        if ($items.Count -eq 0 -and $skip -lt $total) { throw 'Incomplete pagination; stopping.' }
        foreach ($query in $items) {
            if ([string]$query.id -notmatch '^[1-9]\d*$') { throw 'Unexpected query ID; stopping.' }
            if ($seen.ContainsKey([string]$query.id)) { throw 'Duplicate query ID during pagination; stopping.' }
            $seen[[string]$query.id] = $true
            if ([string]$query.user_id -ieq $OwnerUserId.ToString()) { $queries.Add($query) }
        }
        $skip += $items.Count
        if ($skip -gt $total -or $skip -gt $MaxQueries) { throw 'Pagination exceeded expected bounds; stopping.' }
    } while ($skip -lt $total)
    return ,$queries.ToArray()
}

function Get-UserText {
    param($User, [string]$Field)
    $property = $User.PSObject.Properties[$Field]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    $value = $property.Value
    if ($value -is [string]) { return $value }
    # BloodHound nullable strings are returned as {string, valid}.
    if ($null -ne $value.PSObject.Properties['valid'] -and $value.valid -eq $true -and
        $null -ne $value.PSObject.Properties['string']) { return [string]$value.string }
    return ''
}

function Read-MenuNumber {
    param([string]$Prompt, [int]$Maximum)
    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ($answer -ieq 'Q' -or $answer -eq '') { return 0 }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Maximum) {
            return $number
        }
        Write-Host "Enter a number from 1 to $Maximum, or Q to cancel."
    }
}

function Select-BHEUser {
    $response = Invoke-BHERequest GET '/api/v2/bloodhound-users'
    if ($null -eq $response.data -or $null -eq $response.data.PSObject.Properties['users'] -or
        $null -eq $response.data.users) { throw 'Unexpected users response; expected data.users.' }
    $users = @($response.data.users | Sort-Object principal_name, id)
    if ($users.Count -eq 0) { Write-Host 'No BloodHound users were returned.'; return $null }
    $seen = @{}
    for ($index = 0; $index -lt $users.Count; $index++) {
        $user = $users[$index]
        $uuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$user.id, [ref]$uuid) -or $uuid -eq [guid]::Empty -or
            $seen.ContainsKey($uuid.ToString())) { throw 'Invalid or duplicate user UUID; stopping.' }
        $seen[$uuid.ToString()] = $true
        $email = Get-UserText $user 'email_address'
        $name = ((Get-UserText $user 'first_name') + ' ' + (Get-UserText $user 'last_name')).Trim()
        Write-Host ("{0}. {1} | {2} | {3} | UUID: {4}" -f ($index+1), $user.principal_name, $name, $email, $uuid)
    }
    $choice = Read-MenuNumber 'Select a user number (Q or Enter to cancel)' $users.Count
    if ($choice -eq 0) { return $null }
    return $users[$choice-1]
}

function Get-QueryPermissions {
    param([string]$Id)
    $permissions = Invoke-BHERequest GET "/api/v2/saved-queries/$Id/permissions"
    if ($null -eq $permissions.data -or [string]$permissions.data.query_id -ne $Id -or
        $permissions.data.public -isnot [bool]) { throw 'Unexpected query permissions response.' }
    return $permissions.data
}

function Write-NewJson {
    param([string]$Path, $Value)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $json = ConvertTo-Json -InputObject $Value -Depth 50
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    return $fullPath
}

if ($interactive) {
    $selectedUser = Select-BHEUser
    if ($null -eq $selectedUser) { Write-Host 'Cancelled.'; return }
    $OwnerUserId = [guid]$selectedUser.id
    Write-Host ("Selected: {0} | UUID: {1}" -f $selectedUser.principal_name, $OwnerUserId)
}
$queries = Get-PublicQueries
Write-Host ("Matched {0} public saved queries for owner {1}." -f $queries.Count, $OwnerUserId)
if ($interactive) {
    if ($queries.Count -eq 0) { return }
    for ($index = 0; $index -lt $queries.Count; $index++) {
        $query = $queries[$index]
        Write-Host ("{0}. {1} | Query ID: {2}" -f ($index+1), $query.name, $query.id)
        Write-Host ("   Description: {0}" -f $query.description)
        Write-Host $query.query
        Write-Host ''
    }
    while ($true) {
        $action = (Read-Host 'Delete [S]elected query, [A]ll matching queries, or [Q]uit (default Q)').Trim()
        if ($action -eq '' -or $action -ieq 'Q') { Write-Host 'No queries deleted.'; return }
        if ($action -ieq 'S') {
            $choice = Read-MenuNumber 'Select a query number (Q or Enter to cancel)' $queries.Count
            if ($choice -eq 0) { Write-Host 'No queries deleted.'; return }
            $queries = @($queries[$choice-1])
            break
        }
        if ($action -ieq 'A') { break }
        Write-Host 'Enter S, A, or Q.'
    }
    $Delete = $true
    if (-not $WhatIfPreference) {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $timestamp = [datetime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            $defaultBackupPath = '.\queries-backup-{0}-{1}.json' -f $OwnerUserId, $timestamp
            Write-Host 'Before deleting, the script saves the selected queries and their sharing details to a JSON backup.'
            Write-Host ("Press Enter to use this timestamped file in your current folder: {0}" -f $defaultBackupPath)
            Write-Host 'Or enter a different path. The folder must already exist, and the file must not already exist.'
            $answer = Read-Host 'Backup JSON file path (Enter = default, Q = quit without deleting)'
            if ($answer.Trim() -ieq 'Q') { Write-Host 'No queries deleted.'; return }
            $BackupPath = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultBackupPath } else { $answer }
        }
        Write-Host ("Backup file: {0}" -f $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupPath))
        Write-Host ("Selected {0} queries for deletion. Owner UUID: {1}" -f $queries.Count, $OwnerUserId)
        $approval = Read-Host 'Type DELETE to confirm this selection (anything else cancels)'
        if ($approval -cne 'DELETE') { Write-Host 'No queries deleted.'; return }
        # One explicit confirmation covers the selection; an explicit -Confirm still adds per-query prompts.
        if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
    }
}
if (-not $Delete -or $WhatIfPreference) {
    foreach ($query in $queries) {
        if ($Delete) { [void]$PSCmdlet.ShouldProcess("$($query.id): $($query.name)", 'Delete public saved query') }
        [pscustomobject]@{ Id=$query.id; Name=$query.name; OwnerUserId=$query.user_id; Status='Preview' }
    }
    return
}
if ($queries.Count -eq 0) { return }

# Fetch sharing metadata for the entire backup before issuing any DELETE request.
$backupRecords = foreach ($query in $queries) {
    $permissions = Get-QueryPermissions ([string]$query.id)
    if (-not $permissions.public) { throw 'Public sharing changed before backup. Run preview again.' }
    [pscustomobject]@{ saved_query=$query; permissions=$permissions }
}
$backup = [ordered]@{
    schema_version=1; tenant=$BaseUrl.AbsoluteUri.TrimEnd('/'); owner_user_id=$OwnerUserId.ToString()
    exported_at=[datetime]::UtcNow.ToString('o'); queries=@($backupRecords)
}
$savedPath = Write-NewJson $BackupPath $backup
Write-Host "Backup saved: $savedPath"
$backupStem = [IO.Path]::GetFileNameWithoutExtension($savedPath)
if ($backupStem.StartsWith('queries-backup-', [StringComparison]::OrdinalIgnoreCase)) {
    $backupStem = $backupStem.Substring('queries-backup-'.Length)
}
$resultsPath = Join-Path ([IO.Path]::GetDirectoryName($savedPath)) ("queries-deletion-results-{0}.jsonl" -f $backupStem)
# Reserve the results file before deletion; it is flushed after every attempt.
$resultStream = [IO.File]::Open($resultsPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = New-Object IO.StreamWriter($resultStream, (New-Object Text.UTF8Encoding($false)))
$writer.AutoFlush = $true
$failed = 0
try {
    foreach ($query in $queries) {
        $result = [ordered]@{ Id=$query.id; Name=$query.name; OwnerUserId=$query.user_id; Status='Declined'; Detail='' }
        if ($PSCmdlet.ShouldProcess("$($query.id): $($query.name)", 'Delete public saved query')) {
            $deleteStarted = $false
            try {
                $current = (Invoke-BHERequest GET "/api/v2/saved-queries/$($query.id)").data
                if ([string]$current.id -ne [string]$query.id -or [string]$current.user_id -ine $OwnerUserId.ToString()) {
                    throw 'Query ID or ownership changed.'
                }
                foreach ($field in @('name','query','description','updated_at')) {
                    if ([string]$current.$field -cne [string]$query.$field) { throw "Query $field changed since backup." }
                }
                $permissions = Get-QueryPermissions ([string]$query.id)
                if (-not $permissions.public) { throw 'Query is no longer public.' }
                $deleteStarted = $true
                Invoke-BHERequest DELETE "/api/v2/saved-queries/$($query.id)"
                $result.Status = 'Deleted'
            } catch {
                $failed++
                $result.Status = if ($deleteStarted) { 'DeleteUnconfirmed' } else { 'Skipped' }
                $result.Detail = $_.Exception.Message
                # Record the failure before continuing; no retries of destructive requests.
            }
        }
        $writer.WriteLine((ConvertTo-Json -InputObject $result -Compress))
        [pscustomobject]$result
    }
} finally { $writer.Dispose(); $resultStream.Dispose() }
Write-Host "Results saved: $resultsPath"
if ($failed) { throw "$failed queries were skipped or their deletion could not be confirmed. Review $resultsPath." }
