#!/usr/bin/env bash
# 03 — DSIO agent harness. Clone → build → shim on PATH → register MCP.
#
# The harness lives in a PRIVATE repo, so only entitled users can fetch it.
# This step therefore never starts a GitHub login by itself:
#   * already signed in to gh (or GH_TOKEN set) with access to the repo
#       -> clone/update + build as before
#   * otherwise it is skipped with a message (exit 0). To opt in, either
#       - export GH_TOKEN=<fine-grained token: Contents read-only, on
#         jiujitsumagician/dsio only> and re-run (preferred), or
#       - run with FLOWSTATE_DSIO=1 to start the interactive gh browser login
#         (that login asks for the broad classic `repo` scope; prefer a token).
#
# Optional: DSIO_REF=<tag or commit> checks out that exact ref instead of
# fast-forwarding the default branch.
set -euo pipefail

DEST="$HOME/dsio-harness"
REPO="jiujitsumagician/dsio"
DSIO_REF="${DSIO_REF:-}"

skip_msg() {
  echo "  $1"
  echo "  (DSIO is a private harness; to install it later set GH_TOKEN to a read-only fine-grained token"
  echo "   for $REPO, or re-run with FLOWSTATE_DSIO=1 to sign in with gh interactively.)"
}

FETCH=1
if ! command -v gh >/dev/null 2>&1; then
  FETCH=0; skip_msg "gh is not installed — skipping DSIO harness download"
elif ! gh auth status >/dev/null 2>&1; then
  if [[ "${FLOWSTATE_DSIO:-0}" == "1" ]]; then
    echo "  gh is not signed in — starting browser login (approve the device code)"
    gh auth login --hostname github.com --web --git-protocol https --scopes repo
  else
    FETCH=0; skip_msg "gh is not signed in — skipping DSIO harness download"
  fi
fi
if (( FETCH )) && ! gh repo view "$REPO" >/dev/null 2>&1; then
  FETCH=0; skip_msg "this GitHub account has no access to $REPO — skipping DSIO harness download"
fi

if (( ! FETCH )) && [[ ! -d "$DEST/dist" ]]; then
  echo "  DSIO harness not installed; continuing without it."
  exit 0
fi

if (( FETCH )); then
  if [[ -d "$DEST/.git" ]]; then
    echo "  updating $DEST"
    if [[ -n "$DSIO_REF" ]]; then
      git -C "$DEST" fetch -q --tags origin
      git -C "$DEST" checkout -q --detach "$DSIO_REF"
    else
      git -C "$DEST" pull -q --ff-only || {
        echo "  (fast-forward failed; leaving local changes in place)"
      }
    fi
  else
    echo "  cloning $REPO to $DEST"
    gh repo clone "$REPO" "$DEST"
    if [[ -n "$DSIO_REF" ]]; then
      git -C "$DEST" checkout -q --detach "$DSIO_REF"
    fi
  fi

  pushd "$DEST" >/dev/null
  # Lockfile-exact install with dependency lifecycle scripts disabled: the
  # build (tsc + a local stamp script) does not need them.
  if [[ -f package-lock.json ]]; then
    echo "  npm ci --ignore-scripts"
    npm ci --ignore-scripts --no-audit --no-fund >/dev/null
  else
    echo "  npm install --ignore-scripts"
    npm install --ignore-scripts --no-audit --no-fund >/dev/null
  fi
  echo "  npm run build"
  npm run build >/dev/null
  [[ -f .env ]] || cp .env.example .env
  popd >/dev/null
else
  echo "  using the existing DSIO build in $DEST (no GitHub access; not updating)"
fi

# `dsio` on PATH — user scope, so no sudo needed.
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/dsio" <<EOF
#!/usr/bin/env bash
exec node --no-warnings "$DEST/dist/src/dsio/index.js" "\$@"
EOF
chmod +x "$HOME/.local/bin/dsio"

# Register the DSIO MCP server with Claude Code at user scope. Remove any
# previous entry first so this is idempotent.
if command -v claude >/dev/null 2>&1; then
  claude mcp remove dsio -s user >/dev/null 2>&1 || true
  claude mcp add --scope user dsio -- node --no-warnings "$DEST/dist/src/cli/index.js" serve >/dev/null
  echo "  Claude Code MCP server 'dsio' registered (user scope)"
else
  echo "  claude CLI not on PATH — skipping MCP registration (install Claude Code first)"
fi

echo "  DSIO harness ready. In any terminal: dsio"
