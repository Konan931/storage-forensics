#!/usr/bin/env bash
# Read-only filesystem size reconnaissance. Bash 3.2; macOS BSD du.
# IMPORTANT: --depth limits displayed entries, not total disk traversal.
set -u
set -o pipefail
export LC_ALL=C

DWP_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 70
# shellcheck source=dwp-common.sh
. "$DWP_SCRIPT_DIR/dwp-common.sh"

MODE=triage
COLOR=auto
ROOT=''
DEPTH=1
LIMIT=12

usage() {
  cat <<'HELP'
Usage: bash bin/dwp-hotspots.sh [--triage|--home|--library|--data|--path DIR]
       [--depth 1|2] [--limit 1..50] [--color auto|always|never]

Read-only sizes; no sudo, deletion, sync, or file output.
--triage   Focus on app state / developer paths (not a whole-disk inventory).
--path     Investigate one explicit local directory; symlink roots rejected.
--home     Full home subtree (HIGH metadata I/O; includes personal data).
--library  Full user Library subtree (HIGH metadata I/O).
--data     Entire APFS Data subtree (VERY HIGH metadata I/O).
--depth    Display depth; it DOES NOT limit how far du must traverse.

Readability != reclaimability: preserve MobileSync, Photos, Docker volumes,
projects, cloud roots, and APFS snapshots pending separate validation.
HELP
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --triage|--home|--library|--data) MODE=${1#--};;
    --path|--depth|--limit|--color)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 64; }
      case "$1" in
        --path) MODE=path; ROOT=$2;;
        --depth) DEPTH=$2;;
        --limit) LIMIT=$2;;
        --color) COLOR=$2;;
      esac
      shift;;
    --help|-h) usage; exit 0;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64;;
  esac
  shift
done

case "$DEPTH" in 1|2) ;; *) printf '%s\n' 'Depth must be 1 or 2' >&2; exit 64;; esac
dwp_is_uint "$LIMIT" && [ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 50 ] || {
  printf '%s\n' 'Limit must be 1..50' >&2; exit 64;
}
dwp_colors "$COLOR" || exit $?

# --path must be deliberately chosen, not a symlink to an unrelated tree.
if [ "$MODE" = path ]; then
  if [ -z "$ROOT" ] || [ ! -d "$ROOT" ] || [ -L "$ROOT" ]; then
    printf 'Path is absent, not a directory, or a symlink: %s\n' "$ROOT" >&2
    exit 64
  fi
fi

scan() {
  local label="$1" dir="$2" rc
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    printf '%s[SKIPPED]%s %s (not a directory or symlink root)\n' "$DWP_Y" "$DWP_Z" "$label"
    return 0
  fi

  printf '\n%s== %s ==%s\n%s\n' "$DWP_C" "$label" "$DWP_Z" "$dir"
  # BSD macOS du treats -a and -d as mutually exclusive. Never combine them.
  # First stream directory totals, then only immediate regular files via find.
  # The two traversals feed a bounded top-N in awk; no disk-backed sort/temp.
  {
    /usr/bin/du -x -k -d "$DEPTH" "$dir" 2>/dev/null
    dwp_walk_rc=$?
    /usr/bin/find "$dir" ! -path "$dir" -prune -type f \
      -exec /usr/bin/du -k {} + 2>/dev/null
    dwp_files_rc=$?
    [ "$dwp_walk_rc" -eq 0 ] && [ "$dwp_files_rc" -eq 0 ]
  } | /usr/bin/awk -F '\t' -v root="$dir" -v limit="$LIMIT" '
    function human(k) {
      if (k >= 1073741824) return sprintf("%.2f TiB", k/1073741824);
      if (k >= 1048576) return sprintf("%.2f GiB", k/1048576);
      if (k >= 1024) return sprintf("%.1f MiB", k/1024);
      return sprintf("%.0f KiB", k);
    }
    function before(a, name, b, other) { return a > b || (a == b && name < other); }
    {
      if ($1 !~ /^[0-9]+$/) { bad++; next }
      val = $1 + 0
      # Reconstruct paths with tab characters; terminal controls are sanitized.
      p = $0; sub(/^[^\t]*\t/, "", p)
      if (p == root) { root_value=val; seen_root=1; next }
      if (p == "" || p == root) next
      gsub(/[[:cntrl:]]/, "?", p)
      pos=0
      for (i=1; i<=limit; i++) {
        if (i>n || before(val,p,sizes[i],names[i])) { pos=i; break }
      }
      if (!pos) next
      if (n<limit) n++
      for (j=n; j>pos; j--) { sizes[j]=sizes[j-1]; names[j]=names[j-1] }
      sizes[pos]=val; names[pos]=p
    }
    END {
      for (i=1; i<=n; i++) printf " %2d  %10s  %s\n", i, human(sizes[i]), names[i]
      if (n==0) print "  No visible children"
      if (seen_root) printf "  ROOT %s (visible same-filesystem du estimate)\n", human(root_value)
      else print "  ROOT UNKNOWN (not reported by du)"
      if (bad>0) printf "  WARNING: %d unparsed records\n", bad
    }'
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  %s[MEASURED]%s visible entries; APFS allocation not reconciled\n' "$DWP_G" "$DWP_Z"
    return 0
  else
    printf '  %s[PARTIAL]%s du failed or paths were inaccessible (status %d)\n' "$DWP_Y" "$DWP_Z" "$rc"
    return 2
  fi
}

printf '%sDWP // HOTSPOT FINDER %s%s   [READ ONLY]\n' "$DWP_C" "$DWP_VERSION" "$DWP_Z"
printf '%sNOTE%s: --depth controls output detail, NOT scan I/O. Stop with Ctrl+C if I/O stalls.\n' "$DWP_Y" "$DWP_Z"
rc=0
case "$MODE" in
  path) scan 'SELECTED LOCAL PATH' "$ROOT" || rc=2;;
  home) scan 'HOME / FULL WALK' "$HOME" || rc=2;;
  library) scan 'LIBRARY / FULL WALK' "$HOME/Library" || rc=2;;
  data) scan 'DATA / EXPENSIVE FULL WALK' /System/Volumes/Data || rc=2;;
  triage)
    # Deliberately avoid broad Photos, cloud, and home recursion by default.
    scan 'APP SUPPORT / APP DATA' "$HOME/Library/Application Support" || rc=2
    scan 'CONTAINERS / APP SANDBOXES' "$HOME/Library/Containers" || rc=2
    scan 'DEVELOPER / HOME VS CODE' "$HOME/.vscode" || rc=2
    scan 'DEVELOPER / BREW ROOT' /usr/local || rc=2
    printf '\n[UNMEASURED] Photos, Music, full Home, full Data, snapshots.\n'
    ;;
esac
printf '\n%sINTERPRETATION%s: sizes are not verified reclaimable bytes. No files modified.\n' "$DWP_C" "$DWP_Z"
exit "$rc"
