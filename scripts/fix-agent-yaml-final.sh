#!/bin/bash

# Final fix for agent.yaml - creates a working configuration from scratch

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
echo -e "${CYAN}  FINAL FIX FOR AGENT.YAML${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Stop agent first
echo -e "${BLUE}1. STOPPING AGENT${NC}"
echo "────────────────────────────────"
sudo systemctl stop grafana-agent
sudo pkill -9 grafana-agent 2>/dev/null || true
echo -e "${GREEN}✓${NC} Agent stopped"
echo ""

# Load configuration
echo -e "${BLUE}2. LOADING CONFIGURATION${NC}"
echo "────────────────────────────────"
CONFIG_FILE="/opt/grafana-cloud-emby/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

# Set the logs key (use GRAFANA_CLOUD_LOGS_API_KEY if set, otherwise use main key)
LOGS_KEY="${GRAFANA_CLOUD_LOGS_API_KEY:-${GRAFANA_CLOUD_API_KEY}}"

echo "User ID: ${GRAFANA_CLOUD_USER}"
echo "Metrics Key: ${GRAFANA_CLOUD_API_KEY:0:20}..."
echo "Logs Key: ${LOGS_KEY:0:20}..."
echo ""

# Backup current config
echo -e "${BLUE}3. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" 2>/dev/null || true
echo -e "${GREEN}✓${NC} Backup created"
echo ""

# Create new config file
echo -e "${BLUE}4. CREATING NEW AGENT.YAML${NC}"
echo "────────────────────────────────"

# Write the configuration file using printf to avoid issues
sudo tee /etc/grafana-agent/agent.yaml > /dev/null << 'ENDOFCONFIG'
server:
  log_level: info

metrics:
  global:
    scrape_interval: 60s
    remote_write:
      - url: https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
        basic_auth:
          username: GRAFANA_USER_PLACEHOLDER
          password: GRAFANA_METRICS_KEY_PLACEHOLDER

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
            username: GRAFANA_USER_PLACEHOLDER
            password: GRAFANA_LOGS_KEY_PLACEHOLDER
            
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
                
        - job_name: nfl_updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater
                __path__: /var/log/nfl_updater.log
ENDOFCONFIG

# Now replace the placeholders with actual values
sudo sed -i "s/GRAFANA_USER_PLACEHOLDER/${GRAFANA_CLOUD_USER}/g" /etc/grafana-agent/agent.yaml
sudo sed -i "s/GRAFANA_METRICS_KEY_PLACEHOLDER/${GRAFANA_CLOUD_API_KEY}/g" /etc/grafana-agent/agent.yaml
sudo sed -i "s/GRAFANA_LOGS_KEY_PLACEHOLDER/${LOGS_KEY}/g" /etc/grafana-agent/agent.yaml

echo -e "${GREEN}✓${NC} Configuration created"
echo ""

# Verify the configuration
echo -e "${BLUE}5. VERIFYING CONFIGURATION${NC}"
echo "────────────────────────────────"
echo "Checking that keys are in place:"

if grep -q "${GRAFANA_CLOUD_USER}" /etc/grafana-agent/agent.yaml; then
    echo -e "${GREEN}✓${NC} User ID is set"
else
    echo -e "${RED}✗${NC} User ID not found"
fi

if grep -q "${LOGS_KEY:0:20}" /etc/grafana-agent/agent.yaml; then
    echo -e "${GREEN}✓${NC} Logs API key is set"
else
    echo -e "${RED}✗${NC} Logs API key not found"
fi
echo ""

# Clear positions to start fresh
echo -e "${BLUE}6. CLEARING POSITIONS${NC}"
echo "────────────────────────────────"
sudo rm -f /var/lib/grafana-agent/positions.yaml
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Positions cleared"
echo ""

# Start agent
echo -e "${BLUE}7. STARTING AGENT${NC}"
echo "────────────────────────────────"
sudo systemctl daemon-reload
sudo systemctl start grafana-agent

# Wait for startup
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Agent started successfully"
else
    echo -e "${RED}✗${NC} Agent failed to start"
    echo "Checking logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi
echo ""

# Test authentication
echo -e "${BLUE}8. TESTING AUTHENTICATION${NC}"
echo "────────────────────────────────"

# Wait for agent to settle
sleep 10

# Check for auth errors
AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "20 seconds ago" --no-pager | grep -c "401" || echo "0")

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Authentication errors detected ($AUTH_ERRORS errors)"
    echo ""
    echo "Testing direct push to Loki..."
    
    # Test direct push
    TIMESTAMP=$(date +%s%N)
    TEST_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${GRAFANA_CLOUD_USER}:${LOGS_KEY}" \
        -d '{"streams":[{"stream":{"job":"test"},"values":[["'$TIMESTAMP'","Test from fix script"]]}]}' \
        "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null || echo "000")
    
    echo "Direct push result: $TEST_RESULT"
    
    if [ "$TEST_RESULT" = "204" ] || [ "$TEST_RESULT" = "200" ]; then
        echo -e "${YELLOW}⚠${NC} Direct push works but agent auth fails"
        echo "This might be a formatting issue in agent.yaml"
    else
        echo -e "${RED}✗${NC} API key is not valid for logs"
        echo ""
        echo "The key might not have logs:write permission."
        echo "Please create a new API key with logs:write permission in Grafana Cloud."
    fi
else
    echo -e "${GREEN}✓${NC} No authentication errors!"
    
    # Check if logs are being sent
    if sudo journalctl -u grafana-agent --since "20 seconds ago" --no-pager | grep -q "batch"; then
        echo -e "${GREEN}✓${NC} Agent is sending log batches"
    else
        echo -e "${YELLOW}⚠${NC} No batches sent yet (may need more time)"
    fi
fi
echo ""

# Final check
echo -e "${BLUE}9. FINAL STATUS${NC}"
echo "────────────────────────────────"

# Show what's in the config
echo "Current logs configuration:"
grep -A3 "logs:" /etc/grafana-agent/agent.yaml | grep -E "username:|password:" | sed 's/password:.*/password: [KEY SET]/'

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$AUTH_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}SUCCESS!${NC} The agent has been reconfigured."
    echo ""
    echo "Your logs should start appearing in Grafana Cloud within 1-2 minutes."
    echo ""
    echo "Test with these queries in Explore:"
    echo "  {job=\"embyserver\"}"
    echo "  {job=\"nfl_updater\"}"
else
    echo -e "${YELLOW}Configuration updated but authentication still failing.${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Verify your API key has logs:write permission in Grafana Cloud"
    echo "2. Try creating a new API key specifically for logs"
    echo "3. Check if the key format is correct (should start with glc_)"
    echo ""
    echo "Monitor logs with:"
    echo "  sudo journalctl -u grafana-agent -f | grep -v filetarget"
fi