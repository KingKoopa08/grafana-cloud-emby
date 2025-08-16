#!/bin/bash

# Quick fix to update the logs API key in agent.yaml

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
echo -e "${CYAN}  FIX LOGS API KEY IN AGENT CONFIG${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. LOADING CORRECT KEY FROM CONFIG${NC}"
echo "────────────────────────────────"

# Load config file
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

# Get the correct logs API key
CORRECT_LOGS_KEY="${GRAFANA_CLOUD_LOGS_API_KEY:-${GRAFANA_CLOUD_API_KEY}}"

if [ -z "$CORRECT_LOGS_KEY" ]; then
    echo -e "${RED}✗${NC} No logs API key found in config.env"
    exit 1
fi

echo "Correct logs key: ${CORRECT_LOGS_KEY:0:20}...${CORRECT_LOGS_KEY: -4}"

echo ""
echo -e "${BLUE}2. CHECKING CURRENT AGENT CONFIG${NC}"
echo "────────────────────────────────"

AGENT_CONFIG="/etc/grafana-agent/agent.yaml"

# Get the current key in agent.yaml
CURRENT_KEY=$(grep -A2 "logs:" "$AGENT_CONFIG" | grep -A10 "clients:" | grep "password:" | awk '{print $2}' | head -1)

if [ -n "$CURRENT_KEY" ]; then
    echo "Current key in agent.yaml: ${CURRENT_KEY:0:20}...${CURRENT_KEY: -4}"
    
    if [ "$CURRENT_KEY" = "$CORRECT_LOGS_KEY" ]; then
        echo -e "${GREEN}✓${NC} Keys already match!"
        exit 0
    else
        echo -e "${YELLOW}⚠${NC} Keys don't match - fixing now..."
    fi
else
    echo -e "${RED}✗${NC} No password found in agent.yaml"
fi

echo ""
echo -e "${BLUE}3. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp "$AGENT_CONFIG" "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Backup created"

echo ""
echo -e "${BLUE}4. UPDATING LOGS API KEY${NC}"
echo "────────────────────────────────"

# Create a temporary file with the updated config
TEMP_CONFIG="/tmp/agent-fixed-$TIMESTAMP.yaml"

# Use sed to replace the password in the logs section
sudo sed "/^logs:/,/^[a-z_]*:/ {
    /password:/ s|password:.*|password: $CORRECT_LOGS_KEY|
}" "$AGENT_CONFIG" > "$TEMP_CONFIG"

# Verify the change
NEW_KEY=$(grep -A2 "logs:" "$TEMP_CONFIG" | grep -A10 "clients:" | grep "password:" | awk '{print $2}' | head -1)

if [ "$NEW_KEY" = "$CORRECT_LOGS_KEY" ]; then
    echo -e "${GREEN}✓${NC} Key updated successfully in temp file"
    
    # Apply the change
    sudo cp "$TEMP_CONFIG" "$AGENT_CONFIG"
    echo -e "${GREEN}✓${NC} Configuration updated"
else
    echo -e "${RED}✗${NC} Failed to update key"
    exit 1
fi

echo ""
echo -e "${BLUE}5. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Agent restarted successfully"
else
    echo -e "${RED}✗${NC} Agent failed to start"
    echo "Reverting changes..."
    sudo cp "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" "$AGENT_CONFIG"
    sudo systemctl restart grafana-agent
    exit 1
fi

echo ""
echo -e "${BLUE}6. TESTING NEW AUTHENTICATION${NC}"
echo "────────────────────────────────"

# Wait for agent to settle
sleep 10

# Check for auth errors
AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -c "401" || echo "0")

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Still seeing authentication errors"
    echo ""
    echo "Recent errors:"
    sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep "401" | tail -3
else
    echo -e "${GREEN}✓${NC} No authentication errors!"
    
    # Check if logs are being sent
    if sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -q "batch"; then
        echo -e "${GREEN}✓${NC} Agent is sending log batches"
    fi
fi

echo ""
echo -e "${BLUE}7. QUICK LOKI TEST${NC}"
echo "────────────────────────────────"

# Test direct push with the correct key
TIMESTAMP=$(date +%s%N)
TEST_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_CLOUD_USER}:${CORRECT_LOGS_KEY}" \
    -d '{"streams":[{"stream":{"job":"test","host":"'$(hostname)'"},"values":[["'$TIMESTAMP'","Test from fix script"]]}]}' \
    "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null || echo "000")

if [ "$TEST_RESULT" = "204" ] || [ "$TEST_RESULT" = "200" ]; then
    echo -e "${GREEN}✓${NC} Direct push to Loki successful!"
else
    echo -e "${RED}✗${NC} Direct push failed (HTTP $TEST_RESULT)"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$AUTH_ERRORS" -eq 0 ] && ([ "$TEST_RESULT" = "204" ] || [ "$TEST_RESULT" = "200" ]); then
    echo -e "${GREEN}SUCCESS!${NC} The correct API key is now configured."
    echo ""
    echo "Your logs should start appearing in Grafana Cloud within 1-2 minutes."
    echo ""
    echo "Test with these queries in Explore:"
    echo "  {job=\"embyserver\"}"
    echo "  {job=\"nfl_updater\"}"
else
    echo -e "${YELLOW}Partial success.${NC} The key has been updated but may still have issues."
    echo ""
    echo "Check the agent logs:"
    echo "  sudo journalctl -u grafana-agent -f"
fi