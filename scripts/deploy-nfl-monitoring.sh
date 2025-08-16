#!/bin/bash

# Deploy NFL Live Score EPG Updater Monitoring
# Sets up log collection, metrics, and alerting

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
echo -e "${CYAN}  NFL LIVE SCORE MONITORING DEPLOYMENT${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${PROJECT_DIR}/config"

# Load configuration
CONFIG_FILE="${CONFIG_DIR}/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗${NC} Configuration file not found: $CONFIG_FILE"
    echo "Please create it with your Grafana Cloud credentials"
    exit 1
fi

source "$CONFIG_FILE"
echo -e "${GREEN}✓${NC} Configuration loaded"

# Set default Loki URL if not provided
GRAFANA_CLOUD_LOKI_URL=${GRAFANA_CLOUD_LOKI_URL:-"https://logs-prod-021.grafana.net/loki/api/v1/push"}

echo ""
echo -e "${BLUE}1. CHECKING NFL UPDATER SERVICE${NC}"
echo "────────────────────────────────"

# Check if NFL updater service exists
if systemctl list-units --all | grep -q "nfl-updater.service"; then
    echo -e "${GREEN}✓${NC} NFL updater service found"
    
    if systemctl is-active --quiet nfl-updater; then
        echo -e "${GREEN}✓${NC} Service is running"
    else
        echo -e "${YELLOW}⚠${NC} Service is not running"
        echo "  Start it with: sudo systemctl start nfl-updater"
    fi
else
    echo -e "${YELLOW}⚠${NC} NFL updater service not found"
    echo "  This monitoring requires the NFL updater to be installed as a systemd service"
fi

# Check log file
if [ -f /home/emby/py/nfl-updater/nfl_updater.log ]; then
    LOG_SIZE=$(du -h /home/emby/py/nfl-updater/nfl_updater.log | cut -f1)
    echo -e "${GREEN}✓${NC} Log file exists (size: $LOG_SIZE)"
else
    echo -e "${YELLOW}⚠${NC} Log file not found at /home/emby/py/nfl-updater/nfl_updater.log"
fi

echo ""
echo -e "${BLUE}2. BACKING UP CURRENT AGENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [ -f /etc/grafana-agent/agent.yaml ]; then
    sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
    echo -e "${GREEN}✓${NC} Current config backed up"
fi

echo ""
echo -e "${BLUE}3. APPLYING NFL MONITORING CONFIG${NC}"
echo "────────────────────────────────"

# Process the NFL agent config template
export GRAFANA_CLOUD_USER
export GRAFANA_CLOUD_API_KEY
export GRAFANA_CLOUD_PROMETHEUS_URL=${GRAFANA_CLOUD_PROMETHEUS_URL:-"https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push"}
export GRAFANA_CLOUD_LOKI_URL

envsubst < "${CONFIG_DIR}/agent-nfl.yaml" > /tmp/agent-nfl-processed.yaml

# Apply the configuration
sudo cp /tmp/agent-nfl-processed.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} NFL monitoring configuration applied"

echo ""
echo -e "${BLUE}4. SETTING UP LOG PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure grafana-agent can read the log files
if [ -f /home/emby/py/nfl-updater/nfl_updater.log ]; then
    # Add grafana-agent to emby group if needed
    if ! groups grafana-agent 2>/dev/null | grep -q emby; then
        sudo usermod -a -G emby grafana-agent
        echo -e "${GREEN}✓${NC} Added grafana-agent to emby group"
    fi
    
    # Check file permissions
    if [ -r /home/emby/py/nfl-updater/nfl_updater.log ]; then
        echo -e "${GREEN}✓${NC} Log file is readable"
    else
        sudo chmod 644 /home/emby/py/nfl-updater/nfl_updater.log*
        echo -e "${GREEN}✓${NC} Fixed log file permissions"
    fi
fi

# Create positions file directory
sudo mkdir -p /var/lib/grafana-agent
sudo chown grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Positions directory configured"

echo ""
echo -e "${BLUE}5. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent restarted successfully"
else
    echo -e "${RED}✗${NC} Failed to restart Grafana Agent"
    echo "Recent logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}6. VERIFYING LOG COLLECTION${NC}"
echo "────────────────────────────────"

# Wait for agent to start collecting
sleep 10

# Check if logs are being tailed
if sudo journalctl -u grafana-agent --since "1 minute ago" --no-pager | grep -q "nfl-updater"; then
    echo -e "${GREEN}✓${NC} Agent is tailing NFL updater logs"
else
    echo -e "${YELLOW}⚠${NC} No NFL log collection detected yet"
fi

# Check for systemd journal collection
if sudo journalctl -u grafana-agent --since "1 minute ago" --no-pager | grep -q "journal"; then
    echo -e "${GREEN}✓${NC} Systemd journal collection active"
fi

echo ""
echo -e "${BLUE}7. TESTING LOKI INGESTION${NC}"
echo "────────────────────────────────"

# Test Loki connection
LOKI_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "${GRAFANA_CLOUD_LOKI_URL}/ready" 2>/dev/null || echo "000")

if [ "$LOKI_TEST" = "200" ] || [ "$LOKI_TEST" = "204" ]; then
    echo -e "${GREEN}✓${NC} Loki endpoint is accessible"
else
    echo -e "${YELLOW}⚠${NC} Could not verify Loki endpoint (status: $LOKI_TEST)"
fi

echo ""
echo -e "${BLUE}8. SAMPLE LOG ENTRIES${NC}"
echo "────────────────────────────────"

if [ -f /home/emby/py/nfl-updater/nfl_updater.log ]; then
    echo "Recent NFL updater log entries:"
    tail -5 /home/emby/py/nfl-updater/nfl_updater.log | sed 's/^/  /'
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DEPLOYMENT COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Next Steps:${NC}"
echo ""
echo "1. ${YELLOW}Import Dashboard:${NC}"
echo "   • Log into Grafana Cloud"
echo "   • Go to Dashboards > Import"
echo "   • Upload: ${DASHBOARDS_DIR}/nfl-updater-monitoring.json"
echo "   • Select your Prometheus and Loki datasources"
echo ""
echo "2. ${YELLOW}Configure Alerts:${NC}"
echo "   • Go to Alerting > Alert rules"
echo "   • Import rules from: ${CONFIG_DIR}/nfl-alerts.yaml"
echo "   • Configure notification channels (email, Slack, etc.)"
echo ""
echo "3. ${YELLOW}Test Queries in Explore:${NC}"
echo "   ${CYAN}Live games:${NC}"
echo "   {job=\"nfl-updater\"} |= \"Updated:\""
echo ""
echo "   ${CYAN}Errors:${NC}"
echo "   {job=\"nfl-updater\"} |= \"ERROR\""
echo ""
echo "   ${CYAN}Game states:${NC}"
echo "   {job=\"nfl-updater\"} |~ \"LIVE|FINAL|SCHEDULED\""
echo ""
echo "4. ${YELLOW}Monitor Metrics:${NC}"
echo "   • nfl_updater_service_up"
echo "   • nfl_updater_game_score_update"
echo "   • nfl_updater_error_total"
echo "   • nfl_updater_espn_api_duration_seconds"
echo ""
echo -e "${CYAN}Useful Commands:${NC}"
echo "• View agent logs: sudo journalctl -u grafana-agent -f"
echo "• Check NFL service: sudo systemctl status nfl-updater"
echo "• Test log parsing: tail -f /home/emby/py/nfl-updater/nfl_updater.log"
echo "• Agent config: cat /etc/grafana-agent/agent.yaml"
echo ""
echo -e "${YELLOW}Peak Monitoring Times:${NC}"
echo "• Thursday: 8:15 PM - 11:30 PM ET"
echo "• Saturday: All day during season"
echo "• Sunday: 1:00 PM - 11:30 PM ET (peak load)"
echo "• Monday: 8:15 PM - 11:30 PM ET"