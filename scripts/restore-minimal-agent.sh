#!/bin/bash

# Restore Grafana Agent to minimal working configuration
# This uses the exact config that was working before

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
echo -e "${CYAN}  RESTORE MINIMAL AGENT CONFIG${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

echo ""
echo -e "${BLUE}1. STOPPING AGENT${NC}"
echo "────────────────────────────────"

# Stop the agent to prevent restart loops
sudo systemctl stop grafana-agent 2>/dev/null || true
echo -e "${GREEN}✓${NC} Agent stopped"

echo ""
echo -e "${BLUE}2. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [ -f /etc/grafana-agent/agent.yaml ]; then
    sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP.broken"
    echo -e "${GREEN}✓${NC} Backed up broken config"
fi

echo ""
echo -e "${BLUE}3. CREATING MINIMAL WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Create the absolute minimal config that was working
cat > /tmp/agent-minimal.yaml <<EOF
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
          
        # Node exporter
        - job_name: node
          static_configs:
            - targets: ['localhost:9100']
          scrape_interval: 60s

integrations:
  agent:
    enabled: true
EOF

echo -e "${GREEN}✓${NC} Minimal configuration created"

echo ""
echo -e "${BLUE}4. APPLYING CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-minimal.yaml /etc/grafana-agent/agent.yaml
sudo chown root:root /etc/grafana-agent/agent.yaml
sudo chmod 644 /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}5. FIXING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure working directory exists
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent

# Clear any old WAL data
sudo rm -rf /var/lib/grafana-agent/data-agent 2>/dev/null || true
sudo rm -rf /var/lib/grafana-agent/wal 2>/dev/null || true

echo -e "${GREEN}✓${NC} Permissions fixed"

echo ""
echo -e "${BLUE}6. STARTING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl start grafana-agent
sleep 3

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent started successfully!"
else
    echo -e "${RED}✗${NC} Failed to start agent"
    echo ""
    echo "Checking logs..."
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}7. VERIFYING OPERATION${NC}"
echo "────────────────────────────────"

# Wait for agent to initialize
sleep 5

# Check if metrics endpoint is available
if curl -s -o /dev/null -w "%{http_code}" http://localhost:12345/metrics 2>/dev/null | grep -q "200"; then
    echo -e "${GREEN}✓${NC} Agent metrics endpoint is accessible"
    
    # Check for scrape targets
    METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null || echo "")
    if echo "$METRICS" | grep -q 'up{.*job="emby"'; then
        UP_VALUE=$(echo "$METRICS" | grep 'up{.*job="emby"' | grep -oE '[0-9]+$' | head -1)
        if [ "$UP_VALUE" = "1" ]; then
            echo -e "${GREEN}✓${NC} Emby exporter is UP and being scraped"
        else
            echo -e "${YELLOW}⚠${NC} Emby exporter is DOWN"
        fi
    fi
else
    echo -e "${YELLOW}⚠${NC} Agent metrics endpoint not ready yet"
fi

# Check Emby exporter directly
if curl -s http://localhost:9119/metrics | grep -q "emby_livetv"; then
    METRIC_COUNT=$(curl -s http://localhost:9119/metrics | grep -c "emby_livetv" || echo "0")
    echo -e "${GREEN}✓${NC} Emby exporter has $METRIC_COUNT Live TV metrics"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  AGENT RESTORED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Success!${NC} The agent is running with minimal configuration."
echo ""
echo "Current setup:"
echo "• Scraping Emby exporter on port 9119"
echo "• Scraping Node exporter on port 9100"  
echo "• Sending metrics to Grafana Cloud"
echo "• Your Emby dashboards should be working again"
echo ""
echo -e "${YELLOW}NFL Monitoring:${NC}"
echo "The NFL monitoring requires:"
echo "1. NFL updater service to be installed"
echo "2. Compatible Grafana Agent version with logs support"
echo "3. The dashboard can still be imported for future use"
echo ""
echo -e "${CYAN}Commands:${NC}"
echo "• Check status: sudo systemctl status grafana-agent"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• View config: cat /etc/grafana-agent/agent.yaml"
echo "• Test metrics: curl http://localhost:12345/metrics | grep up"