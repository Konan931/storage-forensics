#!/usr/bin/env bash
# Shared, side-effect-free helpers. Compatible with macOS Bash 3.2.

DWP_VERSION=1.2.0
DWP_KIB_TARGET=15728640

# Only whole numbers are permitted in disk-capacity arithmetic.
dwp_is_uint() {
  case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac
}

dwp_state() {
  dwp_is_uint "$1" || return 64
  if [ "$1" -lt 1048576 ]; then printf 'CRITICAL\n'
  elif [ "$1" -lt 3145728 ]; then printf 'DANGER\n'
  elif [ "$1" -lt 15728640 ]; then printf 'WARNING\n'
  else printf 'STABLE\n'; fi
}

dwp_human_kib() {
  /usr/bin/awk -v n="$1" 'BEGIN {
    if (n >= 1073741824) printf "%.2f TiB", n/1073741824;
    else if (n >= 1048576) printf "%.2f GiB", n/1048576;
    else if (n >= 1024) printf "%.1f MiB", n/1024;
    else printf "%.0f KiB", n;
  }'
}

# Input: full POSIX df -kP output. Output: available_kib|used_percent.
# Reject malformed or unexpectedly multi-line records rather than guessing.
dwp_parse_df() {
  /usr/bin/awk '
    NR == 2 {
      if (NF < 6 || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+%$/) exit 65;
      free = $4; pct = $5; sub(/%$/, "", pct);
      if (pct > 100) exit 65;
      printf "%s|%s\n", free, pct;
      seen = 1;
    }
    NR > 2 { unexpected=1; }
    END { if (!seen || unexpected) exit 65; }
  '
}

dwp_colors() {
  DWP_C='' DWP_Y='' DWP_R='' DWP_G='' DWP_Z='' DWP_B=''
  local use_color=0
  case "$1" in
    always) use_color=1;;
    never) use_color=0;;
    auto)
      if [ -t 1 ] && [ "${NO_COLOR+x}" != x ] && [ "${TERM:-dumb}" != dumb ]; then
        use_color=1
      fi;;
    *) printf 'Invalid color setting: %s\n' "$1" >&2; return 64;;
  esac
  if [ "$use_color" -eq 1 ]; then
    DWP_C=$(printf '\033[1;36m'); DWP_Y=$(printf '\033[1;33m')
    DWP_R=$(printf '\033[1;31m'); DWP_G=$(printf '\033[1;32m')
    DWP_B=$(printf '\033[1m'); DWP_Z=$(printf '\033[0m')
  fi
}

dwp_terminal_cols() {
  local cols="${COLUMNS:-}"
  if ! dwp_is_uint "$cols" || [ "$cols" -lt 36 ] || [ "$cols" -gt 300 ]; then
    cols=80
    if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
      local measured
      measured=$(tput cols 2>/dev/null) || measured=''
      if dwp_is_uint "$measured" && [ "$measured" -ge 36 ] && [ "$measured" -le 300 ]; then
        cols="$measured"
      fi
    fi
  fi
  printf '%s\n' "$cols"
}

dwp_usage_bar() {
  local pct="$1" cols="$2"
  /usr/bin/awk -v p="$pct" -v w="$cols" 'BEGIN {
    width = (w < 60 ? 22 : 38);
    p += 0; if (p < 0) p = 0; if (p > 100) p = 100;
    filled = int((p * width / 100) + 0.5);
    printf "[";
    for (i=0; i<width; i++) printf (i < filled ? "#" : ".");
    printf "]";
  }'
}

dwp_swap_summary() {
  /usr/bin/awk 'BEGIN { used = -1; total = -1 }
    {
      if (match($0, /used = *[0-9.]+M/)) {
        s = substr($0, RSTART, RLENGTH); sub(/^used = */, "", s); sub(/M$/, "", s); used=s+0
      }
      if (match($0, /total = *[0-9.]+M/)) {
        s = substr($0, RSTART, RLENGTH); sub(/^total = */, "", s); sub(/M$/, "", s); total=s+0
      }
    }
    END {
      if (used < 0 || total < 0) print "UNKNOWN";
      else printf "%.2f GiB / %.2f GiB", used / 1024, total / 1024;
    }'
}
