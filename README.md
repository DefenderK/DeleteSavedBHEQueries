# Remove public BloodHound Enterprise saved queries by owner

`Remove-BHEPublicQueries.ps1` interactively lists BloodHound users, previews one user's **public saved queries**, and lets you delete one query or all matching queries. Supplying `-OwnerUserId` retains the command-line preview/delete mode. 
Requires Windows PowerShell 5.1 or PowerShell 7, a tenant URL, and an administrator API token (ID and key). 
An existing bearer JWT is also supported. 
Tenant URLs require HTTPS; HTTP is allowed for local loopback addresses such as `localhost`, `127.0.0.1`, and `[::1]`.

Interactive mode obtains users from `GET /api/v2/bloodhound-users` and captures the selected user's **BloodHound application UUID** automatically. It displays every returned user, including disabled accounts, sorted by principal name and UUID. Each numbered entry includes principal name, display name, email, and UUID. UUIDs identify application accounts, not Active Directory/Entra objects.

## Setup and interactive selection

### Option 1: Env file

Copy [`.env.example`](.env.example) to `.env` and replace the URL, token ID, and token key:

```dotenv
BHE_URL=https://your-tenant.bloodhoundenterprise.io
BHE_TOKEN_ID=your-administrator-token-id
BHE_TOKEN_KEY=your-administrator-token-key
BHE_BEARER_TOKEN=
```

Run the interactive tool using that file:

```powershell
.\Remove-BHEPublicQueries.ps1 -EnvFile .\.env
```

For a local instance, this quoted URL with a trailing slash is also supported:

```dotenv
BHE_URL='http://127.0.0.1:8080/'
```

The same loopback HTTP support applies to `-BaseUrl` and the `BHE_URL` process environment variable. Paths beyond `/`, query strings, fragments, and credentials embedded in the URL remain rejected.

You can also use the file with the existing UUID-based mode:

```powershell
.\Remove-BHEPublicQueries.ps1 -EnvFile .\.env -OwnerUserId '11111111-1111-1111-1111-111111111111'
```

Values resolve per setting in this order: **explicit command-line parameter**, then **env file**, then **process environment**. An empty file value overrides the environment too; keep `BHE_BEARER_TOKEN=` when using token ID/key to clear any inherited bearer JWT. `BHE_URL` is also supported directly as a process environment variable. Env files load only when you specify `-EnvFile`; they are never discovered automatically and do not change your session environment.

The file supports `NAME=value`, blank lines, full-line `#` comments, and optional matching single/double quotes. Values are literal: `$variables`, commands, and escape sequences are not evaluated. Split is at the first `=`, so values may contain additional equals signs. Inline comments and `export` syntax are not supported. Only the four keys above are accepted; malformed entries and duplicate keys stop the run before any HTTP request. Error messages do not print setting values.

`.env` and `.env.*` files are ignored by Git except `.env.example`. The env file stores the token key in plaintext, so keep it private and outside shared folders.

### Option 2: Process environment

Generate an API token for your administrator account in BloodHound's user management UI. Set these environment variables in your current PowerShell session. The key prompt hides input and avoids placing the secret in shell history:

```powershell
$env:BHE_TOKEN_ID = Read-Host 'Administrator API token ID'
$secret = Read-Host 'Administrator API token key' -AsSecureString
$env:BHE_TOKEN_KEY = (New-Object System.Net.NetworkCredential('', $secret)).Password

.\Remove-BHEPublicQueries.ps1 -BaseUrl 'https://your-tenant.bloodhoundenterprise.io'
```

The script then:

1. Lists the users and asks you to select a user number.
2. Captures and displays the selected UUID for this run.
3. Previews every matching public query with its name, ID, description, and full Cypher text.
4. Asks whether to delete a **selected query (S)**, **all matching queries (A)**, or **quit (Q)**.
5. For S, asks for the query number from the preview.
6. Offers a timestamped backup JSON filename in the current folder, unless you supplied `-BackupPath`. Press Enter to accept it, enter a different path, or enter Q to quit without deleting.
7. Requires typing `DELETE` to confirm, then saves the backup and processes the chosen queries.

Enter or Q at either numbered selection, or at the action menu, cancels. At the **backup path prompt**, Enter accepts the default and Q cancels. The default filename is `queries-backup-<owner-UUID>-<UTC timestamp>.json`, for example `queries-backup-11111111-1111-1111-1111-111111111111-20261008-160000-123Z.json`. 
The script displays the resolved backup path before final confirmation and never overwrites existing files. Invalid selections prompt again. No matches ends the run without a deletion prompt. The selected UUID is retained in memory for the run and written as `owner_user_id` in the backup when deleting; no separate user-selection file is created. The backup covers only the selected query when deleting one query.

Interactive mode uses one typed confirmation for the selection; `-Confirm` optionally adds individual PowerShell confirmation prompts. Omitting `-OwnerUserId` selects interactive mode; omit `-Delete` in that mode. For an interactive simulation, use:

```powershell
.\Remove-BHEPublicQueries.ps1 -BaseUrl 'https://your-tenant.bloodhoundenterprise.io' -WhatIf
```

The simulation still asks for user and query selections, but does not ask for a backup path or typed confirmation, write files, or send DELETE requests.

## Command-line preview by UUID

```powershell
$options = @{
    BaseUrl     = 'https://your-tenant.bloodhoundenterprise.io'
    OwnerUserId = '11111111-1111-1111-1111-111111111111'
}

.\Remove-BHEPublicQueries.ps1 @options | Format-Table -AutoSize
```

With `-OwnerUserId`, the default only sends GET requests and never prompts to delete. It lists every match without truncating the result objects. In both modes, the API is queried with `scope=public`, and the selected owner UUID is matched exactly locally. This avoids a server SQL filter issue affecting `user_id` in some versions. Pagination completes before deletion, with a default maximum of 10,000 public queries scanned across all owners. An incomplete page, duplicate ID, changed count, or unexpected query ID stops the run. Queries belonging to other users are excluded from preview, backup, and deletion. Use `-MaxQueries` to explicitly raise the limit.

## Delete and verify

```powershell
# Simulate deletion without writing backups or issuing DELETE requests.
.\Remove-BHEPublicQueries.ps1 @options -Delete -WhatIf

# Choose a NEW backup filename in an existing directory.
# The script prompts for each deletion after saving the backup.
.\Remove-BHEPublicQueries.ps1 @options -Delete -BackupPath '.\queries-backup.json'

# After reviewing the preview, -Confirm:$false can suppress individual prompts:
# .\Remove-BHEPublicQueries.ps1 @options -Delete -BackupPath '.\queries-backup-2.json' -Confirm:$false

# Verify by running the preview again.
.\Remove-BHEPublicQueries.ps1 @options | Format-Table -AutoSize
```

The backup contains the complete listed records (including Cypher text, names, descriptions, and owner IDs), sharing metadata, tenant, and export time. The script never overwrites a backup or result file. If backup or result-file creation fails, no deletion starts. A separate `queries-deletion-results-<owner-UUID>-<UTC timestamp>.jsonl` file in the same folder is flushed after every query and records `Deleted`, `Declined`, `Skipped`, or `DeleteUnconfirmed`. The last status means a DELETE was attempted without confirmed success; check the tenant before retrying. Any skipped or unconfirmed deletion causes a terminating error after processing the batch. For a custom backup filename, the results file uses `queries-deletion-results-<backup filename without extension>.jsonl`, with any leading `queries-backup-` removed. For example, `admin.json` creates `queries-deletion-results-admin.jsonl`.

Immediately before each deletion, the script rechecks ID, owner, name, query text, description, modification time, and public sharing. Changed queries are skipped. These checks and the DELETE are separate requests, so concurrent changes cannot be ruled out entirely; run during a period when the target queries are not being edited.

The backup is an evidence/backup envelope, **not** a directly importable BloodHound query file. To restore content using the import API, extract each record's `name`, `query`, and `description` to individual JSON files. Importing creates new queries owned by the importing user; IDs and sharing are not automatically restored. No automatic restore is included.

Private queries and queries shared only with particular users are outside this script's scope. No tenant requests or deletions were made during development; validation uses mocked HTTP responses.

## API endpoints and request flow

All paths below are appended to the configured `BHE_URL` / `BaseUrl`. Every request uses the same authenticated account. Selecting a user records their UUID for filtering; it does not impersonate that user.

| Method | Endpoint | How the tool uses it |
| --- | --- | --- |
| GET | `/api/v2/bloodhound-users` | Interactive mode: reads `data.users` and displays a numbered list of application users. Skipped when `-OwnerUserId` is supplied. |
| GET | `/api/v2/saved-queries?scope=public&sort_by=id&skip=<offset>&limit=<page-size>` | Fetches public saved queries in pages. Reads the `data` array and `count`, then locally matches each query's `user_id` to the selected UUID. |
| GET | `/api/v2/saved-queries/<query-ID>/permissions` | Fetches `data.public` and sharing metadata for the backup, then checks public sharing again immediately before each deletion. |
| GET | `/api/v2/saved-queries/<query-ID>` | Immediately before deletion, reads `data` to recheck the ID, owner, name, query text, description, and modification time against the backed-up record. |
| DELETE | `/api/v2/saved-queries/<query-ID>` | Deletes one selected query after all checks pass. HTTP `204 No Content` is required to record a confirmed deletion. |

### Interactive flow

1. **Load configuration and authentication.** Read parameters, the optional env file, and environment variables. This is local work; the script does not call a login or token-generation endpoint.
2. **List users.** Call `GET /api/v2/bloodhound-users`. The operator selects a displayed user; the script retains that account's UUID.
3. **Fetch public queries.** Call the paginated saved-query list endpoint, starting with `skip=0` and advancing by the number of records returned. The default `limit` is 100. Collect only exact owner UUID matches. Fetching completes before any deletion begins. The script deliberately omits the server-side `user_id` filter to avoid the server compatibility issue described above.
4. **Preview and select.** Display the matching queries locally. The operator chooses one query, all matching queries, or quit. There are no API calls for these menu choices. “All” means the matching public queries from this preview, not all users' queries or queries created later.
5. **Choose the backup path and confirm.** Enter accepts the timestamped default path; Q cancels. Typing `DELETE` confirms the selection. `-WhatIf` ends with simulated actions instead of backup or deletion.
6. **Gather backup metadata.** For every selected query, call `GET /api/v2/saved-queries/<query-ID>/permissions`. Require public sharing and collect sharing metadata. If any request/check fails, stop before deleting anything.
7. **Save local files.** Write the selected records and their permissions to the JSON backup, then create the separate deletion results log. The query text comes from the list response; the script does not use the query export endpoint. Failure to create either file prevents deletion.
8. **Recheck and delete each query.** After any PowerShell confirmation prompt is accepted, call `GET /api/v2/saved-queries/<query-ID>`, then `GET /api/v2/saved-queries/<query-ID>/permissions`. Require unchanged content, the selected owner UUID, and public sharing. Only then call `DELETE /api/v2/saved-queries/<query-ID>`. A failed recheck skips that query. A deletion without a confirmed 204 response is recorded as `DeleteUnconfirmed`; destructive requests are not automatically retried.
9. **Record results.** Flush one local JSONL result per selected query and display its outcome. Verification is a separate preview run, which calls the list endpoint again; the script does not automatically perform a final verification request.

The GET checks and DELETE are separate requests, so the sequence is not an atomic transaction. Private queries are outside the tool's scope, even where an individual GET endpoint might permit an administrator to read a known private query ID.

### Command-line mode

With `-OwnerUserId`, the script skips user listing and selection and starts at the public-query list endpoint. Without `-Delete`, it returns preview objects and stops. With `-Delete`, it targets all matching queries and requires `-BackupPath`, then follows the same backup, recheck, deletion, and result-logging sequence. `-Delete -WhatIf` makes only the paginated query-list requests and writes no files.

## Authentication and API references

API token requests use the documented chained HMAC-SHA256 `bhesignature` authentication. Alternatively, clear `BHE_TOKEN_ID` and `BHE_TOKEN_KEY`, then set `BHE_BEARER_TOKEN` to an existing session JWT. API token keys are not bearer tokens. Credentials are never written to backups/results; avoid storing them in the script. HTTPS certificates remain validated, redirects are disabled, requests have a 30-second timeout, and DELETE requests are not automatically retried.

- [Signed API authentication](https://bloodhound.specterops.io/reference/overview)
- [List application users](https://bloodhound.specterops.io/reference/bloodhound-users/list-users)
- [List saved queries](https://bloodhound.specterops.io/reference/cypher/list-saved-queries)
- [Read a saved query](https://bloodhound.specterops.io/reference/cypher/return-a-saved-query)
- [Delete a saved query](https://bloodhound.specterops.io/reference/cypher/delete-a-saved-query)
- [Saved query permissions](https://bloodhound.specterops.io/reference/cypher/retrieves-saved-query-permissions-for-provided-query-id)
- [Public implementation permission checks](https://github.com/SpecterOps/BloodHound/blob/main/cmd/api/src/api/v2/saved_queries.go)

## Example interactive output

This anonymized example shows selecting a user, previewing their public queries, choosing one query to delete, accepting the default backup filename by pressing Enter, and confirming with `DELETE`. Names, email addresses, UUIDs, query IDs, computer names, SIDs, timestamps, and local paths are illustrative. Only the first five of 184 matching queries are shown here; the actual script displays every match.

```text
.\Remove-BHEPublicQueries.ps1 -EnvFile .\.env
1. admin | Example Admin | admin@example.com | UUID: 11111111-1111-1111-1111-111111111111
2. audit_api | Audit Service | audit@example.com | UUID: 22222222-2222-2222-2222-222222222222
3. demo_user | Demo User | demo@example.com | UUID: 33333333-3333-3333-3333-333333333333
4. analyst | Example Analyst | analyst@example.com | UUID: 44444444-4444-4444-4444-444444444444
5. monitoring_api | Monitoring Service | monitoring@example.com | UUID: 55555555-5555-5555-5555-555555555555
6. test_user | Test User | test@example.com | UUID: 66666666-6666-6666-6666-666666666666
Select a user number (Q or Enter to cancel): 1
Selected: admin | UUID: 11111111-1111-1111-1111-111111111111
Matched 184 public saved queries for owner 11111111-1111-1111-1111-111111111111.
1. Local Groups on Machine | Query ID: 501
   Description:
MATCH p=(c:Computer {name:'WORKSTATION01.EXAMPLE.LOCAL'})<-[:LocalToComputer]-
(n:ADLocalGroup)-[:MemberOfLocalGroup]-(u:Base)
RETURN p
LIMIT 500

2. Local Group expanded | Query ID: 502
   Description:
MATCH p=(c:Computer {name:'WORKSTATION01.EXAMPLE.LOCAL'})<-[:LocalToComputer]-
(n:ADLocalGroup)<-[:MemberOfLocalGroup]-(u:Base)<-[:MemberOf*1..]-(r:Base)
RETURN p
LIMIT 500

3. Group Granting local admin on a computer | Query ID: 503
   Description:
MATCH p=(g:Group)-[:AdminTo]->(c:Computer)
WHERE c.objectid = 'S-1-5-21-1111111111-2222222222-3333333333-1103'
RETURN p
LIMIT 100

4. User has Admin via Group Membership | Query ID: 504
   Description:
MATCH p=(u:User)-[:MemberOf*1..]->(g:Group)-[:AdminTo]->(c:Computer)
WHERE u.objectid = 'S-1-5-21-1111111111-2222222222-3333333333-500'
RETURN p
LIMIT 100

5. Users with Admin on a Computer | Query ID: 505
   Description:
MATCH p=(u:User)-[:MemberOf*1..]->(g:Group)-[:AdminTo]->(c:Computer)
WHERE c.objectid = 'S-1-5-21-1234567890-2345678901-3456789012-1120'
RETURN p
LIMIT 100

[The remaining 179 query previews are omitted from this documentation example.]

Delete [S]elected query, [A]ll matching queries, or [Q]uit (default Q): S
Select a query number (Q or Enter to cancel): 5
Before deleting, the script saves the selected queries and their sharing details to a JSON backup.
Press Enter to use this timestamped file in your current folder: .\queries-backup-11111111-1111-1111-1111-111111111111-20261008-120000-123Z.json
Or enter a different path. The folder must already exist, and the file must not already exist.
Backup JSON file path (Enter = default, Q = quit without deleting):
Backup file: C:\Tools\BHEQueries\queries-backup-11111111-1111-1111-1111-111111111111-20261008-120000-123Z.json
Selected 1 queries for deletion. Owner UUID: 11111111-1111-1111-1111-111111111111
Type DELETE to confirm this selection (anything else cancels): DELETE
```

This transcript ends at confirmation. The script next saves the backup and creates the deletion results log, rechecks query 505's ownership, content, and public sharing, and attempts its deletion. It reports the outcome in the console and in `queries-deletion-results-11111111-1111-1111-1111-111111111111-20261008-120000-123Z.jsonl`.
