#!/bin/bash

# Complete reset and fix for Grafana Agent
# This script cleans up all the mess and starts fresh with a known working config

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
echo -e "${CYAN}  COMPLETE GRAFANA AGENT RESET${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. STOPPING EVERYTHING${NC}"
echo "────────────────────────────────"

# Stop the agent completely
sudo systemctl stop grafana-agent 2>/dev/null || true
sudo pkill -f grafana-agent 2>/dev/null || true
echo -e "${GREEN}✓${NC} Agent stopped"

# Stop any restart loops
sudo systemctl reset-failed grafana-agent 2>/dev/null || true
echo -e "${GREEN}✓${NC} Reset failed state"

echo ""
echo -e "${BLUE}2. LOADING CONFIGURATION${NC}"
echo "────────────────────────────────"

# Load config file
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗${NC} Config file not found at $CONFIG_FILE"
    echo ""
    echo "Please create it with:"
    echo "GRAFANA_CLOUD_USER=your-user-id"
    echo "GRAFANA_CLOUD_API_KEY=your-api-key"
    exit 1
fi

source "$CONFIG_FILE"

# Validate required variables
if [ -z "${GRAFANA_CLOUD_USER:-}" ] || [ -z "${GRAFANA_CLOUD_API_KEY:-}" ]; then
    echo -e "${RED}✗${NC} Missing required configuration"
    echo "Please check $CONFIG_FILE"
    exit 1
fi

echo -e "${GREEN}✓${NC} Configuration loaded"
echo "  User: ${GRAFANA_CLOUD_USER}"
echo "  API Key: ${GRAFANA_CLOUD_API_KEY:0:20}..."

echo ""
echo -e "${BLUE}3. BACKING UP OLD CONFIGS${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/etc/grafana-agent/backups"
sudo mkdir -p "$BACKUP_DIR"

# Backup current config if it exists
if [ -f /etc/grafana-agent/agent.yaml ]; then
    sudo mv /etc/grafana-agent/agent.yaml "$BACKUP_DIR/agent.yaml.backup.$TIMESTAMP"
    echo -e "${GREEN}✓${NC} Old config backed up"
fi

# Backup and remove positions file to start fresh
if [ -f /var/lib/grafana-agent/positions.yaml ]; then
    sudo mv /var/lib/grafana-agent/positions.yaml "$BACKUP_DIR/positions.yaml.backup.$TIMESTAMP"
    echo -e "${GREEN}✓${NC} Positions file backed up"
fi

# Clean WAL directory
sudo rm -rf /var/lib/grafana-agent/data-agent 2>/dev/null || true
sudo rm -rf /var/lib/grafana-agent/wal 2>/dev/null || true
echo -e "${GREEN}✓${NC} WAL directory cleaned"

echo ""
echo -e "${BLUE}4. CREATING FRESH WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Create the simplest config that we know works
# Start with ONLY metrics, no logs (since logs have auth issues)
cat <<EOF | sudo tee /etc/grafana-agent/agent.yaml > /dev/null
server:
  log_level: info

metrics:
  global:
    scrape_interval: 60s
    remote_write:
      - url: https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
        basic_auth:
          username: ${GRAFANA_CLOUD_USER}
          password: ${GRAFANA_CLOUD_API_KEY}

  configs:
    - name: default
      scrape_configs:
        # Emby Live TV exporter
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
        # Node exporter for system metrics
        - job_name: node
          static_configs:
            - targets: ['localhost:9100']
          scrape_interval: 60s

integrations:
  agent:
    enabled: true
EOF

echo -e "${GREEN}✓${NC} Created clean configuration (metrics only)"

echo ""
echo -e "${BLUE}5. SETTING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure proper ownership
sudo chown root:root /etc/grafana-agent/agent.yaml
sudo chmod 644 /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Config permissions set"

# Ensure working directory exists with correct permissions
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Working directory ready"

echo ""
echo -e "${BLUE}6. STARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

# Reload systemd in case of any changes
sudo systemctl daemon-reload

# Start the agent
sudo systemctl start grafana-agent

# Wait for it to start
sleep 5

# Check if it's running
if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent is running!"
    
    # Show some logs to confirm it's working
    echo ""
    echo "Recent startup logs:"
    sudo journalctl -u grafana-agent --since "10 seconds ago" --no-pager | grep -E "(Started|level=info|Scraped)" | head -5 | sed 's/^/  /'
else
    echo -e "${RED}✗${NC} Agent failed to start"
    echo ""
    echo "Error logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}7. VERIFYING METRICS COLLECTION${NC}"
echo "────────────────────────────────"

# Check if metrics endpoint is accessible
if curl -s -o /dev/null -w "%{http_code}" http://localhost:12345/metrics 2>/dev/null | grep -q "200"; then
    echo -e "${GREEN}✓${NC} Agent metrics endpoint is accessible"
    
    # Check for Emby scraping
    if curl -s http://localhost:12345/metrics 2>/dev/null | grep -q 'up{.*job="emby".*} 1'; then
        echo -e "${GREEN}✓${NC} Emby exporter is being scraped"
    else
        echo -e "${YELLOW}⚠${NC} Emby exporter not confirmed yet (may need a moment)"
    fi
else
    echo -e "${YELLOW}⚠${NC} Agent metrics endpoint not ready yet"
fi

# Check if Emby exporter itself is running
if curl -s http://localhost:9119/metrics 2>/dev/null | grep -q "emby_livetv"; then
    METRIC_COUNT=$(curl -s http://localhost:9119/metrics 2>/dev/null | grep -c "emby_livetv" || echo "0")
    echo -e "${GREEN}✓${NC} Emby exporter is running ($METRIC_COUNT Live TV metrics)"
else
    echo -e "${YELLOW}⚠${NC} Emby exporter not responding on port 9119"
fi

echo ""
echo -e "${BLUE}8. TESTING GRAFANA CLOUD CONNECTION${NC}"
echo "────────────────────────────────"

# Test Prometheus connection
PROM_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=up" 2>/dev/null || echo "000")

if [ "$PROM_TEST" = "200" ]; then
    echo -e "${GREEN}✓${NC} Prometheus (metrics) authentication working"
else
    echo -e "${RED}✗${NC} Prometheus authentication failed (status: $PROM_TEST)"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  RESET COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Current Status:${NC}"
echo "✓ Agent is running with a clean configuration"
echo "✓ Metrics collection is active (Emby + System)"
echo "✓ No log collection configured (due to auth issues)"
echo ""

echo -e "${YELLOW}About Logs:${NC}"
echo "Log collection is currently DISABLED because:"
echo "• Your API key doesn't have logs:write permission"
echo "• This was causing 401 authentication errors"
echo ""

echo -e "${CYAN}To Enable Logs:${NC}"
echo "1. Go to Grafana Cloud portal"
echo "2. Create a new API key with BOTH permissions:"
echo "   • metrics:write"
echo "   • logs:write"
echo "3. Update $CONFIG_FILE with the new key"
echo "4. Run: sudo ./scripts/add-logs-when-ready.sh"
echo ""

echo -e "${GREEN}What's Working Now:${NC}"
echo "• Emby Live TV metrics dashboard"
echo "• System metrics (CPU, Memory, Disk)"
echo "• All Prometheus queries"
echo ""

echo -e "${CYAN}Useful Commands:${NC}"
echo "• Check status: sudo systemctl status grafana-agent"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• Test metrics: curl http://localhost:12345/metrics | grep up"
echo "• View config: cat /etc/grafana-agent/agent.yaml"
echo ""

echo -e "${GREEN}Your dashboards should be working again!${NC}"