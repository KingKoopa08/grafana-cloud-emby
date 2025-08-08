#!/bin/bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORTERS_DIR="$(dirname "$SCRIPT_DIR")/exporters"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"

echo -e "${BLUE}Setting up Emby Exporter...${NC}"

# Check Python installation
if ! command -v python3 &> /dev/null; then
    echo "Python 3 is not installed. Installing..."
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip python3-venv
fi

# Create virtual environment
VENV_DIR="/opt/emby-exporter/venv"
echo "Creating Python virtual environment..."
sudo mkdir -p /opt/emby-exporter
sudo python3 -m venv "$VENV_DIR"

# Install Python dependencies
echo "Installing Python dependencies..."
sudo "$VENV_DIR/bin/pip" install --upgrade pip
sudo "$VENV_DIR/bin/pip" install -r "$EXPORTERS_DIR/requirements.txt"

# Copy exporter script
echo "Installing exporter script..."
sudo cp "$EXPORTERS_DIR/emby_exporter.py" /opt/emby-exporter/
sudo chmod +x /opt/emby-exporter/emby_exporter.py

# Create user for exporter
if ! id -u emby-exporter &>/dev/null; then
    echo "Creating emby-exporter user..."
    sudo useradd --system --no-create-home --shell /bin/false emby-exporter
fi

# Set permissions
sudo chown -R emby-exporter:emby-exporter /opt/emby-exporter

# Load configuration for environment variables
if [ -f "${CONFIG_DIR}/config.env" ]; then
    source "${CONFIG_DIR}/config.env"
fi

# Create systemd service
echo "Creating systemd service..."
sudo tee /etc/systemd/system/emby-exporter.service > /dev/null <<EOF
[Unit]
Description=Emby Prometheus Exporter
Documentation=https://github.com/yourusername/grafana-cloud-emby
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=emby-exporter
Group=emby-exporter
Environment="EMBY_SERVER_URL=${EMBY_SERVER_URL:-http://localhost:8096}"
Environment="EMBY_API_KEY=${EMBY_API_KEY}"
Environment="EXPORTER_PORT=9119"
Environment="SCRAPE_INTERVAL=30"
ExecStart=${VENV_DIR}/bin/python3 /opt/emby-exporter/emby_exporter.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=emby-exporter

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# Enable and start the service
echo "Enabling Emby exporter service..."
sudo systemctl enable emby-exporter

# Start the service if API key is configured
if [ -n "${EMBY_API_KEY:-}" ]; then
    echo "Starting Emby exporter service..."
    sudo systemctl restart emby-exporter
    
    # Wait for service to start
    sleep 3
    
    # Check if service is running
    if systemctl is-active --quiet emby-exporter; then
        echo -e "${GREEN}Emby exporter is running!${NC}"
        
        # Test metrics endpoint
        if curl -s http://localhost:9119/metrics > /dev/null 2>&1; then
            echo -e "${GREEN}Metrics endpoint is accessible at http://localhost:9119/metrics${NC}"
        else
            echo -e "${RED}Warning: Metrics endpoint is not responding${NC}"
        fi
    else
        echo -e "${RED}Emby exporter failed to start. Check logs with: sudo journalctl -u emby-exporter -n 50${NC}"
    fi
else
    echo -e "${BLUE}Emby exporter service created but not started (API key not configured)${NC}"
fi

echo -e "${GREEN}Emby exporter setup completed!${NC}"