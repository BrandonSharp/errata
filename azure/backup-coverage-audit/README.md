# Backup Coverage Audit

Script: [backup-coverage-audit.sh](backup-coverage-audit.sh)

Assesses VM backup coverage by correlating discovered VMs with Recovery Services protected items.

## What It Checks

- Enumerates VMs in each subscription
- Enumerates Recovery Services vault backup items (`AzureIaasVM`)
- Flags VMs with no detected backup item
- Captures health state for discovered protected items

## Requirements

- Bash
- `az` CLI authenticated with read access to VMs, Recovery Services vaults, and backup items
- `jq`

## Usage

```bash
./backup-coverage-audit.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --format both \
  --output-dir ./out
```

Optional flags:

- `--fail-on-high`
- `--verbose`

## Output

- Markdown report (default)
- Optional JSON report
- Severity counts + aggregate risk score (0-100)

## Notes

- This script is read-only.
- Current baseline focuses on VM backup coverage; extend later for SQL/SAP/Azure Files coverage parity.
