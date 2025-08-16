#!/bin/bash

# Add logs collection with the new API key that has logs:write permission
# This script safely adds logs back to the working metrics configuration

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
echo -e "${CYAN}  ADD LOGS WITH NEW API KEY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. LOADING CONFIGURATION${NC}"
echo "────────────────────────────────"

# Load existing config for metrics
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

# The new logs API key - should be set in environment or passed as argument
# If not provided, use the main API key (assuming it has logs:write permission)
LOGS_API_KEY="${GRAFANA_CLOUD_LOGS_API_KEY:-${GRAFANA_CLOUD_API_KEY}}"

if [ -z "$LOGS_API_KEY" ]; then
    echo -e "${RED}✗${NC} No API key found for logs"
    echo "Please set GRAFANA_CLOUD_LOGS_API_KEY in config.env"
    echo "or ensure GRAFANA_CLOUD_API_KEY has logs:write permission"
    exit 1
fi

echo "  Metrics User: ${GRAFANA_CLOUD_USER}"
echo "  Logs API Key: ${LOGS_API_KEY:0:20}..."

echo ""
echo -e "${BLUE}2. DETECTING LOKI ENDPOINT${NC}"
echo "────────────────────────────────"

# Detect the correct Loki URL based on Prometheus URL
if [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-36"* ]] || [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-us-west-0"* ]]; then
    LOKI_URL="https://logs-prod-021.grafana.net/loki/api/v1/push"
    echo "  Region: US West (prod-36)"
elif [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-10"* ]] || [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-us-central"* ]]; then
    LOKI_URL="https://logs-prod-006.grafana.net/loki/api/v1/push"
    echo "  Region: US Central (prod-10)"
elif [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-13"* ]] || [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-eu"* ]]; then
    LOKI_URL="https://logs-prod-eu-west-0.grafana.net/loki/api/v1/push"
    echo "  Region: EU (prod-13)"
else
    # Default to US West
    LOKI_URL="https://logs-prod-021.grafana.net/loki/api/v1/push"
    echo "  Region: Default US West"
fi

echo "  Loki URL: $LOKI_URL"

echo ""
echo -e "${BLUE}3. TESTING NEW LOGS KEY${NC}"
echo "────────────────────────────────"

# Test the new logs key
echo "Testing logs authentication..."
LOKI_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_CLOUD_USER}:${LOGS_API_KEY}" \
    -d '{"streams": [{"stream": {"job": "test"}, "values": [["'$(date +%s%N)'", "test"]]}]}' \
    "$LOKI_URL" 2>/dev/null || echo "000")

if [ "$LOKI_TEST" = "204" ] || [ "$LOKI_TEST" = "200" ]; then
    echo -e "${GREEN}✓${NC} Logs authentication successful!"
else
    echo -e "${RED}✗${NC} Logs authentication failed (status: $LOKI_TEST)"
    echo "Continuing anyway..."
fi

echo ""
echo -e "${BLUE}4. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Current config backed up"

echo ""
echo -e "${BLUE}5. CREATING CONFIG WITH LOGS${NC}"
echo "────────────────────────────────"

# Create new config with both metrics and logs
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

logs:
  configs:
    - name: default
      clients:
        - url: ${LOKI_URL}
          basic_auth:
            username: ${GRAFANA_CLOUD_USER}
            password: ${LOGS_API_KEY}
          external_labels:
            hostname: 'ns1017440'
            environment: 'prod'
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # Emby Server Logs
        - job_name: embyserver
          static_configs:
            - targets:
                - localhost
              labels:
                job: embyserver
                service: emby
                __path__: /var/lib/emby/logs/embyserver.txt
                
          pipeline_stages:
            - multiline:
                firstline: '^\\d{4}-\\d{2}-\\d{2}'
                max_wait_time: 3s
            - regex:
                expression: '^(?P<timestamp>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+)'
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05.000'
                location: UTC
                action_on_failure: skip
            - output:
                source: message
                
        # NFL Updater Logs  
        - job_name: nfl_updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater
                service: nfl
                __path__: /var/log/nfl_updater.log
                
          pipeline_stages:
            - regex:
                expression: '^(?P<timestamp>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})'
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05'
                location: UTC
                action_on_failure: skip
            - regex:
                expression: 'Game (?P<teams>[^:]+):\\s+(?P<score>[\\d-]+)\\s+\\((?P<status>[^)]+)\\)'
            - labels:
                status:
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Configuration created with logs enabled"

echo ""
echo -e "${BLUE}6. SETTING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure log files are readable
if [ -f /var/lib/emby/logs/embyserver.txt ]; then
    sudo chmod 644 /var/lib/emby/logs/embyserver.txt 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Emby log permissions set"
fi

if [ -f /var/log/nfl_updater.log ]; then
    sudo chmod 644 /var/log/nfl_updater.log 2>/dev/null || true
    echo -e "${GREEN}✓${NC} NFL log permissions set"
fi

# Ensure positions directory
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Positions directory ready"

echo ""
echo -e "${BLUE}7. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent restarted successfully"
else
    echo -e "${RED}✗${NC} Agent failed to start"
    echo "Error logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    
    # Revert on failure
    sudo cp "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" /etc/grafana-agent/agent.yaml
    sudo systemctl restart grafana-agent
    echo -e "${YELLOW}⚠${NC} Reverted to previous config"
    exit 1
fi

echo ""
echo -e "${BLUE}8. CHECKING FOR AUTH ERRORS${NC}"
echo "────────────────────────────────"

sleep 10

# Check for authentication errors
AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -c "401" || echo "0")

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Still seeing authentication errors"
    sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep "401" | head -2
else
    echo -e "${GREEN}✓${NC} No authentication errors!"
    
    # Check if logs are being sent
    if sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -q "tail"; then
        echo -e "${GREEN}✓${NC} Agent is tailing log files"
    fi
    
    if sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -q "batch"; then
        echo -e "${GREEN}✓${NC} Agent is sending log batches to Loki"
    fi
fi

echo ""
echo -e "${BLUE}9. VERIFYING LOG FILES${NC}"
echo "────────────────────────────────"

# Check what files the agent is reading
AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Files being read by agent:"
    
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "embyserver.txt"; then
        echo -e "  ${GREEN}✓${NC} Emby server logs"
    else
        echo -e "  ${YELLOW}⚠${NC} Emby logs not being read yet"
    fi
    
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "nfl_updater.log"; then
        echo -e "  ${GREEN}✓${NC} NFL updater logs"
    else
        echo -e "  ${YELLOW}⚠${NC} NFL logs not being read yet"
    fi
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOGS COLLECTION ENABLED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$AUTH_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}Success!${NC} Logs are now being collected and sent to Grafana Cloud."
    echo ""
    echo "Log sources configured:"
    echo "• Emby: /var/lib/emby/logs/embyserver.txt"
    echo "• NFL: /var/log/nfl_updater.log"
    echo ""
    echo "Test queries in Grafana Explore (wait 2-3 minutes for data):"
    echo ""
    echo -e "${CYAN}All logs:${NC}"
    echo '{job=~".+"}'
    echo ""
    echo -e "${CYAN}Emby logs:${NC}"
    echo '{job="embyserver"}'
    echo ""
    echo -e "${CYAN}NFL logs:${NC}"
    echo '{job="nfl_updater"}'
    echo ""
    echo -e "${CYAN}NFL game updates:${NC}"
    echo '{job="nfl_updater"} |~ "Game"'
else
    echo -e "${YELLOW}Warning:${NC} Authentication issues detected."
    echo "The logs API key might not be working correctly."
fi

echo ""
echo -e "${CYAN}Useful commands:${NC}"
echo "• Check agent: sudo systemctl status grafana-agent"
echo "• View logs: sudo journalctl -u grafana-agent -f | grep -v 401"
echo "• Check positions: cat /var/lib/grafana-agent/positions.yaml"