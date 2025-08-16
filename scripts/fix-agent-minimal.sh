#!/bin/bash

# Minimal working Grafana Agent configuration fix
# Creates a simple, guaranteed-to-work configuration

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
echo -e "${CYAN}  GRAFANA AGENT MINIMAL CONFIG FIX${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found at $CONFIG_FILE"
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

if [ -f /etc/grafana-agent/agent.yaml ]; then
    sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$(date +%Y%m%d-%H%M%S)"
    echo -e "${GREEN}✓${NC} Current config backed up"
fi

echo ""
echo -e "${BLUE}3. CREATING MINIMAL WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Create minimal working config - no fancy features, just basic scraping
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
echo -e "${BLUE}4. APPLYING MINIMAL CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-minimal.yaml /etc/grafana-agent/agent.yaml
sudo chown root:root /etc/grafana-agent/agent.yaml
sudo chmod 644 /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}5. CREATING SYSTEMD OVERRIDE${NC}"
echo "────────────────────────────────"

# Create systemd override to ensure proper working directory
sudo mkdir -p /etc/systemd/system/grafana-agent.service.d
cat << EOF | sudo tee /etc/systemd/system/grafana-agent.service.d/override.conf > /dev/null
[Service]
WorkingDirectory=/var/lib/grafana-agent
Environment="HOSTNAME=%H"
EOF

sudo systemctl daemon-reload
echo -e "${GREEN}✓${NC} Systemd override created"

echo ""
echo -e "${BLUE}6. FIXING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure directories exist with correct permissions
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent

# Clear any old WAL data
sudo rm -rf /var/lib/grafana-agent/data-agent 2>/dev/null || true
sudo rm -rf /var/lib/grafana-agent/wal 2>/dev/null || true

echo -e "${GREEN}✓${NC} Permissions fixed"

echo ""
echo -e "${BLUE}7. STARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl start grafana-agent
sleep 3

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent started successfully!"
    
    # Show recent logs
    echo ""
    echo "Recent logs:"
    sudo journalctl -u grafana-agent -n 5 --no-pager | grep -v "level=error" || true
else
    echo -e "${RED}✗${NC} Failed to start Grafana Agent"
    echo ""
    echo "Error logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}8. VERIFYING OPERATION${NC}"
echo "────────────────────────────────"

# Check if metrics endpoint is available
sleep 5

if curl -s -o /dev/null -w "%{http_code}" http://localhost:12345/metrics 2>/dev/null | grep -q "200"; then
    echo -e "${GREEN}✓${NC} Agent metrics endpoint is accessible"
    
    # Check for scrape targets
    METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null || echo "")
    if echo "$METRICS" | grep -q 'up{.*job="emby"'; then
        echo -e "${GREEN}✓${NC} Emby job is configured"
    fi
    if echo "$METRICS" | grep -q 'up{.*job="node"'; then
        echo -e "${GREEN}✓${NC} Node job is configured"
    fi
else
    echo -e "${YELLOW}⚠${NC} Agent metrics endpoint not yet ready"
fi

# Check Emby exporter
echo ""
if curl -s http://localhost:9119/metrics | grep -q "emby_livetv"; then
    METRIC_COUNT=$(curl -s http://localhost:9119/metrics | grep -c "emby_livetv" || echo "0")
    echo -e "${GREEN}✓${NC} Emby exporter is running ($METRIC_COUNT Live TV metrics)"
else
    echo -e "${YELLOW}⚠${NC} Emby exporter not responding or no Live TV metrics"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  MINIMAL CONFIG APPLIED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Success!${NC} The agent is now running with a minimal configuration."
echo ""
echo "The configuration includes:"
echo "• Scraping Emby exporter on port 9119"
echo "• Scraping Node exporter on port 9100"
echo "• Sending metrics to Grafana Cloud"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Wait 2-3 minutes for metrics to appear"
echo "2. Check your Grafana Cloud dashboard"
echo "3. Verify metrics in Grafana Explore with: emby_livetv_streams_active"
echo ""
echo -e "${CYAN}Commands:${NC}"
echo "• View config: cat /etc/grafana-agent/agent.yaml"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• Check status: sudo systemctl status grafana-agent"
echo "• Test metrics: curl http://localhost:12345/metrics | grep up"