#!/usr/bin/env bash
# DWP Storage Forensics 1.2: read-only macOS checkpoint with useful first screen.
set -u
export LC_ALL=C
DWP_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 70
# shellcheck source=dwp-common.sh
. "$DWP_SCRIPT_DIR/dwp-common.sh"
MODE=quick
COLOR=auto
SHOW_CLOUD=0
SHOW_RAM=1

usage() {
  cat <<'HELP'
Usage: bash bin/dwp-checkpoint.sh [--quick|--triage|--details|--raw|--check]
       [--cloud] [--no-ram] [--color auto|always|never] [--self-test]

--quick    Minimal first screen; does not identify largest directory (default).
--triage   First screen plus targeted app/developer hotspot scan (metadata I/O).
--details  Show APFS container summary and OS-update snapshot details.
--raw      Print macOS command output for local-only troubleshooting.
--check    Machine-readable DWP_STATE, DWP_FREE_KB, DWP_USED_PERCENT.
           Exit 0 stable, 10 warning, 20 danger, 30 critical.
--cloud    List local sync roots only; remote quota is never queried.
--self-test 7 pure boundary tests, works on non-macOS.

No destructive operations, privileged commands, logs, or network access.
HELP
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick|--triage|--details|--raw|--check) MODE=${1#--};;
    --cloud) SHOW_CLOUD=1;;
    --no-ram) SHOW_RAM=0;;
    --color)
      [ "$#" -ge 2 ] || { echo 'Missing --color value' >&2; exit 64; }
      COLOR=$2; shift;;
    --self-test) MODE=self-test;;
    --help|-h) usage; exit 0;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64;;
  esac
  shift
done
dwp_colors "$COLOR" || exit $?

if [ "$MODE" = self-test ]; then
  failures=0
  while IFS='|' read -r amount wanted; do
    got=$(dwp_state "$amount")
    if [ "$got" = "$wanted" ]; then
      printf 'PASS %s => %s\n' "$amount" "$got"
    else
      printf 'FAIL %s => %s expected %s\n' "$amount" "$got" "$wanted"
      failures=$((failures+1))
    fi
  done <<'BOUNDARIES'
0|CRITICAL
1048575|CRITICAL
1048576|DANGER
3145727|DANGER
3145728|WARNING
15728639|WARNING
15728640|STABLE
BOUNDARIES
  if [ "$failures" -eq 0 ]; then printf 'PASS all 7 boundaries\n'; exit 0; fi
  exit 1
fi

[ "$(uname -s)" = Darwin ] || { echo 'Scanning requires macOS.' >&2; exit 69; }
DATA=/
[ ! -d /System/Volumes/Data ] || DATA=/System/Volumes/Data
DF=$(/bin/df -kP "$DATA" 2>/dev/null) || { echo 'ERROR: df failed' >&2; exit 65; }
MEAS=$(printf '%s\n' "$DF" | dwp_parse_df) || { echo 'ERROR: invalid df output' >&2; exit 65; }
FREE=${MEAS%%|*}
PCT=${MEAS#*|}
STATE=$(dwp_state "$FREE") || exit 65
case "$STATE" in
  CRITICAL) CODE=30; STATUS_COLOR=$DWP_R;;
  DANGER) CODE=20; STATUS_COLOR=$DWP_R;;
  WARNING) CODE=10; STATUS_COLOR=$DWP_Y;;
  STABLE) CODE=0; STATUS_COLOR=$DWP_G;;
esac
if [ "$MODE" = check ]; then
  printf 'DWP_STATE=%s\nDWP_FREE_KB=%s\nDWP_USED_PERCENT=%s\n' "$STATE" "$FREE" "$PCT"
  exit "$CODE"
fi
GAP=$((DWP_KIB_TARGET-FREE))
[ "$GAP" -ge 0 ] || GAP=0
COLS=$(dwp_terminal_cols)
BAR=$(dwp_usage_bar "$PCT" "$COLS")
OS=$(sw_vers -productVersion 2>/dev/null) || OS=unknown
printf '%sDWP // STORAGE CHECKPOINT %s%s   [READ ONLY]\n' "$DWP_C" "$DWP_VERSION" "$DWP_Z"
printf '%s%s%s  %s used  |  %s free  |  %s below 15 GiB target\n' \
  "$STATUS_COLOR" "$STATE" "$DWP_Z" "$PCT%" "$(dwp_human_kib "$FREE")" "$(dwp_human_kib "$GAP")"
printf '%s%s%s  APFS Data / OS %s\n' "$STATUS_COLOR" "$BAR" "$DWP_Z" "$OS"
if [ "$SHOW_RAM" -eq 1 ]; then
  RAM=$(sysctl -n hw.memsize 2>/dev/null) || RAM=''
  SWAP=$(sysctl vm.swapusage 2>/dev/null | dwp_swap_summary) || SWAP=UNKNOWN
  if dwp_is_uint "$RAM"; then
    RGH=$(/usr/bin/awk -v n="$RAM" 'BEGIN {printf "%.2f", n/1073741824}')
    printf 'RAM %s GiB   |   Swap used/total %s\n' "$RGH" "$SWAP"
  else
    printf 'RAM UNKNOWN   |   Swap used/total %s\n' "$SWAP"
  fi
fi

if [ "$MODE" = triage ]; then
  printf '%sMEASURING%s selected app/developer trees below; not a complete APFS inventory.\n' "$DWP_C" "$DWP_Z"
  bash "$DWP_SCRIPT_DIR/dwp-hotspots.sh" --triage --color "$COLOR"
  SCAN_RC=$?
  if [ "$SCAN_RC" -ne 0 ]; then
    printf '%s[PARTIAL]%s At least one lens could not be measured fully.\n' "$DWP_Y" "$DWP_Z"
    exit "$SCAN_RC"
  fi
  printf '%sNEXT%s: inspect the largest result with dwp-hotspots.sh --path "<PATH>".\n' "$DWP_C" "$DWP_Z"
else
  printf 'LARGEST DIRECTORY: %sUNKNOWN%s until a hotspot scan runs.\n' "$DWP_Y" "$DWP_Z"
  printf '%sNEXT%s: bash bin/dwp-checkpoint.sh --triage  (filesystem metadata I/O)\n' "$DWP_C" "$DWP_Z"
fi

if [ "$SHOW_CLOUD" -eq 1 ]; then
  printf '\nLOCAL CLOUD PATHS (existence only; remote quotas NOT measured):\n'
  for p in "$HOME/Library/Mobile Documents/com~apple~CloudDocs" \
           "$HOME/Library/CloudStorage" "$HOME/Google Drive"; do
    if [ -d "$p" ]; then printf 'PRESENT  %s\n' "$p"; fi
  done
fi

if [ "$MODE" = details ] || [ "$MODE" = raw ]; then
  printf '\nAPFS AND SNAPSHOTS (inspect only):\n'
  if command -v diskutil >/dev/null 2>&1; then
    if [ "$MODE" = raw ]; then
      diskutil apfs list 2>&1 || true
    else
      diskutil apfs list 2>&1 | /usr/bin/grep -E \
        'APFS Container Reference|Capacity Ceiling|Capacity In Use|Capacity Not Allocated' | /usr/bin/head -n 20 || true
    fi
    for vol in / /System/Volumes/Data; do
      [ -d "$vol" ] || continue
      printf 'Snapshots (%s):\n' "$vol"
      if [ "$MODE" = raw ]; then
        diskutil apfs listSnapshots "$vol" 2>&1 || true
      else
        diskutil apfs listSnapshots "$vol" 2>&1 | /usr/bin/grep -E \
          'Name:|Purgeable:|NOTE:' || true
      fi
    done
  fi
  printf 'Note: OS-update snapshots are not Time Machine backups by default.\n'
  if [ "$MODE" = raw ]; then
    printf '\nRAW DF:\n'; /bin/df -h / "$DATA" 2>&1 || true
    printf '\nRAW VM STAT:\n'; vm_stat 2>&1 || true
    printf '\nRAW LSOF (may include sensitive paths):\n'; lsof +L1 -n 2>&1 || true
  fi
fi
printf 'No deletion, cleanup, sudo, data transfer, or report file writing.\n'
