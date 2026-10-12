#!/usr/bin/env bash
# Shared helpers for the reviewer dispatchers: temp-file tracking, data-safe
# placeholder substitution, and `task` prompt assembly. Meant to be sourced
# (the sourcing script owns `set -euo pipefail`).

err()  { printf '%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- cleanup: delete ONLY temp files this process created ---
_PRIVATE=()
cleanup() {
  local f
  [ "${#_PRIVATE[@]}" -gt 0 ] || return 0
  for f in "${_PRIVATE[@]}"; do
    [ -n "$f" ] && rm -f "$f"
  done
  return 0
}
trap cleanup EXIT INT TERM
# Sets REPLY to a freshly-created temp path and tracks it for cleanup.
# Must NOT be called inside a command substitution — that runs in a subshell and
# would lose the _PRIVATE array update, leaking the temp file.
mk_private() {
  REPLY="$(mktemp "${TMPDIR:-/tmp}/dispatch.XXXXXX")"
  _PRIVATE+=("$REPLY")
}

is_file_path_key() { case "$1" in *_FILE_PATH) return 0 ;; *) return 1 ;; esac; }

# --- data-safe literal substitution: [KEY] -> VALUE (no regex/sed metachar hazard) ---
require_no_newline() {
  case "$2" in
    *$'\n'*) die "--set $1 value must not contain a newline" ;;
  esac
}
subst_into() {            # subst_into <file> <KEY> <VALUE>
  local file="$1" key="$2" val="$3" content
  content="$(cat "$file"; printf x)"; content="${content%x}"   # preserve trailing newlines
  content="${content//"[$key]"/"$val"}"
  printf '%s' "$content" > "$file"
}
# assert_no_residual <file> [allowed-names]
# allowed-names: space-separated placeholder names (without brackets) that may remain.
assert_no_residual() {
  local file="$1" allowed=" ${2:-} " tok residual=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$allowed" in
      *" ${tok:1:${#tok}-2} "*) ;;          # strip the surrounding [ ]
      *) residual="${residual}${tok}"$'\n' ;;
    esac
  done < <(grep -Eo '\[[A-Z_][A-Z0-9_]*\]' "$file" | sort -u || true)
  if [ -n "$residual" ]; then
    err "unsubstituted placeholder(s) remain:"
    printf '%s' "$residual" >&2
    die "provide a --set for each placeholder."
  fi
}

require_file() { [ -f "$1" ] || die "file not found: $1 (cwd=$(pwd))"; }

# task_assemble_prompt: parse `task` arguments (--prompt, --report-file, --set K=V,
# --dry-run), validate them, and render the prompt into a private temp file.
# Results (no command substitution, so cleanup tracking survives):
#   REPLY         path of the rendered private prompt file
#   TASK_DRY_RUN  1 if --dry-run was given, else 0
task_assemble_prompt() {
  local prompt="" report_src="" dry=0
  local -a set_keys=() set_vals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      --report-file) report_src="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --set)
        local kv="$2"; shift 2
        set_keys+=("${kv%%=*}"); set_vals+=("${kv#*=}") ;;
      *) die "task: unknown arg: $1" ;;
    esac
  done
  [ -n "$prompt" ] || die "task: --prompt is required"
  require_file "$prompt"
  [ -z "$report_src" ] || require_file "$report_src"

  # Validate inputs first (fail loudly before building anything):
  #   - reject newline values; - every *_FILE_PATH --set value must exist.
  local i
  if [ "${#set_keys[@]}" -gt 0 ]; then
    for i in "${!set_keys[@]}"; do
      require_no_newline "${set_keys[$i]}" "${set_vals[$i]}"
      if is_file_path_key "${set_keys[$i]}"; then require_file "${set_vals[$i]}"; fi
    done
  fi

  local work; mk_private; work="$REPLY"
  cat "$prompt" > "$work"

  # report: copy source content into our OWN private file; inject the private path.
  if [ -n "$report_src" ]; then
    local report_priv; mk_private; report_priv="$REPLY"
    cat "$report_src" > "$report_priv"
    subst_into "$work" "REPORT_FILE_PATH" "$report_priv"
  fi

  if [ "${#set_keys[@]}" -gt 0 ]; then
    for i in "${!set_keys[@]}"; do subst_into "$work" "${set_keys[$i]}" "${set_vals[$i]}"; done
  fi
  assert_no_residual "$work"

  # shellcheck disable=SC2034  # read by the sourcing script
  TASK_DRY_RUN="$dry"
  REPLY="$work"
}
