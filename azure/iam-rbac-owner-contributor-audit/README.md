# IAM RBAC Owner/Access Audit

Script: [iam-rbac-owner-contributor-audit.sh](iam-rbac-owner-contributor-audit.sh)

Audits high-privilege Azure RBAC assignments at subscription and child scopes.

## What It Checks

- Role assignments matching target roles (default: `Owner`, `User Access Administrator`)
- Optional inclusion of `Contributor`
- Scope type awareness (subscription, resource group, resource, other)
- Severity assignment by role/principal/scope pattern

## Requirements

- Bash
- `az` CLI authenticated with read access to role assignments
- `jq`

## Usage

```bash
./iam-rbac-owner-contributor-audit.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --format both \
  --output-dir ./out
```

Optional flags:

- `--roles "Owner,User Access Administrator"`
- `--include-contributor`
- `--fail-on-high`
- `--verbose`

## Output

- Markdown report (default)
- Optional JSON report
- Severity counts + aggregate risk score (0-100)

## Notes

- This script is read-only.
- Use it early in initial tenant/subscription triage to identify over-privileged scopes.
