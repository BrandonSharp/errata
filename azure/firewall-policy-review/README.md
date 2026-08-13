# Firewall Policy Review

Script: [firewall-policy-review.sh](firewall-policy-review.sh)

Reviews Azure Firewalls and their attached Firewall Policies, then builds a Markdown report per policy.

## What It Includes

For each firewall policy, the report contains three sections:

1. Application Rules
2. Network Rules
3. DNAT Rules

Each rule is shown as one table row with source, destination, and ports.
Fields that include multiple values are rendered with line breaks in each table cell.

## Requirements

- Bash
- Azure CLI (`az`) with read access to firewall and policy resources
- `jq`

## Usage

```bash
./firewall-policy-review.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --output-dir ./out
```

Optional flags:

- `--output-file <path>`

## Notes

- This script is read-only.
- It scopes policies by firewalls currently attached to them.
