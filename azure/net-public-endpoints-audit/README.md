# Network Public Endpoints Audit

Script: [net-public-endpoints-audit.sh](net-public-endpoints-audit.sh)

Finds likely internet-facing assets and exposure conditions.

## What It Checks

- Public IP addresses
- App Service public access and access restriction posture
- Storage account public network and blob public access posture

## Requirements

- Bash
- `az` CLI authenticated with read access to networking and resource config
- `jq`

## Usage

```bash
./net-public-endpoints-audit.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --format both \
  --output-dir ./out
```

Optional flags:

- `--skip-app-services`
- `--skip-storage`
- `--fail-on-high`
- `--verbose`

## Output

- Markdown report (default)
- Optional JSON report
- Severity counts + aggregate risk score (0-100)

## Notes

- This script is read-only.
- Findings are triage-focused and should be validated against intended architecture.
