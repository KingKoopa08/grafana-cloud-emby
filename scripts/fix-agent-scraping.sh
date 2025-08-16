#!/bin/bash

# Fix Grafana Agent scraping issues for Emby exporters
# This script diagnoses and fixes the agent configuration

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
echo -e "${CYAN}  GRAFANA AGENT SCRAPING FIX${NC}"
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
echo -e "${BLUE}1. CHECKING CURRENT AGENT STATUS${NC}"
echo "────────────────────────────────"

# Find which config file agent is using
AGENT_PID=$(pgrep grafana-agent || echo "")
if [ -n "$AGENT_PID" ]; then
    AGENT_CONFIG=$(ps aux | grep grafana-agent | grep -v grep | grep -oE '(agent\.yaml|grafana-agent\.yaml)' | head -1)
    AGENT_CONFIG_PATH="/etc/grafana-agent/${AGENT_CONFIG:-agent.yaml}"
    echo -e "${GREEN}✓${NC} Agent running with PID: $AGENT_PID"
    echo -e "  Config file: $AGENT_CONFIG_PATH"
else
    echo -e "${RED}✗${NC} Grafana Agent not running"
    AGENT_CONFIG_PATH="/etc/grafana-agent/agent.yaml"
fi

echo ""
echo -e "${BLUE}2. CHECKING EXPORTER STATUS${NC}"
echo "────────────────────────────────"

# Check which exporters are available
EXPORTERS_FOUND=()
if curl -s http://localhost:9119/metrics > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Port 9119 (Ultimate/LiveTV exporter) is responding"
    EXPORTERS_FOUND+=("9119")
fi

if curl -s http://localhost:9101/metrics > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Port 9101 (Basic exporter) is responding"
    EXPORTERS_FOUND+=("9101")
fi

if [ ${#EXPORTERS_FOUND[@]} -eq 0 ]; then
    echo -e "${RED}✗${NC} No Emby exporters are running!"
    echo "  Deploy an exporter first with:"
    echo "  ./scripts/deploy-ultimate.sh"
    exit 1
fi

echo ""
echo -e "${BLUE}3. CREATING FIXED AGENT CONFIGURATION${NC}"
echo "────────────────────────────────"

# Create new agent config with proper scraping
cat > /tmp/agent-fixed.yaml <<EOF
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
          max_retries: 10
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
        - job_name: emby_livetv_ultimate
          static_configs:
            - targets: ['localhost:9119']
              labels:
                instance: 'emby-server'
                exporter: 'ultimate'
          scrape_interval: 30s
          scrape_timeout: 10s
          metrics_path: /metrics
          honor_timestamps: true
          
        # Emby basic metrics (if available)
        - job_name: emby_basic
          static_configs:
            - targets: ['localhost:9101']
              labels:
                instance: 'emby-server'
                exporter: 'basic'
          scrape_interval: 60s
          metrics_path: /metrics
          honor_timestamps: true

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

echo -e "${GREEN}✓${NC} Fixed configuration created"

echo ""
echo -e "${BLUE}4. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

BACKUP_NAME="${AGENT_CONFIG_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
sudo cp "$AGENT_CONFIG_PATH" "$BACKUP_NAME"
echo -e "${GREEN}✓${NC} Backed up to: $BACKUP_NAME"

echo ""
echo -e "${BLUE}5. APPLYING FIXED CONFIGURATION${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-fixed.yaml "$AGENT_CONFIG_PATH"
echo -e "${GREEN}✓${NC} New configuration applied"

# Test config syntax
if sudo grafana-agent -config.file="$AGENT_CONFIG_PATH" -config.check 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Configuration syntax is valid"
else
    echo -e "${YELLOW}⚠${NC} Configuration check not available, proceeding anyway"
fi

echo ""
echo -e "${BLUE}6. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 3

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent restarted successfully"
else
    echo -e "${RED}✗${NC} Failed to restart Grafana Agent"
    echo "Checking logs..."
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}7. VERIFYING SCRAPING${NC}"
echo "────────────────────────────────"

# Wait for agent to start scraping
echo "Waiting for agent to start scraping..."
sleep 10

# Check agent's internal metrics
echo "Checking agent metrics endpoint..."
AGENT_METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null || echo "")

if [ -n "$AGENT_METRICS" ]; then
    # Check for successful scrapes
    EMBY_SCRAPES=$(echo "$AGENT_METRICS" | grep -c 'up{.*job="emby' || echo "0")
    LIVETV_SCRAPES=$(echo "$AGENT_METRICS" | grep -c 'up{.*job="emby_livetv' || echo "0")
    
    if [ "$LIVETV_SCRAPES" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Agent is scraping Live TV Ultimate exporter"
        UP_VALUE=$(echo "$AGENT_METRICS" | grep 'up{.*job="emby_livetv' | grep -oE '[0-9]+$' | head -1)
        if [ "$UP_VALUE" = "1" ]; then
            echo -e "${GREEN}✓${NC} Live TV exporter is UP"
        else
            echo -e "${YELLOW}⚠${NC} Live TV exporter is DOWN (up=0)"
        fi
    elif [ "$EMBY_SCRAPES" -gt 0 ]; then
        echo -e "${YELLOW}⚠${NC} Agent is scraping basic Emby exporter (not Live TV)"
    else
        echo -e "${RED}✗${NC} Agent is not scraping any Emby exporters"
    fi
    
    # Show scrape statistics
    echo ""
    echo "Scrape statistics:"
    echo "$AGENT_METRICS" | grep 'prometheus_sd_discovered_targets' | head -3
    echo "$AGENT_METRICS" | grep 'prometheus_target_scrapes_sample_' | head -3
else
    echo -e "${YELLOW}⚠${NC} Cannot access agent metrics endpoint"
fi

echo ""
echo -e "${BLUE}8. CHECKING REMOTE WRITE${NC}"
echo "────────────────────────────────"

# Check recent logs for remote write status
WRITE_SUCCESS=$(sudo journalctl -u grafana-agent -n 100 --no-pager 2>/dev/null | grep -c "remote_storage_samples_total" || echo "0")
WRITE_ERRORS=$(sudo journalctl -u grafana-agent -n 100 --no-pager 2>/dev/null | grep -c "remote.write.*error" || echo "0")

if [ "$WRITE_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Found $WRITE_ERRORS remote write errors"
    echo "Recent errors:"
    sudo journalctl -u grafana-agent -n 100 --no-pager | grep "error" | tail -3
elif [ "$WRITE_SUCCESS" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Remote write appears to be working"
else
    echo -e "${YELLOW}⚠${NC} Cannot determine remote write status"
fi

echo ""
echo -e "${BLUE}9. TESTING GRAFANA CLOUD${NC}"
echo "────────────────────────────────"

# Wait for metrics to reach cloud
echo "Waiting 30 seconds for metrics to reach Grafana Cloud..."
sleep 30

# Query Grafana Cloud for metrics
echo "Querying Grafana Cloud for Live TV metrics..."
CLOUD_RESPONSE=$(curl -s -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=emby_livetv_streams_active" 2>/dev/null || echo "{}")

if echo "$CLOUD_RESPONSE" | grep -q '"status":"success"'; then
    if echo "$CLOUD_RESPONSE" | grep -q '"result":\[\]'; then
        echo -e "${YELLOW}⚠${NC} Query successful but no Live TV metrics found yet"
        echo "  This could mean:"
        echo "  • Metrics haven't propagated yet (wait 1-2 minutes)"
        echo "  • No Live TV activity to report"
        echo "  • Scraping still not working properly"
    else
        echo -e "${GREEN}✓${NC} Live TV metrics found in Grafana Cloud!"
        VALUE=$(echo "$CLOUD_RESPONSE" | grep -o '"value":\[.*\]' | grep -o '[0-9.]*' | tail -1 || echo "0")
        echo "  Current emby_livetv_streams_active: $VALUE"
    fi
else
    echo -e "${RED}✗${NC} Failed to query Grafana Cloud"
    echo "  Check your API credentials in config.env"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  FIX COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}What we did:${NC}"
echo "1. Created a new, properly formatted agent configuration"
echo "2. Added explicit scrape configs for Emby exporters"
echo "3. Fixed the scrape intervals and timeouts"
echo "4. Restarted the Grafana Agent"
echo ""

echo -e "${YELLOW}Next steps:${NC}"
echo "1. Wait 2-3 minutes for metrics to propagate"
echo "2. Check your Grafana Cloud dashboard"
echo "3. If still no data, check the exporter logs:"
echo "   sudo journalctl -u emby-livetv-ultimate -f"
echo "4. Monitor agent logs:"
echo "   sudo journalctl -u grafana-agent -f"
echo ""

echo -e "${CYAN}Useful commands:${NC}"
echo "• Test local metrics: curl http://localhost:9119/metrics | grep emby_livetv_"
echo "• Check agent targets: curl http://localhost:12345/metrics | grep up"
echo "• View agent config: cat $AGENT_CONFIG_PATH"
echo "• Restore backup: sudo cp $BACKUP_NAME $AGENT_CONFIG_PATH"