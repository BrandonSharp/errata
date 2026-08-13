# Azure Scripts

Collection of Azure-focused utility scripts for inventory, operations, and environment triage.

## Initial Evaluation Script Kit

These scripts are designed for early-stage customer environment assessments.
All are read-only and accept explicit subscription targets.

1. IAM RBAC high-privilege audit:
- Folder: [iam-rbac-owner-contributor-audit](iam-rbac-owner-contributor-audit)
- Script: [iam-rbac-owner-contributor-audit.sh](iam-rbac-owner-contributor-audit/iam-rbac-owner-contributor-audit.sh)

2. Network public exposure audit:
- Folder: [net-public-endpoints-audit](net-public-endpoints-audit)
- Script: [net-public-endpoints-audit.sh](net-public-endpoints-audit/net-public-endpoints-audit.sh)

3. Key Vault hardening audit:
- Folder: [data-keyvault-hardening-audit](data-keyvault-hardening-audit)
- Script: [data-keyvault-hardening-audit.sh](data-keyvault-hardening-audit/data-keyvault-hardening-audit.sh)

4. Monitoring diagnostics coverage audit:
- Folder: [monitor-diagnostic-settings-coverage](monitor-diagnostic-settings-coverage)
- Script: [monitor-diagnostic-settings-coverage.sh](monitor-diagnostic-settings-coverage/monitor-diagnostic-settings-coverage.sh)

5. Backup coverage audit (VM baseline):
- Folder: [backup-coverage-audit](backup-coverage-audit)
- Script: [backup-coverage-audit.sh](backup-coverage-audit/backup-coverage-audit.sh)

6. Firewall policy review:
- Folder: [firewall-policy-review](firewall-policy-review)
- Script: [firewall-policy-review.sh](firewall-policy-review/firewall-policy-review.sh)

## Shared Helper

- Folder: [_lib](_lib)
- Shared audit utilities: [audit_common.sh](_lib/audit_common.sh)

## Common Dependencies

- Bash
- Azure CLI (`az`) with sufficient read permissions
- `jq`

## Quick Start

Example execution pattern:

```bash
./azure/iam-rbac-owner-contributor-audit/iam-rbac-owner-contributor-audit.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --format both \
  --output-dir ./reports
```

Each script supports:

- `--subscriptions <csv>`
- `--output-dir <path>`
- `--format <markdown|json|both>`
- `--fail-on-high`
- `--verbose`
