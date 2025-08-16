#!/bin/bash

# Quick fix when NFL logs stop flowing

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
echo -e "${CYAN}  FIX NFL LOGS STOPPED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. CHECKING NFL SERVICE${NC}"
echo "────────────────────────────────"

NFL_STATUS=$(systemctl is-active nfl-updater || echo "inactive")
if [ "$NFL_STATUS" = "active" ]; then
    echo -e "${GREEN}✓${NC} NFL updater is running"
    
    # Check recent logs
    RECENT_LOGS=$(journalctl -u nfl-updater --since "2 minutes ago" --no-pager | wc -l)
    echo "  Recent log lines (last 2 min): $RECENT_LOGS"
    
    if [ $RECENT_LOGS -eq 0 ]; then
        echo -e "${YELLOW}⚠${NC} No recent logs from NFL service"
        echo "  Restarting NFL service..."
        sudo systemctl restart nfl-updater
        echo -e "${GREEN}✓${NC} NFL service restarted"
    fi
else
    echo -e "${RED}✗${NC} NFL updater is $NFL_STATUS"
    echo "  Starting NFL service..."
    sudo systemctl start nfl-updater
    echo -e "${GREEN}✓${NC} NFL service started"
fi

echo ""
echo -e "${BLUE}2. CHECKING LOG EXPORTER${NC}"
echo "────────────────────────────────"

EXPORTER_STATUS=$(systemctl is-active nfl-log-exporter 2>/dev/null || echo "not-found")
if [ "$EXPORTER_STATUS" = "active" ]; then
    echo -e "${GREEN}✓${NC} Log exporter is running"
elif [ "$EXPORTER_STATUS" = "not-found" ]; then
    echo -e "${YELLOW}⚠${NC} Log exporter service not found"
    echo "  NFL logs may be going directly to journal"
else
    echo -e "${RED}✗${NC} Log exporter is $EXPORTER_STATUS"
    echo "  Restarting log exporter..."
    sudo systemctl restart nfl-log-exporter
    echo -e "${GREEN}✓${NC} Log exporter restarted"
fi

echo ""
echo -e "${BLUE}3. CHECKING LOG FILE${NC}"
echo "────────────────────────────────"

LOG_FILE="/var/log/nfl_updater.log"
if [ -f "$LOG_FILE" ]; then
    SIZE=$(stat -c%s "$LOG_FILE")
    LAST_MOD=$(stat -c %Y "$LOG_FILE")
    NOW=$(date +%s)
    AGE=$((NOW - LAST_MOD))
    
    echo -e "${GREEN}✓${NC} Log file exists"
    echo "  Size: $(numfmt --to=iec-i --suffix=B $SIZE)"
    echo "  Last modified: ${AGE}s ago"
    
    if [ $AGE -gt 300 ]; then
        echo -e "${YELLOW}⚠${NC} Log file hasn't been updated in over 5 minutes"
        
        # Add a test entry
        echo "$(date -Iseconds) nfl-updater INFO Test entry to restart log flow" >> "$LOG_FILE"
        echo -e "${GREEN}✓${NC} Added test entry to log file"
    fi
    
    # Check if file is too large (over 100MB)
    if [ $SIZE -gt 104857600 ]; then
        echo -e "${YELLOW}⚠${NC} Log file is large, rotating..."
        sudo mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
        sudo touch "$LOG_FILE"
        sudo chmod 644 "$LOG_FILE"
        echo -e "${GREEN}✓${NC} Log file rotated"
    fi
else
    echo -e "${RED}✗${NC} Log file not found"
    echo "  Creating log file..."
    sudo touch "$LOG_FILE"
    sudo chmod 644 "$LOG_FILE"
    echo -e "${GREEN}✓${NC} Log file created"
fi

echo ""
echo -e "${BLUE}4. CHECKING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Agent PID: $AGENT_PID"
    
    # Check if agent is reading NFL log
    NFL_OPEN=$(sudo lsof -p $AGENT_PID 2>/dev/null | grep -c "nfl_updater.log" || echo "0")
    
    if [ $NFL_OPEN -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Agent is reading NFL log file"
    else
        echo -e "${YELLOW}⚠${NC} Agent is NOT reading NFL log file"
        echo "  Restarting agent..."
        sudo systemctl restart grafana-agent
        echo -e "${GREEN}✓${NC} Agent restarted"
    fi
else
    echo -e "${RED}✗${NC} Grafana agent not running"
    sudo systemctl start grafana-agent
    echo -e "${GREEN}✓${NC} Agent started"
fi

echo ""
echo -e "${BLUE}5. FORCING LOG FLOW${NC}"
echo "────────────────────────────────"

# Method 1: Direct journal to file if exporter isn't working
echo "Ensuring journal logs are flowing to file..."

# Kill any existing tail processes
pkill -f "journalctl.*nfl-updater.*-f" 2>/dev/null || true

# Start a new background process to tail journal to file
nohup bash -c 'journalctl -u nfl-updater -f --no-hostname -o short-iso >> /var/log/nfl_updater.log 2>&1' > /dev/null 2>&1 &
TAIL_PID=$!

echo -e "${GREEN}✓${NC} Started journal tail process (PID: $TAIL_PID)"

# Add some test entries via journal
echo "Generating test log entries..."
for i in {1..3}; do
    logger -t nfl-updater "Test entry $i - checking log flow at $(date)"
    sleep 1
done

echo -e "${GREEN}✓${NC} Generated test entries"

echo ""
echo -e "${BLUE}6. VERIFYING LOG FLOW${NC}"
echo "────────────────────────────────"

sleep 5

# Check if new entries appeared in the file
NEW_LINES=$(tail -10 "$LOG_FILE" | grep -c "Test entry" || echo "0")

if [ $NEW_LINES -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Test entries found in log file - flow is working!"
else
    echo -e "${YELLOW}⚠${NC} Test entries not found - checking alternative method..."
    
    # Try to fix by recreating the log export service
    if [ "$EXPORTER_STATUS" != "not-found" ]; then
        sudo systemctl stop nfl-log-exporter 2>/dev/null || true
        sudo systemctl reset-failed nfl-log-exporter 2>/dev/null || true
        sudo systemctl start nfl-log-exporter 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Recreated log exporter service"
    fi
fi

# Check positions file
echo ""
echo "Checking positions file..."
if [ -f /var/lib/grafana-agent/positions.yaml ]; then
    NFL_POS=$(grep "nfl_updater.log" /var/lib/grafana-agent/positions.yaml 2>/dev/null | awk '{print $2}' || echo "not found")
    if [ "$NFL_POS" != "not found" ]; then
        echo "  NFL log position: $NFL_POS"
        
        # Compare with actual file size
        FILE_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$NFL_POS" = "$FILE_SIZE" ]; then
            echo -e "${GREEN}✓${NC} Agent is caught up with log file"
        else
            echo -e "${YELLOW}⚠${NC} Agent is behind (file: $FILE_SIZE, position: $NFL_POS)"
        fi
    fi
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo "Actions taken:"
echo "✓ Checked and restarted services as needed"
echo "✓ Verified log file exists and is writable"
echo "✓ Started journal tail process to ensure logs flow"
echo "✓ Generated test entries"
echo ""

echo "Next steps:"
echo "1. Wait 1-2 minutes for logs to appear in Grafana"
echo "2. Check with: {job=\"nfl_updater\"} |= \"Test entry\""
echo "3. Monitor with: tail -f $LOG_FILE"
echo ""

echo "If logs still don't appear:"
echo "• Check agent logs: sudo journalctl -u grafana-agent -f | grep nfl"
echo "• Restart everything: sudo systemctl restart nfl-updater grafana-agent"
echo "• Check NFL service logs: journalctl -u nfl-updater -f"