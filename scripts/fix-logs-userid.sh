#!/bin/bash

# Fix the logs user ID - it's different from metrics!

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
echo -e "${CYAN}  FIX LOGS USER ID${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}CRITICAL DISCOVERY:${NC}"
echo "────────────────────────────────"
echo "Metrics User ID: 2607589"
echo "Logs User ID: 1299471 (DIFFERENT!)"
echo ""

# Load config
source /opt/grafana-cloud-emby/config/config.env

# Set the correct user IDs
METRICS_USER="2607589"
LOGS_USER="1299471"  # Different user ID for logs!
LOGS_KEY="${GRAFANA_CLOUD_LOGS_API_KEY}"

echo -e "${BLUE}1. TESTING WITH CORRECT LOGS USER ID${NC}"
echo "────────────────────────────────"

# Test with the correct logs user ID
TIMESTAMP=$(date +%s%N)
TEST_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${LOGS_USER}:${LOGS_KEY}" \
    -d '{"streams":[{"stream":{"job":"test"},"values":[["'$TIMESTAMP'","Test with correct user ID"]]}]}' \
    "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null || echo "000")

if [ "$TEST_RESULT" = "204" ] || [ "$TEST_RESULT" = "200" ]; then
    echo -e "${GREEN}✓ SUCCESS! Authentication works with user ID 1299471!${NC}"
else
    echo -e "${RED}✗ Still failed with HTTP $TEST_RESULT${NC}"
    echo "Trying without user ID..."
    
    # Try without user ID
    TEST_RESULT2=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${LOGS_KEY}" \
        -d '{"streams":[{"stream":{"job":"test"},"values":[["'$TIMESTAMP'","Test without user ID"]]}]}' \
        "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null || echo "000")
    
    if [ "$TEST_RESULT2" = "204" ] || [ "$TEST_RESULT2" = "200" ]; then
        echo -e "${GREEN}✓ Works with Bearer token (no user ID)!${NC}"
    fi
fi

echo ""
echo -e "${BLUE}2. UPDATING AGENT CONFIGURATION${NC}"
echo "────────────────────────────────"

# Stop agent
sudo systemctl stop grafana-agent
echo -e "${GREEN}✓${NC} Agent stopped"

# Backup current config
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Config backed up"

# Create new config with correct user IDs
echo -e "${GREEN}✓${NC} Creating new configuration with correct user IDs..."

sudo tee /etc/grafana-agent/agent.yaml > /dev/null << EOF
server:
  log_level: info

metrics:
  global:
    scrape_interval: 60s
    remote_write:
      - url: https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
        basic_auth:
          username: ${METRICS_USER}
          password: ${GRAFANA_CLOUD_API_KEY}

  configs:
    - name: default
      scrape_configs:
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
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
        - url: https://logs-prod-021.grafana.net/loki/api/v1/push
          basic_auth:
            username: ${LOGS_USER}
            password: ${LOGS_KEY}
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        - job_name: embyserver
          static_configs:
            - targets:
                - localhost
              labels:
                job: embyserver
                __path__: /var/lib/emby/logs/embyserver.txt
                
          pipeline_stages:
            - multiline:
                firstline: '^\d{4}-\d{2}-\d{2}'
                max_wait_time: 3s
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)'
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05.000'
                location: UTC
                action_on_failure: skip
            - output:
                source: message
                
        - job_name: nfl_updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater
                __path__: /var/log/nfl_updater.log
                
          pipeline_stages:
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05'
                location: UTC
                action_on_failure: skip
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Configuration created with correct user IDs"

echo ""
echo -e "${BLUE}3. UPDATING CONFIG.ENV${NC}"
echo "────────────────────────────────"

# Add the logs user ID to config.env if not present
if ! grep -q "GRAFANA_CLOUD_LOGS_USER" /opt/grafana-cloud-emby/config/config.env; then
    echo "" >> /opt/grafana-cloud-emby/config/config.env
    echo "# Logs has a different user ID!" >> /opt/grafana-cloud-emby/config/config.env
    echo "GRAFANA_CLOUD_LOGS_USER=1299471" >> /opt/grafana-cloud-emby/config/config.env
    echo -e "${GREEN}✓${NC} Added GRAFANA_CLOUD_LOGS_USER to config.env"
else
    echo -e "${YELLOW}⚠${NC} GRAFANA_CLOUD_LOGS_USER already in config.env"
fi

echo ""
echo -e "${BLUE}4. STARTING AGENT${NC}"
echo "────────────────────────────────"

# Clear positions for fresh start
sudo rm -f /var/lib/grafana-agent/positions.yaml
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent

# Start agent
sudo systemctl daemon-reload
sudo systemctl start grafana-agent

sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Agent started successfully"
else
    echo -e "${RED}✗${NC} Agent failed to start"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}5. CHECKING FOR ERRORS${NC}"
echo "────────────────────────────────"

sleep 10

AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "20 seconds ago" --no-pager | grep -c "401" || echo "0")

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Still seeing authentication errors"
    echo "Recent errors:"
    sudo journalctl -u grafana-agent --since "20 seconds ago" --no-pager | grep "401" | tail -3
else
    echo -e "${GREEN}✓${NC} No authentication errors!"
    
    # Check if logs are being sent
    if sudo journalctl -u grafana-agent --since "20 seconds ago" --no-pager | grep -q "batch"; then
        echo -e "${GREEN}✓${NC} Agent is sending log batches!"
    fi
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$AUTH_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}SUCCESS!${NC} Logs should now be working with the correct user ID."
    echo ""
    echo "Key insight: Grafana Cloud uses DIFFERENT user IDs for metrics vs logs!"
    echo "  Metrics: 2607589"
    echo "  Logs: 1299471"
    echo ""
    echo "Your logs should appear in Grafana Cloud within 1-2 minutes."
    echo ""
    echo "Test with these queries in Explore:"
    echo "  {job=\"embyserver\"}"
    echo "  {job=\"nfl_updater\"}"
else
    echo -e "${YELLOW}Still having issues.${NC}"
    echo ""
    echo "The user ID might not be the only problem."
    echo "Check the agent logs for details:"
    echo "  sudo journalctl -u grafana-agent -f"
fi