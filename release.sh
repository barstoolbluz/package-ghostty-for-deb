#!/usr/bin/env bash
# release.sh — Build and publish a ghostty .deb for a specific version
#
# Usage:
#   ./release.sh              # Build current pinned version
#   ./release.sh v1.3.1       # Build a specific version
#   ./release.sh latest       # Detect and build the latest stable tag
#
set -euo pipefail

REPO="ghostty-org/ghostty"

# Determine version
if [ "${1:-}" = "latest" ]; then
    VERSION=$(git ls-remote --tags "https://github.com/$REPO.git" \
        | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1)
    TAG="v$VERSION"
    echo "Latest stable: $TAG"
elif [ -n "${1:-}" ]; then
    TAG="$1"
    VERSION="${TAG#v}"
else
    # Use whatever's in flake.nix
    TAG=$(grep 'ghostty.url' flake.nix | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
    VERSION="${TAG#v}"
    echo "Using pinned version: $TAG"
fi

echo "==> Building ghostty $TAG"

# Update the flake input to the target tag
sed -i "s|ghostty.url = \"github:ghostty-org/ghostty/v[^\"]*\"|ghostty.url = \"github:ghostty-org/ghostty/$TAG\"|" flake.nix

# Update flake lock
nix flake update ghostty

# Build
nix build .

# Find the .deb
DEB=$(find result/ -name "*.deb" -type f | head -1)
if [ -z "$DEB" ]; then
    echo "ERROR: No .deb found in result/"
    exit 1
fi

DEB_NAME="ghostty_${VERSION}_amd64.deb"
echo "==> Built: $DEB ($DEB_NAME)"
echo ""

# Ask whether to create a GitHub release
read -rp "Create GitHub release for $TAG? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Commit the version bump if there are changes
    if ! git diff --quiet flake.nix flake.lock; then
        git add flake.nix flake.lock
        git commit -m "Pin ghostty to $TAG"
    fi

    # Tag locally
    git tag -f "$TAG" -m "Ghostty $TAG .deb release"

    # Push
    git push origin main
    git push origin "$TAG" --force

    # Create GitHub release with the .deb attached
    gh release create "$TAG" \
        --title "Ghostty $VERSION" \
        --notes "Ghostty $VERSION packaged as a self-contained \`.deb\` for Debian/Ubuntu (amd64).

## Install

\`\`\`bash
sudo dpkg -i $DEB_NAME
\`\`\`

## What's included
- Ghostty $VERSION binary with bundled GTK4, libadwaita, and all dependencies
- JetBrains Mono font
- Shell integration (bash, zsh, fish, elvish, nushell)
- Desktop entry, icons, man pages, completions
- Uses system glibc and GPU drivers (works with NVIDIA, AMD, Intel)

## Remote hosts
If tmux/byobu fails with \`missing or unsuitable terminal: xterm-ghostty\`, copy the terminfo:
\`\`\`bash
infocmp xterm-ghostty | ssh user@remote 'tic -x -'
\`\`\`" \
        "$DEB#$DEB_NAME"

    echo "==> Release created: https://github.com/$(git remote get-url origin | sed 's|.*github.com[:/]||;s|\.git$||')/releases/tag/$TAG"
else
    echo "==> Skipped. .deb is at: $DEB"
fi
