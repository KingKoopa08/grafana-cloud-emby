#!/bin/bash

# Git push helper script
# This script helps with pushing to GitHub using a token

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check if we have changes to push
if git diff-index --quiet HEAD --; then
    echo -e "${YELLOW}No changes to commit${NC}"
    exit 0
fi

# Get the token from environment or prompt
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo -e "${BLUE}Enter your GitHub Personal Access Token:${NC}"
    read -s GITHUB_TOKEN
    echo ""
fi

# Set the remote URL with token temporarily
CURRENT_REMOTE=$(git remote get-url origin)
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/KingKoopa08/grafana-cloud-emby.git"

# Push changes
echo -e "${BLUE}Pushing to GitHub...${NC}"
git push origin main

# Restore the remote URL without token
git remote set-url origin "https://github.com/KingKoopa08/grafana-cloud-emby.git"

echo -e "${GREEN}Push successful!${NC}"
echo -e "${YELLOW}Note: Token has been removed from git config for security${NC}"