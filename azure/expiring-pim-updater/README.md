# Expiring PIM Updater

This script checks for expired and soon-to-expire (next 14 days) PIM eligibilities across Entra and Azure, then optionally lets you update each finding interactively.

Script: [check-expiring-pim.sh](check-expiring-pim.sh)

## What It Checks

The script inspects these scenarios:

1. Entra role assignment eligibilities
2. Entra group membership eligibilities (Privileged Access Groups)
3. Azure role assignment eligibilities

By default, it is report-only.

## Requirements

- Bash (Linux/macOS/WSL)
- `az` CLI
- `jq`
- `date` with GNU-compatible parsing (for date normalization)
- You are already signed in with `az login`

## Usage

```bash
./check-expiring-pim.sh --scope <scope-resource-id> [--check-resources] [--update [date_or_datetime]] [--graph-client-id <app-id>] [--graph-tenant-id <tenant>] [--graph-scopes "<space-separated-scopes>"]
```

### Options

- `--scope <scope-resource-id>`
- Required.
- Accepts:
- Management group: `/providers/Microsoft.Management/managementGroups/<name>`
- Subscription: `/subscriptions/<subscriptionId>`
- Resource group: `/subscriptions/<id>/resourceGroups/<name>`
- Resource: `/subscriptions/<id>/resourceGroups/<rg>/providers/<type>/<name>`
- You can also pass a bare management group name; the script normalizes it.

- `--check-resources`
- Optional.
- When the scope is a subscription or resource group, include individual resources in scope expansion.

- `--update [date_or_datetime]`
- Optional.
- Enables interactive prompts for each expired/expiring finding.
- If date is omitted, target end date defaults to `now + 364 days`.
- Date input supports:
- `YYYY-MM-DD` (normalized to `23:59:59Z`)
- Parseable datetime strings (normalized to UTC ISO 8601)

- `--graph-client-id <app-id>`
- Optional.
- Use your own Entra app registration for custom Graph delegated authentication (device code flow).

- `--graph-tenant-id <tenant>`
- Optional.
- Tenant ID or domain for custom Graph auth.
- Defaults to `organizations`.

- `--graph-scopes "<space-separated-scopes>"`
- Optional.
- Override scopes requested during custom Graph device code auth.

- `-h`, `--help`
- Show usage.

## Examples

Report-only scan for a subscription:

```bash
./check-expiring-pim.sh \
  --scope /subscriptions/00000000-0000-0000-0000-000000000000
```

Report-only scan from a management group (including child scopes):

```bash
./check-expiring-pim.sh \
  --scope /providers/Microsoft.Management/managementGroups/my-mg
```

Include resources when scanning a subscription:

```bash
./check-expiring-pim.sh \
  --scope /subscriptions/00000000-0000-0000-0000-000000000000 \
  --check-resources
```

Interactive update mode with default target date (`+364 days`):

```bash
./check-expiring-pim.sh \
  --scope /subscriptions/00000000-0000-0000-0000-000000000000 \
  --update
```

Interactive update mode with explicit target date:

```bash
./check-expiring-pim.sh \
  --scope /subscriptions/00000000-0000-0000-0000-000000000000 \
  --update 2027-06-30
```

Interactive update mode with explicit datetime:

```bash
./check-expiring-pim.sh \
  --scope /subscriptions/00000000-0000-0000-0000-000000000000 \
  --update "2027-06-30T12:00:00Z"
```

Use custom app auth (device code) for Graph calls:

```bash
./check-expiring-pim.sh \
  --scope /subscriptions/00000000-0000-0000-0000-000000000000 \
  --graph-client-id 11111111-2222-3333-4444-555555555555 \
  --graph-tenant-id 66666666-7777-8888-9999-aaaaaaaaaaaa
```

Use a pre-obtained token instead of any built-in auth:

```bash
export GRAPH_ACCESS_TOKEN="<token-with-required-graph-scopes>"
./check-expiring-pim.sh --scope /subscriptions/00000000-0000-0000-0000-000000000000
```

## Output

The script prints:

- Overall findings summary (total, expired, expiring)
- Per-scenario grouped findings
- In update mode, per-item prompt details and final update summary (updated/skipped/failed)

Statuses:

- `expired`: end date/time is in the past
- `expiring`: end date/time is within the next 14 days

## Scope Expansion Behavior

Given `--scope`, the script expands as follows:

- Management group:
- Includes the management group and recursively traverses child management groups and subscriptions.
- Subscription:
- Includes the subscription and all resource groups.
- With `--check-resources`, also includes resources.
- Resource group:
- Includes the resource group.
- With `--check-resources`, also includes resources in that resource group.
- Resource:
- Includes only that resource.

## Update Behavior

When `--update` is supplied:

- The script prompts for each finding individually.
- Only approved items are updated.
- If standard input is not a TTY, update mode exits with an error.

Update request paths used:

- Entra role eligibilities:
- `POST https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleRequests`
- Entra group eligibilities:
- `POST https://graph.microsoft.com/beta/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests`
- Azure role eligibilities:
- `PUT https://management.azure.com{scope}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{requestId}?api-version=2020-10-01-preview`

## Permissions

You need sufficient permissions in both Microsoft Graph and Azure RBAC for the scopes you query and update.

Typical requirements include:

- Read access to Entra PIM and Azure role eligibility schedules
- Permission to submit admin update requests for the same schedules
- Access to enumerate management groups, subscriptions, resource groups, and resources under `--scope`

If a scope or API path is inaccessible, the script warns and continues with other checks.

For Entra PIM role eligibility APIs, delegated Graph scope consent is required on the calling client app.
Being Global Administrator does not automatically add OAuth delegated scopes to the token.

For Entra group eligibility checks, the script enumerates groups and queries group eligibility instances per group.
This is done because the Graph API requires GroupId/PrincipalId targeting for these calls.
In large tenants, this can increase runtime.

## Troubleshooting

- `Required command not found`
- Install missing dependencies (`az`, `jq`).

- `Unable to query ... Ensure Graph permissions are available`
- The signed-in principal may not have required Microsoft Graph or tenant-level permissions.

- `PermissionScopeNotGranted`
- The token lacks Graph delegated scopes for role eligibility APIs.
- Grant/admin-consent required scopes to the calling app, or use custom auth with `--graph-client-id`.

- `Unable to query Azure role eligibilities at scope ...`
- Verify RBAC access to the scope and child scopes.

- `--update requires an interactive terminal (TTY)`
- Run in an interactive shell without redirecting stdin.

## Notes

- Default mode performs no write operations.
- The script uses preview API version for Azure role eligibility schedule operations.
- Behavior can vary by tenant policy, API availability, and granted permissions.
