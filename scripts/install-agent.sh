#!/bin/bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}Installing Grafana Agent...${NC}"

# Detect architecture
ARCH=$(dpkg --print-architecture)
echo "Detected architecture: $ARCH"

# Set the Grafana Agent version
AGENT_VERSION="0.39.1"

# Download URL based on architecture
case $ARCH in
    amd64)
        DOWNLOAD_URL="https://github.com/grafana/agent/releases/download/v${AGENT_VERSION}/grafana-agent-${AGENT_VERSION}-1.${ARCH}.deb"
        ;;
    arm64)
        DOWNLOAD_URL="https://github.com/grafana/agent/releases/download/v${AGENT_VERSION}/grafana-agent-${AGENT_VERSION}-1.${ARCH}.deb"
        ;;
    armhf)
        DOWNLOAD_URL="https://github.com/grafana/agent/releases/download/v${AGENT_VERSION}/grafana-agent-${AGENT_VERSION}-1.armv7.deb"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

# Check if Grafana Agent is already installed
if command -v grafana-agent &> /dev/null; then
    INSTALLED_VERSION=$(grafana-agent --version 2>&1 | grep -oP 'v\K[0-9.]+' | head -1)
    echo "Grafana Agent is already installed (version: $INSTALLED_VERSION)"
    
    if [ "$INSTALLED_VERSION" = "$AGENT_VERSION" ]; then
        echo -e "${GREEN}Grafana Agent is already at the target version${NC}"
        exit 0
    else
        echo "Upgrading from $INSTALLED_VERSION to $AGENT_VERSION"
    fi
fi

# Create temporary directory
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# Download Grafana Agent
echo "Downloading Grafana Agent from: $DOWNLOAD_URL"
wget -q --show-progress "$DOWNLOAD_URL" -O grafana-agent.deb

# Install the package
echo "Installing Grafana Agent package..."
sudo dpkg -i grafana-agent.deb || sudo apt-get install -f -y

# Create necessary directories
sudo mkdir -p /etc/grafana-agent
sudo mkdir -p /var/lib/grafana-agent
sudo mkdir -p /var/log/grafana-agent

# Set proper permissions
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/log/grafana-agent

# Clean up
cd /
rm -rf "$TMP_DIR"

# Verify installation
if command -v grafana-agent &> /dev/null; then
    echo -e "${GREEN}Grafana Agent installed successfully!${NC}"
    grafana-agent --version
else
    echo -e "${RED}Grafana Agent installation failed!${NC}"
    exit 1
fi

# Create systemd service if it doesn't exist
if [ ! -f /etc/systemd/system/grafana-agent.service ]; then
    echo "Creating systemd service for Grafana Agent..."
    sudo tee /etc/systemd/system/grafana-agent.service > /dev/null <<EOF
[Unit]
Description=Grafana Agent
Documentation=https://github.com/grafana/agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=grafana-agent
Group=grafana-agent
ExecStart=/usr/bin/grafana-agent \\
  -config.file=/etc/grafana-agent/grafana-agent.yaml \\
  -metrics.wal-directory=/var/lib/grafana-agent/wal
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=grafana-agent
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
fi

echo -e "${GREEN}Grafana Agent installation completed!${NC}"