#!/bin/bash

# Test script to verify logs are flowing to Grafana Cloud
# Run after add-logs-with-new-key.sh

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
echo -e "${CYAN}  TEST LOG FLOW TO GRAFANA CLOUD${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found"
    exit 1
fi

# The logs API key - should be set in environment
# If not provided, use the main API key (assuming it has logs:write permission)
LOGS_API_KEY="${GRAFANA_CLOUD_LOGS_API_KEY:-${GRAFANA_CLOUD_API_KEY:-}}"

if [ -z "$LOGS_API_KEY" ]; then
    echo -e "${YELLOW}⚠${NC} No logs API key found, using metrics key"
    LOGS_API_KEY="${GRAFANA_CLOUD_API_KEY}"
fi

echo ""
echo -e "${BLUE}1. CHECKING AGENT STATUS${NC}"
echo "────────────────────────────────"

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent is running"
    UPTIME=$(systemctl show grafana-agent --property=ActiveEnterTimestamp --value)
    echo "  Started: $UPTIME"
else
    echo -e "${RED}✗${NC} Grafana Agent is not running"
    echo "  Run: sudo systemctl start grafana-agent"
    exit 1
fi

echo ""
echo -e "${BLUE}2. CHECKING LOG FILES${NC}"
echo "────────────────────────────────"

LOG_COUNT=0

# Check Emby logs
if [ -f /var/lib/emby/logs/embyserver.txt ]; then
    EMBY_SIZE=$(stat -c%s /var/lib/emby/logs/embyserver.txt)
    EMBY_LINES=$(wc -l < /var/lib/emby/logs/embyserver.txt)
    echo -e "${GREEN}✓${NC} Emby log exists"
    echo "  Size: $(numfmt --to=iec-i --suffix=B $EMBY_SIZE)"
    echo "  Lines: $EMBY_LINES"
    LOG_COUNT=$((LOG_COUNT + 1))
    
    # Show last log entry
    LAST_EMBY=$(tail -1 /var/lib/emby/logs/embyserver.txt | head -c 100)
    echo "  Last entry: ${LAST_EMBY}..."
else
    echo -e "${YELLOW}⚠${NC} Emby log not found"
fi

# Check NFL logs
if [ -f /var/log/nfl_updater.log ]; then
    NFL_SIZE=$(stat -c%s /var/log/nfl_updater.log 2>/dev/null || echo "0")
    NFL_LINES=$(wc -l < /var/log/nfl_updater.log 2>/dev/null || echo "0")
    echo -e "${GREEN}✓${NC} NFL log exists"
    echo "  Size: $(numfmt --to=iec-i --suffix=B $NFL_SIZE 2>/dev/null || echo "0B")"
    echo "  Lines: $NFL_LINES"
    LOG_COUNT=$((LOG_COUNT + 1))
    
    if [ "$NFL_LINES" -gt 0 ]; then
        LAST_NFL=$(tail -1 /var/log/nfl_updater.log | head -c 100)
        echo "  Last entry: ${LAST_NFL}..."
    fi
else
    echo -e "${YELLOW}⚠${NC} NFL log not found at /var/log/nfl_updater.log"
fi

echo ""
echo -e "${BLUE}3. CHECKING AGENT FILE HANDLES${NC}"
echo "────────────────────────────────"

AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Agent PID: $AGENT_PID"
    
    OPEN_FILES=$(sudo lsof -p $AGENT_PID 2>/dev/null | wc -l)
    echo "Open files: $OPEN_FILES"
    
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "embyserver.txt"; then
        echo -e "${GREEN}✓${NC} Agent is reading Emby logs"
    else
        echo -e "${YELLOW}⚠${NC} Agent not reading Emby logs"
    fi
    
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "nfl_updater.log"; then
        echo -e "${GREEN}✓${NC} Agent is reading NFL logs"
    else
        echo -e "${YELLOW}⚠${NC} Agent not reading NFL logs"
    fi
fi

echo ""
echo -e "${BLUE}4. CHECKING POSITIONS FILE${NC}"
echo "────────────────────────────────"

if [ -f /var/lib/grafana-agent/positions.yaml ]; then
    echo -e "${GREEN}✓${NC} Positions file exists"
    
    # Check if positions are being updated
    POS_MOD=$(stat -c %Y /var/lib/grafana-agent/positions.yaml)
    NOW=$(date +%s)
    AGE=$((NOW - POS_MOD))
    
    if [ $AGE -lt 300 ]; then
        echo -e "${GREEN}✓${NC} Positions updated ${AGE}s ago"
    else
        echo -e "${YELLOW}⚠${NC} Positions not updated for ${AGE}s"
    fi
    
    echo ""
    echo "Current positions:"
    cat /var/lib/grafana-agent/positions.yaml | head -10 | sed 's/^/  /'
else
    echo -e "${YELLOW}⚠${NC} Positions file not found"
fi

echo ""
echo -e "${BLUE}5. CHECKING RECENT ERRORS${NC}"
echo "────────────────────────────────"

# Check for authentication errors
AUTH_ERRORS=$(sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "401" || echo "0")
if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗${NC} Found $AUTH_ERRORS authentication errors in last 5 minutes"
    echo "Recent 401 errors:"
    sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager | grep "401" | tail -3 | sed 's/^/  /'
else
    echo -e "${GREEN}✓${NC} No authentication errors in last 5 minutes"
fi

# Check for other errors
OTHER_ERRORS=$(sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "level=error" || echo "0")
if [ "$OTHER_ERRORS" -gt 0 ]; then
    echo -e "${YELLOW}⚠${NC} Found $OTHER_ERRORS other errors in last 5 minutes"
    sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager | grep "level=error" | tail -3 | sed 's/^/  /'
else
    echo -e "${GREEN}✓${NC} No other errors in last 5 minutes"
fi

echo ""
echo -e "${BLUE}6. TESTING LOKI QUERY${NC}"
echo "────────────────────────────────"

# Detect the correct Loki URL
if [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-36"* ]] || [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-us-west-0"* ]]; then
    LOKI_URL="https://logs-prod-021.grafana.net"
elif [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-10"* ]] || [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-us-central"* ]]; then
    LOKI_URL="https://logs-prod-006.grafana.net"
elif [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-13"* ]] || [[ "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" == *"prod-eu"* ]]; then
    LOKI_URL="https://logs-prod-eu-west-0.grafana.net"
else
    LOKI_URL="https://logs-prod-021.grafana.net"
fi

echo "Querying Loki for recent logs..."
echo "Loki URL: $LOKI_URL"

# Query for any logs in the last hour
QUERY_TIME=$(date -u -d '1 hour ago' +%s%N)
QUERY_RESULT=$(curl -s -G "${LOKI_URL}/loki/api/v1/query_range" \
    --data-urlencode "query={job=~\".+\"}" \
    --data-urlencode "start=$QUERY_TIME" \
    --data-urlencode "limit=10" \
    -u "${GRAFANA_CLOUD_USER}:${LOGS_API_KEY}" 2>/dev/null || echo '{"status":"error"}')

if echo "$QUERY_RESULT" | grep -q '"status":"success"'; then
    echo -e "${GREEN}✓${NC} Loki query successful"
    
    # Count results
    RESULT_COUNT=$(echo "$QUERY_RESULT" | grep -o '"stream"' | wc -l)
    if [ $RESULT_COUNT -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Found $RESULT_COUNT log streams"
        
        # Show job names
        echo "Log jobs found:"
        echo "$QUERY_RESULT" | grep -o '"job":"[^"]*"' | cut -d'"' -f4 | sort -u | sed 's/^/  • /'
    else
        echo -e "${YELLOW}⚠${NC} No logs found in Loki yet"
        echo "  Logs may take 2-3 minutes to appear"
    fi
else
    echo -e "${RED}✗${NC} Loki query failed"
    echo "$QUERY_RESULT" | head -c 200
fi

echo ""
echo -e "${BLUE}7. CHECKING LOG BATCHES${NC}"
echo "────────────────────────────────"

# Check if agent is sending batches
BATCH_COUNT=$(sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "batch" || echo "0")
if [ $BATCH_COUNT -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Agent sent $BATCH_COUNT log batches in last 5 minutes"
    
    # Show recent batch info
    echo "Recent batch activity:"
    sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager | grep "batch" | tail -3 | sed 's/^/  /'
else
    echo -e "${YELLOW}⚠${NC} No log batches sent in last 5 minutes"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  TEST SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Summarize status
ISSUES=0

if [ "$AUTH_ERRORS" -gt 0 ]; then
    echo -e "${RED}✗ Authentication issues detected${NC}"
    ISSUES=$((ISSUES + 1))
else
    echo -e "${GREEN}✓ Authentication working${NC}"
fi

if [ $LOG_COUNT -eq 0 ]; then
    echo -e "${YELLOW}⚠ No log files found${NC}"
    ISSUES=$((ISSUES + 1))
else
    echo -e "${GREEN}✓ $LOG_COUNT log file(s) found${NC}"
fi

if [ $BATCH_COUNT -eq 0 ]; then
    echo -e "${YELLOW}⚠ No recent log batches${NC}"
    ISSUES=$((ISSUES + 1))
else
    echo -e "${GREEN}✓ Logs being sent to Grafana${NC}"
fi

echo ""
if [ $ISSUES -eq 0 ]; then
    echo -e "${GREEN}SUCCESS: Everything appears to be working!${NC}"
    echo ""
    echo "Your logs should be visible in Grafana Cloud."
    echo "Test with these queries in Explore:"
    echo ""
    echo "  {job=\"embyserver\"}"
    echo "  {job=\"nfl_updater\"}"
    echo "  {job=~\".+\"}"
else
    echo -e "${YELLOW}WARNING: Found $ISSUES potential issue(s)${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Wait 2-3 minutes for logs to appear"
    echo "2. Check agent logs: sudo journalctl -u grafana-agent -f"
    echo "3. Verify API key has logs:write permission"
    echo "4. Run: sudo ./scripts/add-logs-with-new-key.sh"
fi

echo ""
echo -e "${CYAN}Useful commands:${NC}"
echo "• Monitor agent: sudo journalctl -u grafana-agent -f"
echo "• Check config: cat /etc/grafana-agent/agent.yaml | grep -A10 logs"
echo "• Force restart: sudo systemctl restart grafana-agent"