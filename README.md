# DWP Storage Forensics

**Evidence-first storage diagnostics and a separate, explicitly approved cache cleaner for macOS.**

This project targets small, heavily used APFS systems, including older Intel Macs running macOS 11.x. The diagnostic shell commands **do not delete data**. The separate Python cache cleaner can delete explicitly confirmed pip HTTP cache files; see [the cleanup guide](docs/cache-cleaner.md). We prioritize finding the *largest measured directories* before considering any proposed cleanup.

> Status: **v1.2.0 / review candidate**. Portable shell tests run on Linux, but full compatibility must still be verified on an actual macOS 11.7 machine. A successful `du` walk is not proof that APFS accounting has been fully reconciled.

## First run

Run from the repository root. Bash is invoked explicitly to avoid executable permission problems:

```bash
bash bin/dwp-checkpoint.sh --quick
bash bin/dwp-checkpoint.sh --triage
```

The first command reads disk and RAM/swap metrics. The second scans selected local app/developer trees, making additional filesystem metadata reads. **Even `--depth 1` must traverse descendants to calculate directory totals.** If the computer is unstable, stop the scan with `Ctrl+C` and inspect a single suspected path instead:

```bash
bash bin/dwp-hotspots.sh --path "$HOME/Library/Application Support" --depth 1 --limit 20
bash bin/dwp-hotspots.sh --path "$HOME/Library/Containers" --depth 1 --limit 20
```

On macOS, `du -a` and `du -d` are mutually exclusive. The scanner deliberately makes one directory walk plus a shallow direct-file pass, and streams the top-N ranking without disk-backed sort files. The reported root total includes all deeper files.

The diagnostic shell tools never need `sudo`, network access, Homebrew, Python, a database, Docker daemon access, or any cloud tokens. Do not paste raw path listings or device identifiers into public issues.

## Commands

| Command | Purpose |
| --- | --- |
| `bash bin/dwp-checkpoint.sh --quick` | Compact, color-aware summary of current free space, disk percentage and swap usage |
| `bash bin/dwp-checkpoint.sh --triage` | Summary plus selected app/developer disk hotpots; not a complete APFS inventory |
| `bash bin/dwp-checkpoint.sh --details` | APFS container accounting and snapshot names |
| `bash bin/dwp-checkpoint.sh --raw` | Unfiltered local diagnostic details; may contain sensitive file paths |
| `bash bin/dwp-checkpoint.sh --check` | Stable machine-readable output with exit 0/10/20/30 |
| `bash bin/dwp-hotspots.sh --library` | Full user Library scan (potentially expensive) |
| `bash bin/dwp-hotspots.sh --home` | Full user Home scan (potentially expensive) |
| `bash bin/dwp-hotspots.sh --data` | Entire APFS Data filesystem (very expensive; permissions can limit output) |
| `bash bin/dwp-hotspots.sh --path "..."` | Drill down into one chosen directory |
| `bash bin/dwp-hotspots.sh --depth 2 --limit 20 --path "..."` | More reported levels; still a full traversal under the root |

`--color auto` is the default. `--color always` and `--color never` override it. When `NO_COLOR` is present, auto mode uses plain text. `TERM=dumb` and non-TTY stdout also disable automatic ANSI styling.

A `15 GiB` target is an **operational heuristic, not an Apple requirement**. The threshold status is based on free-space headroom, not proof of a particular problem. Machine mode outputs only `DWP_STATE`, `DWP_FREE_KB`, and `DWP_USED_PERCENT`; `--check` returns 30 for critical (under 1 GiB), 20 for danger (1–3 GiB), 10 for warning (3–15 GiB), or 0 for stable.

## Targeted verification: MobileSync and Docker

Two paths can be disproportionately large on developer laptops. **Their size is not synonymous with reclaimability.** Inspect them without deletion:

```bash
# Local device backup directory, potentially the only restorable copy.
bash bin/dwp-hotspots.sh --path "$HOME/Library/Application Support/MobileSync" --depth 1

# Docker Desktop's application container; includes disk images and state.
bash bin/dwp-hotspots.sh --path "$HOME/Library/Containers/com.docker.docker" --depth 2

# Only if the Docker daemon is already running; do not start it on a full disk.
docker system df -v
```

For Apple device backups, prefer Finder's **Manage Backups** interface to identify devices and dates. Do not remove or offload the source until a complete, independent backup and restore process has been validated. Never delete or manually move a live `Docker.raw` image. Docker's UI is the supported way to relocate a disk image; Docker volumes and databases may contain irreplaceable state.

## Interpretation & limitations

- `df` reports the available space on a filesystem; `du` walks visible directory entries. `diskutil apfs list` reports APFS container and volume allocation. **Do not add overlapping totals.**
- APFS clones, sealed system snapshots, purgeable allocations, sparse images, compressed memory, metadata, and access restrictions explain why measurements differ.
- A `MEASURED` walk means `du` completed for the visible tree, **not** that all bytes are privately owned by that directory or safely removable.
- `PARTIAL` means a measurement failed or was inaccessible. The default scan excludes the protected Photos and Music trees and does not claim to rank every directory on the whole disk.
- Shell output can contain private home folder names, device-related filenames, and other personal metadata. Keep reports local unless carefully sanitized.
- The script does not recurse specifically into cloud roots during targeted triage, but user-selected `--path` and full `--home` or `--data` scans may enter cloud-backed locations. Avoid those when hydration is possible.
- This is read-only with respect to user files. It reads filesystem metadata; the OS itself may update internal access metadata. This tool does not explicitly write logs or temporary scan results.
- Paths containing literal newlines can be misrepresented by line-oriented `du` output. Do not base deletion decisions on those results.

## Development

```bash
bash -n bin/*.sh tests/*.sh
bash tests/test_checkpoint.sh
```

The portable suite uses **synthetic fixtures** in a uniquely created directory beneath `TMPDIR` (default: `/tmp`). The test runner creates small example files, removes only its own fixture directory and symlink at exit, and does not inspect or modify real Mac backups, containers, or projects. **Unlike the diagnostic commands, the test suite does write and delete disposable test files.** On a critically full Mac, prefer the GitHub Actions Linux test run rather than executing the fixture suite locally. No real Mac diagnostics are checked into this repository. Validation on macOS 11.7 requires running the read-only diagnostic commands on a real Mac and reviewing BSD `du` differences before a release is declared stable.

## Operational boundaries

The two diagnostic shell entry points perform **measurement only**. They do not invoke cleanup, move or delete files, contact cloud services, request administrative privileges, or write reports. Shell-based measurements may still cause filesystem reads and may be incomplete because of permissions, snapshots, sparse files, or APFS clones.

The separate `python3 bin/dwp-cache-clean.py` command is a **draft cleanup extension**. It defaults to preview and accepts only two fixed pip HTTP cache targets. Each file deletion requires interactive approval. See [requirements, exact targets, safeguards, race limitations and APFS accounting](docs/cache-cleaner.md). Python 3.8+ is required for this command only. Real Big Sur validation is still pending.

This public source tree contains no secret keys or machine-specific diagnostic exports. An operator should keep raw paths, device identifiers, and reports local unless deliberately sanitized.

Licensed under MIT. See `LICENSE`.
