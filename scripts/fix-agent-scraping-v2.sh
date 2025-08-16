#!/bin/bash

# Fix Grafana Agent scraping issues - Version 2
# Fixes configuration syntax errors

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
echo -e "${CYAN}  GRAFANA AGENT SCRAPING FIX V2${NC}"
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
echo -e "${BLUE}1. RESTORING WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Find the most recent backup
LATEST_BACKUP=$(ls -t /etc/grafana-agent/agent.yaml.backup.* 2>/dev/null | head -1 || echo "")

if [ -n "$LATEST_BACKUP" ]; then
    echo "Found backup: $LATEST_BACKUP"
    sudo cp "$LATEST_BACKUP" /etc/grafana-agent/agent.yaml
    echo -e "${GREEN}✓${NC} Restored previous configuration"
else
    echo -e "${YELLOW}⚠${NC} No backup found, creating new config"
fi

echo ""
echo -e "${BLUE}2. CREATING CORRECTED CONFIGURATION${NC}"
echo "────────────────────────────────"

# Create corrected agent config (without invalid fields)
cat > /tmp/agent-corrected.yaml <<EOF
server:
  log_level: info
  log_format: logfmt

metrics:
  global:
    scrape_interval: 60s
    scrape_timeout: 10s
    remote_write:
      - url: https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
        basic_auth:
          username: ${GRAFANA_CLOUD_USER}
          password: ${GRAFANA_CLOUD_API_KEY}
        queue_config:
          capacity: 10000
          max_shards: 5
          max_samples_per_send: 2000
          batch_send_deadline: 5s
          min_backoff: 30ms
          max_backoff: 5s

  configs:
    - name: default
      scrape_configs:
        # System metrics
        - job_name: node_exporter
          static_configs:
            - targets: ['localhost:9100']
          metric_relabel_configs:
            - source_labels: [__name__]
              regex: 'node_(cpu|memory|disk|network|filesystem).*'
              action: keep

        # Emby Ultimate Live TV metrics
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
              labels:
                instance: 'emby-server'
                exporter: 'ultimate'
          scrape_interval: 30s
          scrape_timeout: 10s
          metrics_path: /metrics

integrations:
  agent:
    enabled: true
  node_exporter:
    enabled: true
    include_exporter_metrics: true
    autoscrape:
      enable: true
      metrics_instance: default
EOF

echo -e "${GREEN}✓${NC} Corrected configuration created"

echo ""
echo -e "${BLUE}3. APPLYING CONFIGURATION${NC}"
echo "────────────────────────────────"

# Backup current
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$(date +%Y%m%d-%H%M%S).broken" 2>/dev/null || true

# Apply corrected config
sudo cp /tmp/agent-corrected.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}4. FIXING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Fix WAL directory permissions
sudo mkdir -p /var/lib/grafana-agent
sudo chown grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Fixed WAL directory permissions"

# Fix log permissions if needed
sudo touch /var/log/grafana-agent.log 2>/dev/null || true
sudo chown grafana-agent:grafana-agent /var/log/grafana-agent.log 2>/dev/null || true

echo ""
echo -e "${BLUE}5. STARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

# Stop if running
sudo systemctl stop grafana-agent 2>/dev/null || true
sleep 2

# Clear any stale data
sudo rm -rf /var/lib/grafana-agent/data-agent 2>/dev/null || true
sudo rm -rf /tmp/agent-wal 2>/dev/null || true

# Start agent
sudo systemctl start grafana-agent

sleep 3

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent started successfully!"
else
    echo -e "${RED}✗${NC} Failed to start Grafana Agent"
    echo ""
    echo "Recent logs:"
    sudo journalctl -u grafana-agent -n 30 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}6. VERIFYING SCRAPING${NC}"
echo "────────────────────────────────"

# Wait for initialization
echo "Waiting for agent to initialize..."
sleep 10

# Check if agent is scraping
AGENT_METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null || echo "")

if [ -n "$AGENT_METRICS" ]; then
    echo "Checking scrape targets..."
    
    # Check for emby job
    if echo "$AGENT_METRICS" | grep -q 'up{.*job="emby"'; then
        UP_VALUE=$(echo "$AGENT_METRICS" | grep 'up{.*job="emby"' | grep -oE '[0-9]+$' | head -1)
        if [ "$UP_VALUE" = "1" ]; then
            echo -e "${GREEN}✓${NC} Emby exporter is UP and being scraped!"
        else
            echo -e "${YELLOW}⚠${NC} Emby exporter target is DOWN"
        fi
    else
        echo -e "${RED}✗${NC} Emby job not found in scrape targets"
    fi
    
    # Check for node job
    if echo "$AGENT_METRICS" | grep -q 'up{.*job="node_exporter"'; then
        echo -e "${GREEN}✓${NC} Node exporter is being scraped"
    fi
else
    echo -e "${YELLOW}⚠${NC} Agent metrics endpoint not accessible"
fi

echo ""
echo -e "${BLUE}7. CHECKING METRICS FLOW${NC}"
echo "────────────────────────────────"

# Check for remote write errors
ERROR_COUNT=$(sudo journalctl -u grafana-agent --since="1 minute ago" --no-pager 2>/dev/null | grep -c "level=error" || echo "0")

if [ "$ERROR_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✓${NC} No errors in recent logs"
else
    echo -e "${YELLOW}⚠${NC} Found $ERROR_COUNT errors in recent logs"
fi

# Quick check if metrics are being sent
if sudo journalctl -u grafana-agent --since="1 minute ago" --no-pager 2>/dev/null | grep -q "msg=\"Scraped metrics\""; then
    echo -e "${GREEN}✓${NC} Metrics are being scraped"
fi

echo ""
echo -e "${BLUE}8. TESTING GRAFANA CLOUD${NC}"
echo "────────────────────────────────"

echo "Waiting for metrics to reach Grafana Cloud..."
sleep 20

# Test query
RESPONSE=$(curl -s -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=up{job=\"emby\"}" 2>/dev/null || echo "{}")

if echo "$RESPONSE" | grep -q '"status":"success"'; then
    if echo "$RESPONSE" | grep -q '"result":\[\]'; then
        echo -e "${YELLOW}⚠${NC} Query successful but no results yet"
        echo "  Wait another minute and check dashboard"
    else
        echo -e "${GREEN}✓${NC} Emby metrics found in Grafana Cloud!"
    fi
else
    echo -e "${YELLOW}⚠${NC} Could not verify Grafana Cloud connection"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  FIX COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Status Summary:${NC}"
echo "• Agent is running with corrected configuration"
echo "• Permissions have been fixed"
echo "• Scraping configuration is active"
echo ""

echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait 2-3 minutes for metrics to stabilize"
echo "2. Check your Grafana Cloud dashboard"
echo "3. Look for 'emby_livetv_' metrics in Explore"
echo ""

echo -e "${CYAN}Monitor with:${NC}"
echo "• Agent logs: sudo journalctl -u grafana-agent -f"
echo "• Local metrics: curl http://localhost:9119/metrics | head -20"
echo "• Agent targets: curl http://localhost:12345/metrics | grep up"