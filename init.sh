#!/usr/bin/env bash
#
# init.sh -- Bootstrap code-factory: symlink configs and install Claude Code assets globally.
#
# This script:
#   1. Checks for Node.js (required by statusLine npx command).
#   2. Symlinks configuration files into the user's home directory.
#   3. Installs MCP servers from mcp.json into Claude Code (user scope).
#   4. Symlinks Claude Code hooks and rules.
#   5. Updates Claude Code CLI and all installed marketplace plugins.
#
# Behavior:
#   - If the destination is an existing symlink, it is removed and re-created.
#   - If the destination is a regular file with identical content, it is replaced.
#   - If the destination is a regular file with different content, it is backed up as .bak.
#   - If the destination does not exist, the symlink is created.
#   - Parent directories are created as needed.
#   - The script exits non-zero if any file fails to link, with a summary at the end.
#
# This script is idempotent: running it multiple times produces the same result.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

errors=()

# Source local node env if previously installed (mirrors cargo env pattern)
if [[ -f "$HOME/.local/node/env" ]]; then
    . "$HOME/.local/node/env"
fi

# Check for Node.js (required by statusLine npx command)
echo "Checking Node.js installation..."
if command -v node &>/dev/null; then
    echo "  OK  node already installed ($(node --version))"
else
    case "$(uname -s)" in
        Linux)
            echo "  Installing Node.js..."
            ARCH=$(uname -m)
            NODE_ARCH=""
            case "$ARCH" in
                x86_64)  NODE_ARCH="x64" ;;
                aarch64) NODE_ARCH="arm64" ;;
                *)
                    errors+=("node: unsupported architecture $ARCH")
                    echo "  FAIL  unsupported architecture $ARCH"
                    ;;
            esac
            if [[ -n "$NODE_ARCH" ]]; then
                NODE_VERSION="v22.14.0"
                NODE_DIST="node-${NODE_VERSION}-linux-${NODE_ARCH}"
                TMP_DIR=$(mktemp -d)
                if curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${NODE_DIST}.tar.xz" -o "$TMP_DIR/node.tar.xz"; then
                    tar -xJf "$TMP_DIR/node.tar.xz" -C "$TMP_DIR"
                    rm -rf "$HOME/.local/node"
                    mv "$TMP_DIR/$NODE_DIST" "$HOME/.local/node"
                    cat > "$HOME/.local/node/env" << 'NODEENV'
# Node.js environment (installed by code-factory init.sh)
case ":${PATH}:" in
    *":$HOME/.local/node/bin:"*) ;;
    *) export PATH="$HOME/.local/node/bin:$PATH" ;;
esac
NODEENV
                    . "$HOME/.local/node/env"
                    for profile in "$HOME/.bashrc" "$HOME/.profile"; do
                        if [[ -f "$profile" ]] && ! grep -q '.local/node/env' "$profile"; then
                            printf '\n# Node.js (installed by code-factory)\n[ -f "$HOME/.local/node/env" ] && . "$HOME/.local/node/env"\n' >> "$profile"
                        fi
                    done
                    echo "  OK  node installed ($(node --version))"
                else
                    errors+=("node: download failed")
                    echo "  FAIL  node download failed"
                fi
                rm -rf "$TMP_DIR"
            fi
            ;;
        *)
            echo "  SKIP  node not found, install manually from https://nodejs.org"
            ;;
    esac
fi
echo ""

# Build list of files to symlink
SRCS=("$SCRIPT_DIR/settings.json")
DESTS=("$HOME/.claude/settings.json")

# Add CLAUDE.md if present in the repo
if [[ -f "$SCRIPT_DIR/CLAUDE.md" ]]; then
    SRCS+=("$SCRIPT_DIR/CLAUDE.md")
    DESTS+=("$HOME/.claude/CLAUDE.md")
fi

# In workspace mode, force-remove settings.json so linking always succeeds
# (workspaces may have a pre-existing regular file instead of a symlink)
if [[ "${IN_WORKSPACE:-}" == "1" ]]; then
    rm -f "$HOME/.claude/settings.json"
fi

for i in "${!SRCS[@]}"; do
    src="${SRCS[$i]}"
    dest="${DESTS[$i]}"

    if [[ ! -f "$src" ]]; then
        errors+=("$src -> $dest: source file not found")
        echo "FAIL  $src (source file not found)"
        continue
    fi

    mkdir -p "$(dirname "$dest")"

    if [[ -L "$dest" ]]; then
        rm "$dest"
    elif [[ -f "$dest" && ! -s "$dest" ]]; then
        # Empty stub — safe to replace
        rm "$dest"
    elif [[ -f "$dest" ]] && cmp -s "$dest" "$src"; then
        # Regular file with identical content — safe to replace with a symlink
        rm "$dest"
    elif [[ -f "$dest" ]]; then
        # Regular file with different content — back up before erroring
        backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        if mv "$dest" "$backup"; then
            errors+=("$src -> $dest: dest differed from source; backed up to $backup")
            echo "FAIL  $dest differed from source, backed up to $backup — reconcile manually then re-run"
        else
            errors+=("$src -> $dest: dest differed from source and backup failed")
            echo "FAIL  could not back up $dest, skipping"
        fi
        continue
    elif [[ -e "$dest" ]]; then
        errors+=("$src -> $dest: destination already exists (not a regular file)")
        echo "FAIL  $dest already exists and is not a regular file, cannot link"
        continue
    fi

    if ! ln -s "$src" "$dest"; then
        errors+=("$src -> $dest: ln -s failed")
        echo "FAIL  could not link $dest -> $src"
        continue
    fi
    echo "LINK  $dest -> $src"
done

# Install MCP servers from mcp.json into Claude Code (user scope)
echo ""
echo "Installing MCP servers into Claude Code (user scope)..."

# Clean up stale ~/.mcp.json symlink from old approach
if [[ -L "$HOME/.mcp.json" ]]; then
    rm "$HOME/.mcp.json"
    echo "  Removed stale ~/.mcp.json symlink"
fi

if [[ -f "$SCRIPT_DIR/mcp.json" ]]; then
    mcp_server_names=$(python3 -c "
import json
data = json.load(open('$SCRIPT_DIR/mcp.json'))
for name in data.get('mcpServers', {}):
    print(name)
")
    for name in $mcp_server_names; do
        config=$(python3 -c "
import json
data = json.load(open('$SCRIPT_DIR/mcp.json'))
print(json.dumps(data['mcpServers']['$name']))
")
        claude mcp remove "$name" 2>/dev/null || true
        if claude mcp add-json -s user "$name" "$config" 2>&1; then
            echo "  OK  $name"
        else
            errors+=("mcp: failed to install $name")
            echo "  FAIL  $name"
        fi
    done
else
    echo "  SKIP  mcp.json not found"
fi

# Symlink Claude Code hooks from hooks/ into ~/.claude/hooks/
echo ""
echo "Linking Claude Code hooks..."
HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"
for hook_src in "$SCRIPT_DIR/hooks"/*; do
    [[ -f "$hook_src" ]] || continue
    hook_name=$(basename "$hook_src")
    hook_dest="$HOOKS_DIR/$hook_name"
    if [[ -L "$hook_dest" ]]; then
        rm "$hook_dest"
    elif [[ -e "$hook_dest" ]]; then
        errors+=("$hook_src -> $hook_dest: destination already exists as a regular file")
        echo "  FAIL  $hook_dest already exists as a regular file, cannot link"
        continue
    fi
    if ! ln -s "$hook_src" "$hook_dest"; then
        errors+=("$hook_src -> $hook_dest: ln -s failed")
        echo "  FAIL  could not link $hook_dest -> $hook_src"
    else
        echo "  LINK  $hook_dest -> $hook_src"
    fi
done

# Symlink Claude Code rules from rules/ into ~/.claude/rules/
echo ""
echo "Linking Claude Code rules..."
RULES_DIR="$HOME/.claude/rules"
mkdir -p "$RULES_DIR"
for rule_src in "$SCRIPT_DIR/rules"/*.md; do
    [[ -f "$rule_src" ]] || continue
    rule_name=$(basename "$rule_src")
    rule_dest="$RULES_DIR/$rule_name"
    if [[ -L "$rule_dest" ]]; then
        rm "$rule_dest"
    elif [[ -e "$rule_dest" ]]; then
        errors+=("$rule_src -> $rule_dest: destination already exists as a regular file")
        echo "  FAIL  $rule_dest already exists as a regular file, cannot link"
        continue
    fi
    if ! ln -s "$rule_src" "$rule_dest"; then
        errors+=("$rule_src -> $rule_dest: ln -s failed")
        echo "  FAIL  could not link $rule_dest -> $rule_src"
    else
        echo "  LINK  $rule_dest -> $rule_src"
    fi
done

# In workspace mode, patch settings.json with workspace-specific keys
if [[ "${IN_WORKSPACE:-}" == "1" ]]; then
    settings_file="$HOME/.claude/settings.json"
    if [[ -f "$settings_file" ]]; then
        python3 -c "
import json, os
path = os.path.expanduser('$settings_file')
real = os.path.realpath(path)
with open(real) as f:
    data = json.load(f)
data['apiKeyHelper'] = 'workspace_secret ANTHROPIC_APIKEY1'
data['forceLoginMethod'] = 'console'
with open(real, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
        echo "PATCH  $settings_file (workspace: apiKeyHelper, forceLoginMethod)"
    else
        errors+=("workspace: $settings_file not found after linking, cannot patch")
        echo "FAIL  workspace patch: $settings_file not found"
    fi
fi

# Update Claude Code and marketplace plugins (after all setup is complete)
echo ""
echo "Updating Claude Code and marketplace plugins..."
if command -v claude &>/dev/null; then
    if claude update 2>&1; then
        echo "  OK  claude updated"
    else
        echo "  WARN  claude update failed (may already be up-to-date)"
    fi
    marketplace_repos=$(jq -r '.extraKnownMarketplaces | to_entries[].value.source.repo' "$SCRIPT_DIR/settings.json" 2>/dev/null || true)
    if [[ -n "$marketplace_repos" ]]; then
        while IFS= read -r repo; do
            if claude plugin marketplace add "$repo" 2>&1; then
                echo "  OK  marketplace $repo added"
            else
                echo "  WARN  marketplace $repo add failed (may already exist)"
            fi
        done <<< "$marketplace_repos"
    fi
    enabled_plugins=$(jq -r '.enabledPlugins | keys[]' "$SCRIPT_DIR/settings.json" 2>/dev/null || true)
    if [[ -n "$enabled_plugins" ]]; then
        while IFS= read -r plugin; do
            if claude plugin install "$plugin" 2>&1; then
                echo "  OK  plugin $plugin installed"
            else
                echo "  WARN  plugin $plugin install failed (may already be installed)"
            fi
        done <<< "$enabled_plugins"
    fi
    marketplace_names=$(claude plugin marketplace list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
    if [[ -n "$marketplace_names" ]]; then
        while IFS= read -r marketplace; do
            if claude plugin marketplace update "$marketplace" 2>&1; then
                echo "  OK  marketplace $marketplace updated"
            else
                echo "  WARN  marketplace $marketplace update failed"
            fi
        done <<< "$marketplace_names"
    else
        echo "  No marketplaces installed"
    fi
    installed_plugins=$(claude plugin list --json 2>/dev/null | jq -r '.[].id' 2>/dev/null || true)
    if [[ -n "$installed_plugins" ]]; then
        while IFS= read -r plugin; do
            if claude plugin update "$plugin" 2>&1; then
                echo "  OK  plugin $plugin updated"
            else
                echo "  WARN  plugin $plugin update failed"
            fi
        done <<< "$installed_plugins"
    else
        echo "  No plugins installed"
    fi
else
    echo "  SKIP  claude CLI not found"
fi

# Final error summary
if [[ ${#errors[@]} -gt 0 ]]; then
    echo ""
    echo "========================================="
    echo "ERROR: ${#errors[@]} file(s) failed to link or sync:"
    for err in "${errors[@]}"; do
        echo "  - $err"
    done
    echo "========================================="
    exit 1
fi

echo ""
echo "Done! Claude Code config is live."
