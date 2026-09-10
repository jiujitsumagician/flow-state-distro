#!/usr/bin/env bash
# 03 — DSIO agent harness. Clone → build → shim on PATH → register MCP.
set -euo pipefail

DEST="$HOME/dsio-harness"
REPO="jiujitsumagician/dsio"

# gh must be authenticated to reach the private repo. If not, prompt the user
# to log in (browser flow) once; the shell inherits the session cookie.
if ! gh auth status >/dev/null 2>&1; then
  echo "  gh is not signed in — starting browser login (approve the device code)"
  gh auth login --hostname github.com --web --git-protocol https --scopes repo
fi

if [[ -d "$DEST/.git" ]]; then
  echo "  updating $DEST"
  git -C "$DEST" pull -q --ff-only || {
    echo "  (fast-forward failed; leaving local changes in place)"
  }
else
  echo "  cloning $REPO to $DEST"
  gh repo clone "$REPO" "$DEST"
fi

pushd "$DEST" >/dev/null
echo "  npm install"
npm install --no-audit --no-fund >/dev/null
echo "  npm run build"
npm run build >/dev/null
[[ -f .env ]] || cp .env.example .env
popd >/dev/null

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
