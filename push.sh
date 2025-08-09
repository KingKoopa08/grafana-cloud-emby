#!/bin/bash

# Safe git push with token
set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}Git Push Helper${NC}"
echo "================="

# Load token from .env.local if it exists
if [ -f .env.local ]; then
    source .env.local
    echo -e "${GREEN}✓ Token loaded from .env.local${NC}"
else
    echo -e "${YELLOW}No .env.local file found${NC}"
    echo "Enter your GitHub token (ghp_...):"
    read -s GITHUB_TOKEN
    echo ""
    
    # Offer to save it
    echo "Save token for future use? (y/n)"
    read -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "GITHUB_TOKEN=$GITHUB_TOKEN" > .env.local
        echo -e "${GREEN}✓ Token saved to .env.local${NC}"
    fi
fi

# Check for changes
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${BLUE}You have uncommitted changes:${NC}"
    git status --short
    echo ""
    echo "Commit these changes? (y/n)"
    read -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Enter commit message:"
        read COMMIT_MSG
        git add -A
        git commit -m "$COMMIT_MSG"
    fi
fi

# Push with token
echo -e "${BLUE}Pushing to GitHub...${NC}"
git push https://${GITHUB_TOKEN}@github.com/KingKoopa08/grafana-cloud-emby.git main

echo -e "${GREEN}✓ Push successful!${NC}"
echo ""
echo "Repository: https://github.com/KingKoopa08/grafana-cloud-emby"