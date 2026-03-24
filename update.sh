#!/usr/bin/env bash
#
# Self-update Careless Whisper from git remote.
# Preserves whisper-stt.conf, models, and history.
# Safe to run at any time — does not re-ask for hotkeys or config.
#
# Usage: ./update.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELATIVE_PATH="${ROOT_DIR#${HOME}/}"

echo "==> Careless Whisper — Self-Update"
echo "    Root: ${ROOT_DIR}"
echo

# ── Pre-flight checks ────────────────────────────────────────────────────────

if [ ! -d "${ROOT_DIR}/.git" ]; then
    echo "ERROR: Not a git repository. Self-update requires a git clone."
    echo "       Re-install with: git clone <repo-url> && cd Careless-Whisper && ./install.sh"
    exit 1
fi

LOCAL_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 'unknown')"
echo "    Current version: ${LOCAL_VERSION}"

# ── Fetch + Pull ──────────────────────────────────────────────────────────────

echo "==> Fetching latest changes..."
git -C "${ROOT_DIR}" fetch origin 2>/dev/null

# Determine default branch
DEFAULT_BRANCH="$(git -C "${ROOT_DIR}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo 'main')"

# Check if we're behind
LOCAL_HASH="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null)"
REMOTE_HASH="$(git -C "${ROOT_DIR}" rev-parse "origin/${DEFAULT_BRANCH}" 2>/dev/null)"

if [ "${LOCAL_HASH}" = "${REMOTE_HASH}" ]; then
    echo "    Already up to date (${LOCAL_VERSION})."
    exit 0
fi

echo "==> Pulling changes from origin/${DEFAULT_BRANCH}..."

# Stash any tracked file changes (whisper-stt.conf is gitignored, so safe)
STASHED=false
if ! git -C "${ROOT_DIR}" diff --quiet 2>/dev/null; then
    git -C "${ROOT_DIR}" stash push -m "careless-whisper-update-$(date +%s)" 2>/dev/null
    STASHED=true
    echo "    Stashed local changes"
fi

# Pull
if ! git -C "${ROOT_DIR}" pull --ff-only origin "${DEFAULT_BRANCH}" 2>/dev/null; then
    echo "WARN: Fast-forward failed — trying rebase..."
    git -C "${ROOT_DIR}" pull --rebase origin "${DEFAULT_BRANCH}" 2>/dev/null || {
        echo "ERROR: Could not merge changes. Resolve manually with:"
        echo "       cd ${ROOT_DIR} && git pull"
        if [ "${STASHED}" = true ]; then
            git -C "${ROOT_DIR}" stash pop 2>/dev/null || true
        fi
        exit 1
    }
fi

# Pop stash if we stashed
if [ "${STASHED}" = true ]; then
    git -C "${ROOT_DIR}" stash pop 2>/dev/null || {
        echo "WARN: Could not auto-restore stashed changes."
        echo "      Run: cd ${ROOT_DIR} && git stash pop"
    }
fi

# ── Post-update fixes ────────────────────────────────────────────────────────

NEW_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 'unknown')"
echo "    Updated: ${LOCAL_VERSION} → ${NEW_VERSION}"

# Re-patch whisper_hotkeys.lua with correct paths
if [[ "${RELATIVE_PATH}" != /* ]]; then
    sed -i '' "s|local whisper_script = .*|local whisper_script = home .. \"/${RELATIVE_PATH}/whisper.sh\"|" "${ROOT_DIR}/whisper_hotkeys.lua" 2>/dev/null || true
    sed -i '' "s|local conf_file      = .*|local conf_file      = home .. \"/${RELATIVE_PATH}/whisper-stt.conf\"|" "${ROOT_DIR}/whisper_hotkeys.lua" 2>/dev/null || true
    echo "==> Re-patched whisper_hotkeys.lua"
fi

# Ensure scripts are executable
chmod +x "${ROOT_DIR}/whisper.sh" "${ROOT_DIR}/install.sh" "${ROOT_DIR}/update.sh" "${ROOT_DIR}/uninstall.sh" 2>/dev/null || true

# ── Reload Hammerspoon ────────────────────────────────────────────────────────

echo "==> Reloading Hammerspoon..."
if command -v hs >/dev/null 2>&1; then
    hs -c 'hs.reload()' 2>/dev/null && echo "    Hammerspoon reloaded." || echo "    Could not reload (Hammerspoon CLI not connected)."
else
    echo "    hs CLI not available. Reload Hammerspoon manually (menubar → Reload Config)."
fi

echo
echo "==> Update complete: ${LOCAL_VERSION} → ${NEW_VERSION}"
