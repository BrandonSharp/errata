# Diagnostic Settings Coverage Audit

Script: [monitor-diagnostic-settings-coverage.sh](monitor-diagnostic-settings-coverage.sh)

Checks whether selected resource types have diagnostic settings configured with valid destinations.

## What It Checks

Default resource types:

- `Microsoft.KeyVault/vaults`
- `Microsoft.Storage/storageAccounts`
- `Microsoft.Web/sites`
- `Microsoft.Sql/servers`
- `Microsoft.Network/networkSecurityGroups`

Per resource, the script checks:

- Diagnostic settings existence
- Presence of at least one valid destination (Log Analytics, Event Hub, or Storage)

## Requirements

- Bash
- `az` CLI authenticated with read access to resources and monitor diagnostics
- `jq`

## Usage

```bash
./monitor-diagnostic-settings-coverage.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --format both \
  --output-dir ./out
```

Optional flags:

- `--resource-types "Microsoft.KeyVault/vaults,Microsoft.Storage/storageAccounts"`
- `--fail-on-high`
- `--verbose`

## Output

- Markdown report (default)
- Optional JSON report
- Severity counts + aggregate risk score (0-100)

## Notes

- This script is read-only.
- It focuses on coverage, not log category completeness; validate categories separately for detection engineering.
