#!/usr/bin/env bash
#
# Sophia — read-only verification that graphify and llm-wiki-compiler are installed
# and usable. Safe to run anytime; touches no state.
#
# Exit codes:
#   0  all required checks passed
#   1  at least one required check failed
#
# Usage:
#   ./scripts/verify.sh
#   ./scripts/verify.sh --quiet   # only print failures + summary

set -uo pipefail   # intentionally no -e: we want to run every check, then report

QUIET=0
for arg in "$@"; do
  case "$arg" in
    -q|--quiet) QUIET=1 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---------- pretty logging --------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

pass_count=0
fail_count=0
warn_count=0

section() { (( QUIET )) || printf "\n%s==>%s %s%s%s\n" "$C_BLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
pass()    { (( QUIET )) || printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$1"; pass_count=$((pass_count+1)); }
fail()    {                printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$1" >&2; fail_count=$((fail_count+1)); }
warnmsg() {                printf "  %s!%s %s\n" "$C_YELLOW" "$C_RESET" "$1" >&2; warn_count=$((warn_count+1)); }

# ---------- check helpers ---------------------------------------------------

# require LABEL CMD [ARGS...]   — runs CMD, pass/fail based on exit code
require() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label  (command: $*)"
  fi
}

# require_path LABEL BIN
require_path() {
  local label="$1" bin="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    local where; where="$(command -v "$bin")"
    pass "$label  → $where"
  else
    fail "$label  ('$bin' not found on PATH)"
  fi
}

# ---------- prerequisite checks --------------------------------------------

section "Prerequisites"

require_path "uv installed"   uv
require_path "node installed" node
require_path "npm installed"  npm

if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if (( node_major >= 24 )); then
    pass "node major >= 24  (found $(node -v))"
  else
    fail "node major >= 24  (found $(node -v); llm-wiki-compiler requires >= 24)"
  fi
fi

# ---------- graphify --------------------------------------------------------

section "graphify (PyPI: graphifyy)"

if command -v graphify >/dev/null 2>&1; then
  pass "graphify on PATH  → $(command -v graphify)"

  # graphify exposes --help; --version may or may not exist depending on release.
  if graphify --version >/dev/null 2>&1; then
    pass "graphify --version  → $(graphify --version 2>/dev/null | head -n1)"
  elif graphify --help >/dev/null 2>&1; then
    pass "graphify --help responds"
  else
    fail "graphify is on PATH but neither --version nor --help works"
  fi

  # Confirm it was installed via uv (so reinstall semantics are predictable)
  if command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -qiE '(^| )graphifyy( |$)'; then
    pass "uv tool list contains graphifyy"
  else
    warnmsg "graphifyy not in 'uv tool list' (installed via pip/pipx? still works, but setup.sh assumes uv)"
  fi
else
  fail "graphify not on PATH  (run: uv tool install graphifyy)"
fi

# ---------- llm-wiki-compiler ----------------------------------------------

section "llm-wiki-compiler (npm: llm-wiki-compiler)"

if command -v llmwiki >/dev/null 2>&1; then
  pass "llmwiki on PATH  → $(command -v llmwiki)"

  if llmwiki --version >/dev/null 2>&1; then
    pass "llmwiki --version  → $(llmwiki --version 2>/dev/null | head -n1)"
  elif llmwiki --help >/dev/null 2>&1; then
    pass "llmwiki --help responds"
  else
    fail "llmwiki is on PATH but neither --version nor --help works"
  fi

  if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 2>/dev/null | grep -q 'llm-wiki-compiler@'; then
    pass "npm -g lists llm-wiki-compiler"
  else
    warnmsg "llm-wiki-compiler not in 'npm ls -g' (installed via npx? not pinned globally)"
  fi
else
  fail "llmwiki not on PATH  (run: npm install -g llm-wiki-compiler)"
fi

# ---------- environment (advisory) -----------------------------------------

section "Environment (advisory)"

provider="${LLMWIKI_PROVIDER:-anthropic}"
case "$provider" in
  anthropic)
    if [[ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
      pass "ANTHROPIC_API_KEY / AUTH_TOKEN present"
    else
      warnmsg "ANTHROPIC_API_KEY not set  (llmwiki compile will fail at runtime)"
    fi
    ;;
  openai)
    [[ -n "${OPENAI_API_KEY:-}" ]] \
      && pass "OPENAI_API_KEY present" \
      || warnmsg "OPENAI_API_KEY not set"
    ;;
  ollama)
    [[ -n "${OLLAMA_HOST:-}" ]] \
      && pass "OLLAMA_HOST=$OLLAMA_HOST" \
      || warnmsg "OLLAMA_HOST not set"
    ;;
  *)
    warnmsg "Unknown LLMWIKI_PROVIDER='$provider'"
    ;;
esac

# ---------- summary --------------------------------------------------------

printf "\n%s%s%s pass · %s%s%s fail · %s%s%s warn\n" \
  "$C_GREEN" "$pass_count" "$C_RESET" \
  "$C_RED"   "$fail_count" "$C_RESET" \
  "$C_YELLOW" "$warn_count" "$C_RESET"

if (( fail_count > 0 )); then
  echo "Run ./scripts/setup.sh to install missing tools." >&2
  exit 1
fi
exit 0
