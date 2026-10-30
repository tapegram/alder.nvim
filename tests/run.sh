#!/bin/sh
# tests/run.sh [pattern]: run the headless suite in one throwaway temp root.
#
# - Everything Neovim and the tests write (tempname dirs, scratch apps, state, cache) goes under
#   one root that is removed on exit, also on failure or Ctrl-C. (Neovim's own tempdir cleanup is
#   skipped by os.exit, which used to leave ~6 GB per run in $TMPDIR/nvim.$USER.)
# - alder comes from ALDER_BIN, else ~/go/bin/alder, else PATH; the choice is printed and an alder
#   without `help --json` (editor support) and an lsp command is rejected.
# - The Go build cache stays shared (GOCACHE is pinned before the root is set up), so apps still
#   build warm. Set ALDER_TEST_KEEP=1 to keep the root for debugging.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)

alder=${ALDER_BIN:-}
[ -z "$alder" ] && [ -x "$HOME/go/bin/alder" ] && alder=$HOME/go/bin/alder
[ -z "$alder" ] && alder=$(command -v alder || true)
if [ -z "$alder" ] || [ ! -x "$alder" ]; then
  echo "tests: no alder found (set ALDER_BIN, or go install ./cmd/alder from the alder repo)" >&2
  exit 2
fi
if ! "$alder" help --json 2>/dev/null | grep -q '"lsp"'; then
  echo "tests: $alder ($("$alder" version 2>&1 | head -1)) is too old: it lacks \`help --json\` with the lsp command" >&2
  echo "       build a current one (go install ./cmd/alder in the alder repo) or set ALDER_BIN" >&2
  exit 2
fi
echo "tests: using alder $alder ($("$alder" version 2>&1 | head -1))"

command -v go >/dev/null 2>&1 && GOCACHE=$(go env GOCACHE) && export GOCACHE
root=$(mktemp -d "${TMPDIR:-/tmp}/alder-nvim-tests.XXXXXX") || exit 2
cleanup() { [ -n "${ALDER_TEST_KEEP:-}" ] && { echo "tests: kept $root"; return; }; rm -rf "$root"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$root/tmp" "$root/data" "$root/state" "$root/cache" "$root/config"
export TMPDIR="$root/tmp" XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
  XDG_CACHE_HOME="$root/cache" XDG_CONFIG_HOME="$root/config"
# nvim-treesitter and nui.nvim default to lazy.nvim's checkouts under the real home
export NVIM_TS=${NVIM_TS:-$HOME/.local/share/nvim/lazy/nvim-treesitter}
export NVIM_NUI=${NVIM_NUI:-$HOME/.local/share/nvim/lazy/nui.nvim}
# put the chosen alder first, so tests that run bare `alder` get it
PATH=$(dirname "$alder"):$PATH
export PATH ALDER_BIN="$alder"

cd "$here" && nvim --headless -u tests/minimal.lua -l tests/run.lua "$@"
