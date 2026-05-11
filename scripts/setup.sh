#!/usr/bin/env bash
#
# Sophia — one-shot setup for the knowledge-layer tools.
#
#   - graphify          (PyPI: graphifyy)         Python >= 3.10
#   - llm-wiki-compiler (npm:  llm-wiki-compiler) Node   >= 24
#
# Idempotent: re-running skips already-installed tools and re-runs only
# the configuration steps that are cheap.
#
# Usage:
#   ./scripts/setup.sh              # full setup
#   SKIP_MCP=1 ./scripts/setup.sh   # skip `graphify install` (Claude Code MCP registration)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------- pretty logging --------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

step() { printf "\n%s==>%s %s%s%s\n" "$C_BLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$1"; }
warn() { printf "  %s!%s %s\n"      "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$1" >&2; exit 1; }

# ---------- platform detection ---------------------------------------------

OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM=mac   ;;
  Linux)  PLATFORM=linux ;;
  *)      die "Unsupported OS: $OS (only macOS and Linux are supported)" ;;
esac

# ---------- prerequisites ---------------------------------------------------

check_prereqs() {
  step "Checking prerequisites"

  command -v git >/dev/null 2>&1 || die "git not found"
  ok "git"

  if ! command -v uv >/dev/null 2>&1; then
    die "uv not found. Install via: curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
  ok "uv ($(uv --version))"

  if ! command -v node >/dev/null 2>&1; then
    die "node not found. Install Node.js >= 24 (e.g. via fnm, nvm, or asdf)."
  fi
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  if (( node_major < 24 )); then
    die "Node $node_major detected; llm-wiki-compiler needs >= 24. Upgrade and re-run."
  fi
  ok "node $(node -v)"

  if ! command -v npm >/dev/null 2>&1; then
    die "npm not found (ships with Node)."
  fi
  ok "npm $(npm -v)"
}

# ---------- installers ------------------------------------------------------

install_graphify() {
  step "Installing graphify (PyPI: graphifyy)"
  if command -v graphify >/dev/null 2>&1; then
    ok "graphify already on PATH ($(graphify --version 2>/dev/null || echo 'version unknown'))"
  else
    uv tool install graphifyy
    ok "graphify installed"
  fi

  if [[ "${SKIP_MCP:-0}" == "1" ]]; then
    warn "SKIP_MCP=1 — skipping 'graphify install' (Claude Code MCP registration)"
  else
    step "Registering graphify MCP for Claude Code"
    graphify install || warn "graphify install reported an error; re-run manually if needed."
  fi
}

install_llmwiki() {
  step "Installing llm-wiki-compiler (npm: llm-wiki-compiler)"
  if command -v llmwiki >/dev/null 2>&1; then
    ok "llmwiki already on PATH ($(llmwiki --version 2>/dev/null || echo 'version unknown'))"
  else
    npm install -g llm-wiki-compiler
    ok "llmwiki installed"
  fi
}

# ---------- project-local bootstrap ----------------------------------------

bootstrap_project() {
  step "Bootstrapping project-local layout"

  if [[ -f pyproject.toml ]]; then
    uv sync
    ok "uv sync (.venv ready)"
  fi

  mkdir -p wiki target_data/{code,md,pdf}
  ok "wiki/ and target_data/{code,md,pdf} ready"

  if [[ ! -f .gitignore ]]; then
    : > .gitignore
  fi
  for line in ".llmwiki/candidates/" "node_modules/" ".venv/"; do
    if ! grep -qxF "$line" .gitignore; then
      echo "$line" >> .gitignore
      ok ".gitignore += $line"
    fi
  done
}

# ---------- environment check ----------------------------------------------

check_env() {
  step "Checking environment for llm-wiki-compiler"
  local provider="${LLMWIKI_PROVIDER:-anthropic}"
  case "$provider" in
    anthropic)
      if [[ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
        ok "ANTHROPIC_API_KEY (or AUTH_TOKEN) present"
      else
        warn "ANTHROPIC_API_KEY not set — llmwiki compile will fail until you export it."
      fi
      ;;
    openai)
      [[ -n "${OPENAI_API_KEY:-}" ]] && ok "OPENAI_API_KEY present" || warn "OPENAI_API_KEY not set."
      ;;
    ollama)
      [[ -n "${OLLAMA_HOST:-}" ]] && ok "OLLAMA_HOST=$OLLAMA_HOST" || warn "OLLAMA_HOST not set."
      ;;
    *)
      warn "Unknown LLMWIKI_PROVIDER='$provider'"
      ;;
  esac
}

# ---------- verification ----------------------------------------------------

verify_all() {
  step "Verifying installations"
  command -v graphify >/dev/null && ok "graphify on PATH" || warn "graphify missing"
  command -v llmwiki  >/dev/null && ok "llmwiki on PATH"  || warn "llmwiki missing"
}

# ---------- summary ---------------------------------------------------------

print_next_steps() {
  cat <<EOF

${C_BOLD}Setup complete.${C_RESET} Next steps:

  1. Export your LLM provider key (if not already):
       export ANTHROPIC_API_KEY=sk-...

  2. Drop source material into ${C_BOLD}target_data/${C_RESET}:
       - target_data/code/   git submodules or copies of target repos
       - target_data/md/     hand-curated or ingested markdown
       - target_data/pdf/    PDFs to be ingested

  3. Compile the wiki for the first time:
       llmwiki ingest target_data/
       llmwiki compile

  4. Build the graph:
       graphify .            # writes graph.json / graph.html

For details, see docs/architecture.md.
EOF
}

# ---------- main ------------------------------------------------------------

main() {
  step "Sophia setup (platform: $PLATFORM)"
  check_prereqs
  install_graphify
  install_llmwiki
  bootstrap_project
  check_env
  verify_all
  print_next_steps
}

main "$@"
