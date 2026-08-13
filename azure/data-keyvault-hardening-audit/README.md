# Key Vault Hardening Audit

Script: [data-keyvault-hardening-audit.sh](data-keyvault-hardening-audit.sh)

Evaluates baseline security posture for Azure Key Vault resources.

## What It Checks

- Purge protection
- Soft delete
- Public network access
- Firewall default action
- RBAC vs access policy authorization mode
- Private endpoint connection presence

## Requirements

- Bash
- `az` CLI authenticated with read access to Key Vault metadata
- `jq`

## Usage

```bash
./data-keyvault-hardening-audit.sh \
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
- For sensitive environments, pair this with deeper RBAC assignment and secret lifecycle review.
