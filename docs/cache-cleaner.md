# Controlled cache cleaner (review candidate)

This separate extension is based on PR #1 commit
`160d2bafa99fdc247a27d57e9494f4df30a8cede`. Neither diagnostic shell command
is modified. No real Mac cleanup was performed during development.

## Requirements and use

macOS 11.7 or later, a separately available Python 3.8+ interpreter with
`dir_fd`, descriptor listing and `O_NOFOLLOW` support. Python is **not** assumed
to ship with Big Sur; the cleaner does not install anything. Run as the normal
account, never via sudo. Actual Big Sur hardware validation remains outstanding.

From the repository root:

```bash
python3 bin/dwp-cache-clean.py --help
python3 bin/dwp-cache-clean.py --list
python3 bin/dwp-cache-clean.py --target pip-http-v2
```

The last command is a read-only preview. It prints the complete candidate list,
logical sizes and allocated-block estimates. Missing targets are reported as STOP
(exit 2); nothing is created. An empty cache is a successful no-op.

Only after reviewing that preview and stopping **all** pip/install/build jobs:

```bash
python3 bin/dwp-cache-clean.py --target pip-http-v2 --apply
```

This enables the approval flow, not automatic deletion. Confirm `JOBS STOPPED`,
then type `DELETE` for **each exact displayed file**. `SKIP` retains that file;
any other answer stops. EOF/Ctrl+C stops. There is no `--yes`, saved authorization,
custom root, environmental HOME override, or unattended mode. Piped stdin or
redirected stdout is rejected in apply mode. Every successful unlink is printed.
An error stops further cleanup; completed deletions are not rolled back.

Use `--color auto|always|never`. Auto respects `NO_COLOR`, `TERM=dumb` and TTY
status. Filenames are escaped to prevent terminal control injection. Output is
local and may contain your account path; sanitize before publishing.

## Exact allowlist

| ID | Fixed path under the account database home | Accepted structure |
| --- | --- | --- |
| `pip-http` | `Library/Caches/pip/http` | Five single hex directories, then a 56-character lowercase hex filename |
| `pip-http-v2` | `Library/Caches/pip/http-v2` | Same, also allowing the `.body` suffix |

These are HTTP response/download caches, not installed packages or environments.
Future pip operations may redownload content, costing time/network traffic.
Regeneration requires the source still to exist and be accessible; this is not
an offline backup strategy. Wheels, custom `PIP_CACHE_DIR`/XDG locations and
unknown layouts are deliberately out of scope. A hash-shaped filename alone
cannot prove provenance: the operator must confirm this really is pip's cache.

Rationale and source references:
- [pip caching documentation](https://pip.pypa.io/en/stable/topics/caching/):
  macOS default path, HTTP cache role, `http-v2`, internal-format instability.
- [pip vendored CacheControl implementation](https://github.com/pypa/pip/blob/main/src/pip/_vendor/cachecontrol/caches/file_cache.py):
  SHA-224 key, five-level directory fanout and optional `.body` file.

Unknown files (including lock/temp files), names or subdirectories abort the
whole initial scan **before any deletion**. This intentionally fails closed when
pip changes its layout. A future target needs its own review and tests.

## Protection and concurrency boundary

The CLI derives home from the account database, not `$HOME`. All ancestors are
opened without following symlinks; user-owned cache/home directories must not
be writable by group/others. System ancestors must belong to root or the user.
It checks inode/device, owners, permissions, links and file timestamps. Nested
mounts on different devices, hardlinked files, symlinks, special files and flagged
files are refused. Directory descriptors pin the traversal; cache-directory
identities are recorded during preview and rechecked after each approval.
Descriptors are bounded by traversal depth, not cache size.

Deletion uses `unlink` relative to a checked parent descriptor. It never performs
`rm -rf`, follows a file symlink, deletes directories, invokes pip, or expands to
unknown paths. iPhone backups, Photos, cloud data, Docker volumes, projects,
other caches, system data and snapshots have no selectable cleanup target.
Empty directories remain; no additional destructive operation is hidden.

**This is not a security boundary against a malicious process running as the
same user or root.** Portable Python/macOS does not provide an atomic
"unlink only if inode still matches" operation. A writer can race the final
stat/unlink or move a pinned directory after its check. Stop producers first;
do not run in an adversarial or actively changing tree. Detected changes stop
execution. Ordinary POSIX mode checks also do not constitute an ACL audit.
There is no claim of complete race elimination or automatic process quiescence.

## Space accounting

The final summary (also on partial failure/interruption during deletion) reports:

- Successfully unlinked files and their pre-deletion logical bytes.
- Sum of their `st_blocks * 512`: allocated-byte **estimate**, not guaranteed gain.
- Available filesystem bytes via `fstatvfs`, before/after and signed delta.
  Measurement failure is `unknown`, never fabricated as zero.

A positive delta is an observed volume-wide change, **not independently
attributable recovered space**. APFS snapshots/clones, open handles, compression,
purgeable accounting and concurrent activity prevent that conclusion. Zero or
negative change is preserved. No sync, snapshot deletion or broader cleanup is
triggered to force a better number.

## Verification

```bash
bash tests/test_checkpoint.sh
python3 -m unittest discover -s tests -p 'test_cache_cleaner.py' -v
```

Tests create private temporary fixtures directly beneath the test account home,
not its real cache. They remove only those generated fixtures. They include real
fixture unlinks, preview/approval/decline/interrupt paths, symlink and hardlink
attacks, unknown entries, renamed directories, permissions, failure reporting,
protected sentinel files and accounting fallback. CLI platform/account injection
exists only in tests; no production `--test-root` or platform bypass is exposed.
Do not run fixture suites on a critically full disk.

Before leaving draft: run tests with a compatible Python on an actual Big Sur
11.7 Mac, inspect the live preview, then separately authorize a small known cache
file and compare its deletion and volume metrics. Modern macOS CI is useful but
cannot certify Big Sur/APFS behavior.
