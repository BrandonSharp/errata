# Initial Evaluation Runner

Script: [run-initial-eval.sh](run-initial-eval.sh)

Runs the Azure initial assessment scripts in sequence and stores each script's output in one bundle directory.

## What It Runs

1. IAM RBAC high-privilege audit
2. Network public exposure audit
3. Key Vault hardening audit
4. Diagnostic settings coverage audit
5. Backup coverage audit

## Requirements

- Bash
- `date`
- The child scripts must be executable
- Azure CLI and `jq` are required by the child scripts

## Usage

```bash
./run-initial-eval.sh \
  --subscriptions "<sub-id-1>,<sub-id-2>" \
  --output-dir ./reports \
  --format both
```

Optional flags:

- `--fail-on-high`
- `--verbose`
- `--run-tag <value>`

## Output

The runner creates a timestamped bundle directory containing:

- One subdirectory per child script
- The child script reports for that script
- A bundle README with execution context

## Notes

- This is a coordinator only; it does not query Azure directly.
- Exit status is non-zero if any child script fails.
