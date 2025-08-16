#!/bin/bash

# Diagnostic script to show exactly which API keys are being used where

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
echo -e "${CYAN}  DIAGNOSE LOGS API KEY CONFIGURATION${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. CHECKING CONFIG.ENV${NC}"
echo "────────────────────────────────"

CONFIG_FILE="/opt/grafana-cloud-emby/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}✓${NC} config.env exists"
    echo ""
    
    # Show the raw keys from config.env
    echo "Raw values in config.env:"
    echo "-------------------------"
    grep "GRAFANA_CLOUD_API_KEY=" "$CONFIG_FILE" | head -1
    grep "GRAFANA_CLOUD_LOGS_API_KEY=" "$CONFIG_FILE" | head -1
    echo "-------------------------"
    echo ""
    
    # Now source it and show what we get
    source "$CONFIG_FILE"
    
    echo "After sourcing config.env:"
    echo "-------------------------"
    echo "GRAFANA_CLOUD_USER=${GRAFANA_CLOUD_USER}"
    echo "GRAFANA_CLOUD_API_KEY=${GRAFANA_CLOUD_API_KEY:0:50}..."
    echo "GRAFANA_CLOUD_LOGS_API_KEY=${GRAFANA_CLOUD_LOGS_API_KEY:0:50}..."
    echo "-------------------------"
    
    # Decode the keys to see what they contain
    echo ""
    echo "Key details:"
    if [[ "$GRAFANA_CLOUD_API_KEY" =~ ^glc_ ]]; then
        KEY_PAYLOAD="${GRAFANA_CLOUD_API_KEY:4}"
        if echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.n' 2>/dev/null > /dev/null; then
            NAME=$(echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.n' 2>/dev/null)
            echo "  Metrics key name: $NAME"
        fi
    fi
    
    if [[ "$GRAFANA_CLOUD_LOGS_API_KEY" =~ ^glc_ ]]; then
        KEY_PAYLOAD="${GRAFANA_CLOUD_LOGS_API_KEY:4}"
        if echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.n' 2>/dev/null > /dev/null; then
            NAME=$(echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.n' 2>/dev/null)
            echo "  Logs key name: $NAME"
        fi
    fi
else
    echo -e "${RED}✗${NC} config.env not found"
    exit 1
fi

echo ""
echo -e "${BLUE}2. CHECKING AGENT.YAML${NC}"
echo "────────────────────────────────"

AGENT_CONFIG="/etc/grafana-agent/agent.yaml"
if [ -f "$AGENT_CONFIG" ]; then
    echo -e "${GREEN}✓${NC} agent.yaml exists"
    echo ""
    
    echo "Logs section in agent.yaml:"
    echo "-------------------------"
    # Extract the logs section with context
    sed -n '/^logs:/,/^[a-z_]*:/{/^logs:/d; /^[a-z_]*:/d; p}' "$AGENT_CONFIG" | head -20
    echo "-------------------------"
    echo ""
    
    # Get the actual password values
    echo "Password values in agent.yaml:"
    echo "-------------------------"
    
    # Metrics password
    METRICS_PASS=$(grep -A50 "^metrics:" "$AGENT_CONFIG" | grep "password:" | head -1 | sed 's/.*password: *//')
    echo "Metrics password: ${METRICS_PASS:0:50}..."
    
    # Logs password
    LOGS_PASS=$(grep -A50 "^logs:" "$AGENT_CONFIG" | grep "password:" | head -1 | sed 's/.*password: *//')
    echo "Logs password: ${LOGS_PASS:0:50}..."
    echo "-------------------------"
    
    # Decode logs password to see what key it is
    if [[ "$LOGS_PASS" =~ ^glc_ ]]; then
        KEY_PAYLOAD="${LOGS_PASS:4}"
        if echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.n' 2>/dev/null > /dev/null; then
            NAME=$(echo "$KEY_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.n' 2>/dev/null)
            echo ""
            echo -e "${YELLOW}⚠ Logs key in agent.yaml is: '$NAME'${NC}"
        fi
    fi
else
    echo -e "${RED}✗${NC} agent.yaml not found"
fi

echo ""
echo -e "${BLUE}3. COMPARING KEYS${NC}"
echo "────────────────────────────────"

# Compare the keys
if [ -n "${GRAFANA_CLOUD_LOGS_API_KEY:-}" ] && [ -n "${LOGS_PASS:-}" ]; then
    if [ "$GRAFANA_CLOUD_LOGS_API_KEY" = "$LOGS_PASS" ]; then
        echo -e "${GREEN}✓${NC} Keys MATCH - config.env and agent.yaml have the same logs key"
    else
        echo -e "${RED}✗${NC} Keys DO NOT MATCH!"
        echo ""
        echo "config.env has:    ${GRAFANA_CLOUD_LOGS_API_KEY:0:30}..."
        echo "agent.yaml has:    ${LOGS_PASS:0:30}..."
        echo ""
        echo -e "${YELLOW}This is the problem! The agent is using a different key.${NC}"
    fi
else
    echo -e "${YELLOW}⚠${NC} Could not compare keys"
fi

echo ""
echo -e "${BLUE}4. TESTING BOTH KEYS${NC}"
echo "────────────────────────────────"

# Test the key from config.env
echo "Testing key from config.env..."
TEST1=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_LOGS_API_KEY}" \
    -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test"]]}]}' \
    "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null || echo "000")

if [ "$TEST1" = "204" ] || [ "$TEST1" = "200" ]; then
    echo -e "${GREEN}✓${NC} Config.env key works! (HTTP $TEST1)"
else
    echo -e "${RED}✗${NC} Config.env key failed (HTTP $TEST1)"
fi

# Test the key from agent.yaml if different
if [ -n "${LOGS_PASS:-}" ] && [ "$GRAFANA_CLOUD_LOGS_API_KEY" != "$LOGS_PASS" ]; then
    echo ""
    echo "Testing key from agent.yaml..."
    TEST2=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -u "${GRAFANA_CLOUD_USER}:${LOGS_PASS}" \
        -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test"]]}]}' \
        "https://logs-prod-021.grafana.net/loki/api/v1/push" 2>/dev/null || echo "000")
    
    if [ "$TEST2" = "204" ] || [ "$TEST2" = "200" ]; then
        echo -e "${GREEN}✓${NC} Agent.yaml key works! (HTTP $TEST2)"
    else
        echo -e "${RED}✗${NC} Agent.yaml key failed (HTTP $TEST2)"
    fi
fi

echo ""
echo -e "${BLUE}5. CHECKING ENVIRONMENT VARIABLES${NC}"
echo "────────────────────────────────"

# Check if there are any environment overrides
echo "Checking for environment overrides..."
if [ -f /etc/environment ]; then
    grep -E "GRAFANA_CLOUD|LOKI|PROMETHEUS" /etc/environment 2>/dev/null || echo "No Grafana vars in /etc/environment"
fi

if [ -f /etc/default/grafana-agent ]; then
    echo ""
    echo "Checking /etc/default/grafana-agent:"
    cat /etc/default/grafana-agent 2>/dev/null || echo "File not found"
fi

echo ""
echo -e "${BLUE}6. AGENT PROCESS CHECK${NC}"
echo "────────────────────────────────"

# Check how the agent is running
AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Agent PID: $AGENT_PID"
    echo "Command line:"
    ps -p $AGENT_PID -o args= 
    echo ""
    echo "Environment variables for agent process:"
    sudo cat /proc/$AGENT_PID/environ 2>/dev/null | tr '\0' '\n' | grep -E "GRAFANA|LOKI" || echo "No Grafana env vars in process"
else
    echo "Agent not running"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DIAGNOSIS SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Summary
if [ "$GRAFANA_CLOUD_LOGS_API_KEY" != "$LOGS_PASS" ]; then
    echo -e "${RED}PROBLEM FOUND:${NC} agent.yaml has a different API key than config.env!"
    echo ""
    echo "To fix this, we need to update agent.yaml with the correct key."
    echo ""
    echo "Run this command to fix it:"
    echo ""
    echo -e "${CYAN}sudo sed -i \"s|password: .*|password: ${GRAFANA_CLOUD_LOGS_API_KEY}|g\" /etc/grafana-agent/agent.yaml && sudo systemctl restart grafana-agent${NC}"
else
    echo -e "${GREEN}Keys match in config files.${NC}"
    echo ""
    if [ "$TEST1" != "204" ] && [ "$TEST1" != "200" ]; then
        echo -e "${RED}However, the key doesn't authenticate successfully.${NC}"
        echo "The key might not have logs:write permission."
    fi
fi

echo ""
echo "For more details, check the output above."