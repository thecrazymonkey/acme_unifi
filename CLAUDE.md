# CLAUDE.md

## What This Is

Shell automation for SSL certificate renewal on a **UniFi UCG Max** gateway. Uses [acme.sh](https://github.com/acmesh-official/acme.sh) for the ACME protocol (Let's Encrypt) and AWS Route53 for DNS-01 challenge. Scripts run on the gateway itself under a minimal BusyBox environment.

## GitHub Operations

Always use the `gh` CLI for all GitHub interactions — never construct GitHub URLs manually:

```sh
gh pr create            # open a pull request
gh pr list              # list open PRs
gh issue list           # list issues
gh issue create         # create an issue
gh repo view            # view repo info
gh run list             # check CI runs
```
## Key Constraints

**POSIX sh only — no bash-isms.** The UCG Max runs BusyBox sh. Forbidden constructs:
- `[[ ]]` — use `[ ]`
- Arrays (`arr=(...)`) — not available
- `local` variables — not available in all BusyBox versions; avoid if possible
- `echo -e` — use `printf` instead
- GNU-specific flags on `find`, `stat`, `date` — must support both GNU and BSD forms

`date` epoch conversion must handle both Linux (`date -d`) and BSD/macOS (`date -j -f`). See existing `check_cert_expiry()` for the pattern.


Lint shell scripts with `shellcheck` (installed locally, not on the gateway):
```sh
shellcheck acme-unifi.sh install.sh on-boot-cron.sh
```

