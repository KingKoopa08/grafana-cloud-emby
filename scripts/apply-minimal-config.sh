#!/bin/bash

# Apply minimal agent configuration to drastically reduce metrics costs

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  APPLY MINIMAL METRICS CONFIGURATION${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${RED}WARNING: This will reduce metrics from ~12,000 to ~300 series!${NC}"
echo ""
echo "You will KEEP:"
echo "  ✓ All Emby Live TV metrics (239 series)"
echo "  ✓ Basic server metrics (CPU, Memory, Disk, Network)"
echo ""
echo "You will LOSE:"
echo "  ✗ Grafana internal metrics (3063 series)"
echo "  ✗ Loki internal metrics (3011 series)"
echo "  ✗ Detailed node metrics (3344 → ~50 series)"
echo "  ✗ Prometheus internal metrics (1077 series)"
echo "  ✗ Tempo metrics (793 series)"
echo "  ✗ Agent metrics (426 series)"
echo ""
echo -e "${GREEN}This will save you ~97% on metrics costs!${NC}"
echo ""

read -p "Do you want to apply the minimal configuration? (y/n): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}1. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Backup created: agent.yaml.backup.$TIMESTAMP"

echo ""
echo -e "${BLUE}2. LOADING CONFIGURATION${NC}"
echo "────────────────────────────────"

source /opt/grafana-cloud-emby/config/config.env
echo -e "${GREEN}✓${NC} Configuration loaded"

echo ""
echo -e "${BLUE}3. APPLYING MINIMAL CONFIG${NC}"
echo "────────────────────────────────"

# Copy minimal config
sudo cp /opt/grafana-cloud-emby/config/agent-minimal.yaml /etc/grafana-agent/agent.yaml

# Replace variables
sudo sed -i "s/\${GRAFANA_CLOUD_USER}/$GRAFANA_CLOUD_USER/g" /etc/grafana-agent/agent.yaml
sudo sed -i "s/\${GRAFANA_CLOUD_API_KEY}/$GRAFANA_CLOUD_API_KEY/g" /etc/grafana-agent/agent.yaml
sudo sed -i "s/\${GRAFANA_CLOUD_LOGS_API_KEY}/${GRAFANA_CLOUD_LOGS_API_KEY:-$GRAFANA_CLOUD_API_KEY}/g" /etc/grafana-agent/agent.yaml

echo -e "${GREEN}✓${NC} Minimal configuration applied"

echo ""
echo -e "${BLUE}4. RESTARTING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Agent restarted successfully"
else
    echo -e "${RED}✗${NC} Agent failed to start"
    echo "Reverting to backup..."
    sudo cp "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" /etc/grafana-agent/agent.yaml
    sudo systemctl restart grafana-agent
    exit 1
fi

echo ""
echo -e "${BLUE}5. VERIFYING METRICS${NC}"
echo "────────────────────────────────"

sleep 10

# Test if metrics are being scraped
echo "Testing Emby metrics..."
if curl -s http://localhost:9119/metrics | grep -q "emby_livetv"; then
    echo -e "${GREEN}✓${NC} Emby metrics available"
else
    echo -e "${YELLOW}⚠${NC} Emby metrics not responding"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}SUCCESS!${NC} Minimal configuration is now active."
echo ""
echo "What you have now:"
echo "• All Emby Live TV metrics (for your dashboard)"
echo "• CPU load averages (1, 5, 15 minute)"
echo "• Memory usage (total, free, available)"
echo "• Disk space (root filesystem only)"
echo "• Network traffic (main interface only)"
echo "• System uptime"
echo ""
echo "Your metrics usage should drop by ~97% within the next hour!"
echo ""
echo "Monitor your savings at:"
echo "https://grafana.com/orgs/kingkoopa08/billing/usage"
echo ""
echo "If you need to revert:"
echo "sudo cp /etc/grafana-agent/agent.yaml.backup.$TIMESTAMP /etc/grafana-agent/agent.yaml"
echo "sudo systemctl restart grafana-agent"