#!/usr/bin/env bash
# Portable tests with synthetic fixtures. Must not touch real macOS files.
set -eu
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECKPOINT="$ROOT/bin/dwp-checkpoint.sh"
HOTSPOTS="$ROOT/bin/dwp-hotspots.sh"
COMMON="$ROOT/bin/dwp-common.sh"

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { printf '%s' "$1" | grep -F -- "$2" >/dev/null || fail "missing text: $2"; pass=$((pass+1)); }
assert_not_contains() { if printf '%s' "$1" | grep -F -- "$2" >/dev/null; then fail "unexpected text: $2"; fi; pass=$((pass+1)); }
expect_code() {
  expected=$1; shift
  code=0
  "$@" >/dev/null 2>&1 || code=$?
  [ "$code" -eq "$expected" ] || fail "expected exit $expected, got $code for $*"
  pass=$((pass+1))
}

for f in "$ROOT"/bin/*.sh "$ROOT"/tests/*.sh; do bash -n "$f" || fail "syntax: $f"; pass=$((pass+1)); done

out=$(bash "$CHECKPOINT" --self-test) || fail 'boundary tests'
assert_contains "$out" 'PASS all 7 boundaries'

# Testing pure functions avoids faking macOS, root, or the whole df command.
. "$COMMON"
[ "$(dwp_state 1048575)" = CRITICAL ] || fail 'threshold critical'
[ "$(dwp_state 1048576)" = DANGER ] || fail 'threshold danger'
[ "$(dwp_state 15728640)" = STABLE ] || fail 'threshold stable'
pass=$((pass+3))

mock_df='Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk7s1 118286000 117924400 361600 100% /System/Volumes/Data'
parsed=$(printf '%s\n' "$mock_df" | dwp_parse_df) || fail 'valid synthetic df'
[ "$parsed" = '361600|100' ] || fail "df parsed incorrectly: $parsed"
pass=$((pass+1))

if printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' \
  '/dev/disk1s1 1000 999 invalid 99% /' | dwp_parse_df >/dev/null 2>&1; then
  fail 'accepted corrupt df record'
fi
pass=$((pass+1))

swap=$(printf '%s\n' 'vm.swapusage: total = 3072.00M used = 1723.75M free = 1348.25M (encrypted)' | dwp_swap_summary)
[ "$swap" = '1.68 GiB / 3.00 GiB' ] || fail "swap parse: $swap"
pass=$((pass+1))

bar=$(dwp_usage_bar 100 80)
[ "$bar" = '[######################################]' ] || fail '100 percent bar'
pass=$((pass+1))

# All disposable fixture files are created in an isolated temp directory.
TMP_BASE=${TMPDIR:-/tmp}
FIXTURE=$(mktemp -d "$TMP_BASE/dwp-test.XXXXXXXX") || fail 'mktemp fixture'
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$FIXTURE/large folder" "$FIXTURE/small folder"
dd if=/dev/zero of="$FIXTURE/large folder/larger.dat" bs=1024 count=96 2>/dev/null
dd if=/dev/zero of="$FIXTURE/small folder/smaller.dat" bs=1024 count=4 2>/dev/null
dd if=/dev/zero of="$FIXTURE/top-level.dat" bs=1024 count=16 2>/dev/null

out=$(bash "$HOTSPOTS" --path "$FIXTURE" --depth 1 --limit 3 --color never) || fail 'fixture scan'
assert_contains "$out" 'large folder'
assert_contains "$out" 'top-level.dat'
assert_contains "$out" 'small folder'
assert_contains "$out" '[MEASURED]'
assert_contains "$out" 'NOT scan I/O'
assert_not_contains "$out" $'\033['

# Force ANSI only upon explicit request.
out=$(bash "$HOTSPOTS" --path "$FIXTURE" --color always) || fail 'forced color'
assert_contains "$out" $'\033['

# NO_COLOR must override auto, even when set to an empty string.
out=$(NO_COLOR= TERM=xterm bash "$HOTSPOTS" --path "$FIXTURE" --color auto) || fail 'no-color'
assert_not_contains "$out" $'\033['

ln -s "$FIXTURE" "$FIXTURE-link"
expect_code 64 bash "$HOTSPOTS" --path "$FIXTURE-link"
rm "$FIXTURE-link"
expect_code 64 bash "$HOTSPOTS" --depth 3
expect_code 64 bash "$HOTSPOTS" --limit 0
expect_code 64 bash "$HOTSPOTS" --color broken
expect_code 64 bash "$CHECKPOINT" --color broken

if [ "$(uname -s)" != Darwin ]; then
  expect_code 69 bash "$CHECKPOINT" --quick
fi
printf 'PASS %d portable assertions (including 7 threshold cases)\n' "$pass"
