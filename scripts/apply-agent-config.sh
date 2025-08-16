#!/bin/bash

# Apply the correct Grafana Agent configuration
# This script substitutes environment variables and applies the config

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
echo -e "${CYAN}  APPLYING GRAFANA AGENT CONFIGURATION${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load configuration
CONFIG_DIR="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config"
CONFIG_FILE="${CONFIG_DIR}/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗${NC} Configuration file not found: $CONFIG_FILE"
    echo ""
    echo "Please create it with:"
    echo "GRAFANA_CLOUD_USER=your-instance-id"
    echo "GRAFANA_CLOUD_API_KEY=your-api-key"
    echo "GRAFANA_CLOUD_PROMETHEUS_URL=https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push"
    echo "GRAFANA_CLOUD_LOKI_URL=https://logs-prod-021.grafana.net/loki/api/v1/push"
    echo "EMBY_SERVER_URL=http://localhost:8096"
    echo "EMBY_API_KEY=your-emby-api-key"
    exit 1
fi

# Source the configuration
source "$CONFIG_FILE"

echo -e "${GREEN}✓${NC} Configuration loaded"

# Set default values if not provided
GRAFANA_CLOUD_PROMETHEUS_URL=${GRAFANA_CLOUD_PROMETHEUS_URL:-"https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push"}
GRAFANA_CLOUD_LOKI_URL=${GRAFANA_CLOUD_LOKI_URL:-"https://logs-prod-021.grafana.net/loki/api/v1/push"}
EMBY_SERVER_URL=${EMBY_SERVER_URL:-"http://localhost:8096"}

echo ""
echo -e "${BLUE}Configuration values:${NC}"
echo "  User: $GRAFANA_CLOUD_USER"
echo "  Prometheus URL: $GRAFANA_CLOUD_PROMETHEUS_URL"
echo "  Emby URL: $EMBY_SERVER_URL"

echo ""
echo -e "${BLUE}1. FINDING AGENT CONFIG LOCATION${NC}"
echo "────────────────────────────────"

# Determine which config file the agent is using
AGENT_CONFIG_FILE=""
if systemctl show grafana-agent | grep -q "ExecStart.*agent.yaml"; then
    AGENT_CONFIG_FILE="/etc/grafana-agent/agent.yaml"
elif systemctl show grafana-agent | grep -q "ExecStart.*grafana-agent.yaml"; then
    AGENT_CONFIG_FILE="/etc/grafana-agent/grafana-agent.yaml"
else
    # Default to agent.yaml
    AGENT_CONFIG_FILE="/etc/grafana-agent/agent.yaml"
fi

echo "Target config file: $AGENT_CONFIG_FILE"

echo ""
echo -e "${BLUE}2. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

if [ -f "$AGENT_CONFIG_FILE" ]; then
    BACKUP_FILE="${AGENT_CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    sudo cp "$AGENT_CONFIG_FILE" "$BACKUP_FILE"
    echo -e "${GREEN}✓${NC} Backed up to: $BACKUP_FILE"
else
    echo -e "${YELLOW}⚠${NC} No existing config to backup"
fi

echo ""
echo -e "${BLUE}3. GENERATING NEW CONFIG${NC}"
echo "────────────────────────────────"

# Create temporary file with substituted values
TEMP_CONFIG="/tmp/agent-config-processed.yaml"

# Export variables for envsubst
export GRAFANA_CLOUD_USER
export GRAFANA_CLOUD_API_KEY
export GRAFANA_CLOUD_PROMETHEUS_URL
export GRAFANA_CLOUD_LOKI_URL
export EMBY_SERVER_URL
export EMBY_API_KEY

# Process the template
envsubst < "${CONFIG_DIR}/agent.yaml" > "$TEMP_CONFIG"

echo -e "${GREEN}✓${NC} Configuration generated with environment variables"

echo ""
echo -e "${BLUE}4. VALIDATING CONFIG${NC}"
echo "────────────────────────────────"

# Basic validation
if grep -q "your-instance-id" "$TEMP_CONFIG"; then
    echo -e "${RED}✗${NC} Config still contains placeholder values!"
    echo "  Please check your config.env file"
    exit 1
fi

if ! grep -q "scrape_configs:" "$TEMP_CONFIG"; then
    echo -e "${RED}✗${NC} No scrape_configs section found!"
    exit 1
fi

if ! grep -q "remote_write:" "$TEMP_CONFIG"; then
    echo -e "${RED}✗${NC} No remote_write section found!"
    exit 1
fi

echo -e "${GREEN}✓${NC} Configuration validation passed"

echo ""
echo -e "${BLUE}5. APPLYING NEW CONFIG${NC}"
echo "────────────────────────────────"

# Create directory if it doesn't exist
sudo mkdir -p /etc/grafana-agent

# Apply the config
sudo cp "$TEMP_CONFIG" "$AGENT_CONFIG_FILE"
sudo chmod 644 "$AGENT_CONFIG_FILE"
sudo chown root:root "$AGENT_CONFIG_FILE"

echo -e "${GREEN}✓${NC} Configuration applied to: $AGENT_CONFIG_FILE"

echo ""
echo -e "${BLUE}6. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

# Stop the agent
sudo systemctl stop grafana-agent
echo "Agent stopped"

# Clear any cache
sudo rm -f /tmp/wal/* 2>/dev/null || true

# Start the agent
sudo systemctl start grafana-agent
sleep 3

# Check status
if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent started successfully"
else
    echo -e "${RED}✗${NC} Failed to start Grafana Agent"
    echo ""
    echo "Recent logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}7. VERIFYING OPERATION${NC}"
echo "────────────────────────────────"

# Wait for agent to initialize
echo "Waiting for agent to initialize..."
sleep 10

# Check if agent is scraping
echo ""
echo "Checking scrape targets..."
AGENT_METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null || echo "")

if [ -n "$AGENT_METRICS" ]; then
    # Check for up metrics
    echo "$AGENT_METRICS" | grep '^up{' | while read -r line; do
        JOB=$(echo "$line" | grep -oE 'job="[^"]*"' | sed 's/job="//;s/"//')
        VALUE=$(echo "$line" | grep -oE '[0-9]+$')
        if [ "$VALUE" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} $JOB is UP"
        else
            echo -e "  ${RED}✗${NC} $JOB is DOWN"
        fi
    done
else
    echo -e "${YELLOW}⚠${NC} Cannot access agent metrics endpoint"
fi

# Check recent logs for errors
echo ""
echo "Checking for errors..."
ERROR_COUNT=$(sudo journalctl -u grafana-agent --since="1 minute ago" --no-pager 2>/dev/null | grep -c "level=error" || echo "0")

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}✗${NC} Found $ERROR_COUNT errors in recent logs:"
    sudo journalctl -u grafana-agent --since="1 minute ago" --no-pager | grep "level=error" | head -3
else
    echo -e "${GREEN}✓${NC} No errors in recent logs"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  CONFIGURATION APPLIED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Next steps:${NC}"
echo "1. Wait 2-3 minutes for metrics to appear in Grafana Cloud"
echo "2. Check your dashboard: ${GRAFANA_CLOUD_URL:-https://grafana.com}"
echo "3. Run diagnostics if needed: ./scripts/debug-agent.sh"
echo ""

echo -e "${CYAN}Useful commands:${NC}"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• Check config: cat $AGENT_CONFIG_FILE"
echo "• Test metrics: curl http://localhost:9119/metrics | head"
echo "• Agent metrics: curl http://localhost:12345/metrics | grep up"
echo "• Restore backup: sudo cp $BACKUP_FILE $AGENT_CONFIG_FILE"