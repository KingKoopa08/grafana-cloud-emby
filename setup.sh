#!/bin/bash

# One-liner installation script that can be run directly from GitHub
# Usage: curl -sSL https://raw.githubusercontent.com/KingKoopa08/grafana-cloud-emby/main/setup.sh | bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
GITHUB_REPO="https://github.com/KingKoopa08/grafana-cloud-emby.git"
INSTALL_DIR="/opt/grafana-cloud-emby"
BRANCH="main"

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root. It will use sudo when needed."
   exit 1
fi

# Check prerequisites
print_status "Checking prerequisites..."

# Install git if not present
if ! command -v git &> /dev/null; then
    print_status "Installing git..."
    sudo apt-get update
    sudo apt-get install -y git
fi

# Clone or update repository
if [ -d "$INSTALL_DIR" ]; then
    print_warning "Installation directory already exists: $INSTALL_DIR"
    read -p "Do you want to remove it and reinstall? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Removing existing installation..."
        sudo rm -rf "$INSTALL_DIR"
    else
        print_status "Updating existing installation..."
        cd "$INSTALL_DIR"
        git pull origin "$BRANCH"
        print_success "Repository updated"
        cd "$INSTALL_DIR"
        ./deploy.sh
        exit 0
    fi
fi

# Clone repository
print_status "Cloning repository from GitHub..."
sudo git clone -b "$BRANCH" "$GITHUB_REPO" "$INSTALL_DIR"

# Change ownership to current user
sudo chown -R "$USER:$USER" "$INSTALL_DIR"

# Change to installation directory
cd "$INSTALL_DIR"

print_success "Repository cloned successfully to $INSTALL_DIR"
echo ""
print_status "Starting deployment..."
echo ""

# Make scripts executable
chmod +x deploy.sh update.sh scripts/*.sh

# Run deployment
./deploy.sh

print_success "Setup complete!"
echo ""
echo "Repository location: $INSTALL_DIR"
echo ""
echo "To update in the future, run:"
echo "  cd $INSTALL_DIR"
echo "  ./update.sh"
echo ""
echo "Or to redeploy everything:"
echo "  cd $INSTALL_DIR"
echo "  ./deploy.sh"