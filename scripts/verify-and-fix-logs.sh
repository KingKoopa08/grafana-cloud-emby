#!/bin/bash

# Verify the configuration and fix any issues

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
echo -e "${CYAN}  VERIFY AND FIX LOGS CONFIGURATION${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
source /opt/grafana-cloud-emby/config/config.env

# Correct values
METRICS_USER="2607589"
LOGS_USER="1299471"
LOGS_KEY="${GRAFANA_CLOUD_LOGS_API_KEY}"

echo -e "${BLUE}1. CURRENT AGENT.YAML CONTENT${NC}"
echo "────────────────────────────────"

echo "Logs section in agent.yaml:"
sudo grep -A10 "^logs:" /etc/grafana-agent/agent.yaml | grep -E "username:|password:" | head -2

echo ""
echo -e "${BLUE}2. VERIFYING VALUES${NC}"
echo "────────────────────────────────"

# Get current values from agent.yaml
CURRENT_LOGS_USER=$(sudo grep -A10 "^logs:" /etc/grafana-agent/agent.yaml | grep "username:" | head -1 | awk '{print $2}')
CURRENT_LOGS_KEY=$(sudo grep -A10 "^logs:" /etc/grafana-agent/agent.yaml | grep "password:" | head -1 | awk '{print $2}')

echo "Current logs user in agent.yaml: $CURRENT_LOGS_USER"
echo "Should be: $LOGS_USER"

if [ "$CURRENT_LOGS_USER" = "$LOGS_USER" ]; then
    echo -e "${GREEN}✓${NC} User ID is correct"
else
    echo -e "${RED}✗${NC} User ID is wrong!"
fi

echo ""
echo "Current logs key: ${CURRENT_LOGS_KEY:0:50}..."
echo "Should be: ${LOGS_KEY:0:50}..."

if [ "$CURRENT_LOGS_KEY" = "$LOGS_KEY" ]; then
    echo -e "${GREEN}✓${NC} API key is correct"
else
    echo -e "${RED}✗${NC} API key is wrong!"
fi

echo ""
echo -e "${BLUE}3. TESTING AUTHENTICATION DIRECTLY${NC}"
echo "────────────────────────────────"

# Test with what's in the config
echo "Testing with values from agent.yaml..."
TEST1=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${CURRENT_LOGS_USER}:${CURRENT_LOGS_KEY}" \
    -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test"]]}]}' \
    "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null)

if [ "$TEST1" = "204" ] || [ "$TEST1" = "200" ]; then
    echo -e "${GREEN}✓${NC} Current config authenticates successfully!"
else
    echo -e "${RED}✗${NC} Current config fails (HTTP $TEST1)"
fi

# Test with correct values
echo ""
echo "Testing with correct values..."
TEST2=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${LOGS_USER}:${LOGS_KEY}" \
    -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test"]]}]}' \
    "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null)

if [ "$TEST2" = "204" ] || [ "$TEST2" = "200" ]; then
    echo -e "${GREEN}✓${NC} Correct values authenticate successfully!"
else
    echo -e "${RED}✗${NC} Even correct values fail (HTTP $TEST2)"
fi

echo ""
echo -e "${BLUE}4. FIXING WITH SED${NC}"
echo "────────────────────────────────"

if [ "$CURRENT_LOGS_USER" != "$LOGS_USER" ] || [ "$CURRENT_LOGS_KEY" != "$LOGS_KEY" ]; then
    echo "Fixing configuration..."
    
    # Stop agent
    sudo systemctl stop grafana-agent
    
    # Fix username in logs section only
    sudo sed -i "/^logs:/,/^[a-z]*:/ { s/username: .*/username: $LOGS_USER/; }" /etc/grafana-agent/agent.yaml
    
    # Fix password in logs section only
    sudo sed -i "/^logs:/,/^[a-z]*:/ { s|password: .*|password: $LOGS_KEY|; }" /etc/grafana-agent/agent.yaml
    
    echo -e "${GREEN}✓${NC} Configuration updated"
    
    # Verify the fix
    echo ""
    echo "Verification after fix:"
    sudo grep -A10 "^logs:" /etc/grafana-agent/agent.yaml | grep -E "username:|password:" | head -2
    
    # Start agent
    sudo systemctl start grafana-agent
    echo -e "${GREEN}✓${NC} Agent restarted"
else
    echo "Configuration already correct, just restarting agent..."
    sudo systemctl restart grafana-agent
fi

echo ""
echo -e "${BLUE}5. FINAL CHECK${NC}"
echo "────────────────────────────────"

sleep 10

AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "15 seconds ago" --no-pager | grep -c "401" || echo "0")

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Still seeing authentication errors"
    
    echo ""
    echo "Checking agent process..."
    AGENT_PID=$(pgrep grafana-agent | head -1)
    if [ -n "$AGENT_PID" ]; then
        echo "Agent PID: $AGENT_PID"
        echo "Config file being used:"
        ps -p $AGENT_PID -o args= | grep -o '\-config.file=[^ ]*' || echo "Default config"
    fi
    
    echo ""
    echo "Last few errors:"
    sudo journalctl -u grafana-agent --since "15 seconds ago" --no-pager | grep "401" | tail -2
else
    echo -e "${GREEN}✓${NC} No authentication errors!"
    
    # Check if logs are being sent
    if sudo journalctl -u grafana-agent --since "15 seconds ago" --no-pager | grep -q "batch"; then
        echo -e "${GREEN}✓${NC} Agent is sending log batches!"
    else
        echo -e "${YELLOW}⚠${NC} No batches yet (may need more time)"
    fi
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  TROUBLESHOOTING INFO${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo "Key facts:"
echo "• Metrics User ID: 2607589"
echo "• Logs User ID: 1299471"
echo "• API Key name: logs-test12"
echo "• Endpoint: https://logs-prod-021.grafana.net/loki/api/v1/push"
echo ""

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo "If still failing, try:"
    echo "1. sudo systemctl stop grafana-agent"
    echo "2. sudo pkill -9 grafana-agent"
    echo "3. sudo rm /var/lib/grafana-agent/positions.yaml"
    echo "4. sudo systemctl start grafana-agent"
    echo ""
    echo "Or manually edit /etc/grafana-agent/agent.yaml and ensure:"
    echo "  In the logs section:"
    echo "    username: 1299471"
    echo "    password: $LOGS_KEY"
fi