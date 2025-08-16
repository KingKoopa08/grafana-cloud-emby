#!/bin/bash

# Verify and fix NFL log collection
# Ensures logs are being collected with proper labels

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
echo -e "${CYAN}  VERIFY NFL LOG COLLECTION${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. CHECKING CURRENT AGENT CONFIG${NC}"
echo "────────────────────────────────"

# Check what's in the current config
if grep -q "nfl-updater" /etc/grafana-agent/agent.yaml 2>/dev/null; then
    echo -e "${GREEN}✓${NC} NFL job found in config"
    
    # Show the path being monitored
    NFL_PATH=$(grep -A5 "job_name: nfl-updater" /etc/grafana-agent/agent.yaml | grep "__path__" | sed 's/.*__path__: //')
    echo "  Configured path: $NFL_PATH"
else
    echo -e "${RED}✗${NC} NFL job NOT found in config!"
fi

echo ""
echo -e "${BLUE}2. CHECKING NFL LOG FILES${NC}"
echo "────────────────────────────────"

# Check all possible NFL log locations
echo "Looking for NFL logs..."
if [ -f /var/log/nfl_updater.log ]; then
    echo -e "${GREEN}✓${NC} Found: /var/log/nfl_updater.log"
    echo "  Size: $(du -h /var/log/nfl_updater.log | cut -f1)"
    echo "  Modified: $(stat -c %y /var/log/nfl_updater.log | cut -d. -f1)"
    echo "  Readable by agent: $(sudo -u grafana-agent test -r /var/log/nfl_updater.log && echo "Yes" || echo "No")"
fi

if [ -d /var/log/nfl-updater ]; then
    echo -e "${GREEN}✓${NC} Found directory: /var/log/nfl-updater"
    ls -la /var/log/nfl-updater/*.log 2>/dev/null | sed 's/^/  /'
fi

echo ""
echo -e "${BLUE}3. CHECKING AGENT PROCESS${NC}"
echo "────────────────────────────────"

# Check if agent is tailing the NFL log
AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Agent PID: $AGENT_PID"
    
    # Check open files
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "nfl"; then
        echo -e "${GREEN}✓${NC} Agent is reading NFL logs"
        sudo lsof -p $AGENT_PID 2>/dev/null | grep "nfl" | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠${NC} Agent is NOT reading NFL logs"
    fi
fi

echo ""
echo -e "${BLUE}4. CHECKING POSITIONS FILE${NC}"
echo "────────────────────────────────"

POSITIONS_FILE="/var/lib/grafana-agent/positions.yaml"
if [ -f "$POSITIONS_FILE" ]; then
    echo -e "${GREEN}✓${NC} Positions file exists"
    
    # Check if NFL log is tracked
    if grep -q "nfl" "$POSITIONS_FILE" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} NFL log position is tracked"
        grep -A2 "nfl" "$POSITIONS_FILE" | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠${NC} NFL log not in positions file"
    fi
else
    echo -e "${RED}✗${NC} Positions file not found"
fi

echo ""
echo -e "${BLUE}5. TESTING QUERIES${NC}"
echo "────────────────────────────────"

echo "Run these queries in Grafana Explore to test:"
echo ""
echo -e "${CYAN}Check for any job label:${NC}"
echo '{job=~".+"}'
echo ""
echo -e "${CYAN}Check for NFL job specifically:${NC}"
echo '{job="nfl-updater"}'
echo ""
echo -e "${CYAN}Check for filename containing nfl:${NC}"
echo '{filename=~".*nfl.*"}'
echo ""
echo -e "${CYAN}Check all recent logs:${NC}"
echo '{} |= "Game"'

echo ""
echo -e "${BLUE}6. AGENT LOGS${NC}"
echo "────────────────────────────────"

echo "Recent agent logs mentioning NFL or logs:"
sudo journalctl -u grafana-agent --since "5 minutes ago" --no-pager | grep -E "(nfl|log|tail)" | tail -10 | sed 's/^/  /' || echo "  No relevant logs found"

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DIAGNOSIS${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Provide diagnosis
if ! grep -q "nfl-updater" /etc/grafana-agent/agent.yaml 2>/dev/null; then
    echo -e "${RED}Problem:${NC} NFL job not configured in agent"
    echo ""
    echo -e "${YELLOW}Solution:${NC}"
    echo "Run: sudo ./scripts/fix-nfl-yaml-error.sh"
elif ! sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "nfl"; then
    echo -e "${YELLOW}Problem:${NC} Agent configured but not reading NFL logs"
    echo ""
    echo -e "${YELLOW}Possible causes:${NC}"
    echo "• Permission issue"
    echo "• Path doesn't exist"
    echo "• Agent needs restart"
    echo ""
    echo -e "${YELLOW}Solution:${NC}"
    echo "sudo systemctl restart grafana-agent"
else
    echo -e "${GREEN}Status:${NC} NFL logs should be collecting"
    echo ""
    echo "If you don't see them in Grafana:"
    echo "• Wait 2-3 minutes for data to appear"
    echo "• Check the datasource is correct"
    echo "• Try a broader query like {} |= \"Game\""
fi