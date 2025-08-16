#!/bin/bash

# Check NFL logs setup and troubleshoot issues

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
echo -e "${CYAN}  NFL LOGS DIAGNOSTIC${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}1. CHECKING NFL LOG FILE${NC}"
echo "────────────────────────────────"

NFL_LOG="/var/log/nfl_updater.log"

if [ -f "$NFL_LOG" ]; then
    echo -e "${GREEN}✓${NC} NFL log file exists"
    
    # Check size
    SIZE=$(stat -c%s "$NFL_LOG")
    echo "  Size: $(numfmt --to=iec-i --suffix=B $SIZE 2>/dev/null || echo "$SIZE bytes")"
    
    # Check permissions
    PERMS=$(ls -l "$NFL_LOG" | awk '{print $1}')
    OWNER=$(ls -l "$NFL_LOG" | awk '{print $3}')
    GROUP=$(ls -l "$NFL_LOG" | awk '{print $4}')
    echo "  Permissions: $PERMS"
    echo "  Owner: $OWNER:$GROUP"
    
    # Check if readable by grafana-agent
    if sudo -u grafana-agent test -r "$NFL_LOG" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Readable by grafana-agent"
    else
        echo -e "  ${RED}✗${NC} NOT readable by grafana-agent"
    fi
    
    # Check last modified
    LAST_MOD=$(stat -c %y "$NFL_LOG" | cut -d'.' -f1)
    echo "  Last modified: $LAST_MOD"
    
    # Check line count
    LINES=$(wc -l < "$NFL_LOG")
    echo "  Total lines: $LINES"
    
    # Show last few entries
    echo ""
    echo "Last 3 entries:"
    echo "---"
    tail -3 "$NFL_LOG" | sed 's/^/  /'
    echo "---"
else
    echo -e "${RED}✗${NC} NFL log file NOT FOUND at $NFL_LOG"
    
    # Check alternative locations
    echo ""
    echo "Searching for NFL logs in other locations..."
    
    # Check /var/log for any NFL-related files
    NFL_FILES=$(find /var/log -name "*nfl*" -type f 2>/dev/null | head -5)
    if [ -n "$NFL_FILES" ]; then
        echo "Found these NFL-related files:"
        echo "$NFL_FILES" | sed 's/^/  /'
    else
        echo "No NFL-related files found in /var/log"
    fi
    
    # Check home directories
    for dir in /home/* /root; do
        if [ -d "$dir" ]; then
            NFL_HOME=$(find "$dir" -name "*nfl*" -type f 2>/dev/null | grep -E "\.(log|txt)$" | head -3)
            if [ -n "$NFL_HOME" ]; then
                echo ""
                echo "Found in $dir:"
                echo "$NFL_HOME" | sed 's/^/  /'
            fi
        fi
    done
fi

echo ""
echo -e "${BLUE}2. CHECKING AGENT CONFIGURATION${NC}"
echo "────────────────────────────────"

# Check if NFL job is configured
if sudo grep -q "job_name: nfl_updater" /etc/grafana-agent/agent.yaml; then
    echo -e "${GREEN}✓${NC} NFL job is configured in agent.yaml"
    
    # Show the configuration
    echo ""
    echo "NFL configuration:"
    sudo sed -n '/job_name: nfl_updater/,/job_name:\|^[[:space:]]*$/p' /etc/grafana-agent/agent.yaml | head -10 | sed 's/^/  /'
else
    echo -e "${RED}✗${NC} NFL job NOT configured in agent.yaml"
fi

echo ""
echo -e "${BLUE}3. CHECKING IF AGENT IS READING NFL LOG${NC}"
echo "────────────────────────────────"

AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Agent PID: $AGENT_PID"
    
    # Check open files
    NFL_OPEN=$(sudo lsof -p $AGENT_PID 2>/dev/null | grep -i "nfl" || echo "")
    if [ -n "$NFL_OPEN" ]; then
        echo -e "${GREEN}✓${NC} Agent has NFL log file open:"
        echo "$NFL_OPEN" | awk '{print "  " $9}'
    else
        echo -e "${YELLOW}⚠${NC} Agent is NOT reading any NFL files"
    fi
else
    echo -e "${RED}✗${NC} Grafana agent not running"
fi

echo ""
echo -e "${BLUE}4. CHECKING POSITIONS FILE${NC}"
echo "────────────────────────────────"

POSITIONS="/var/lib/grafana-agent/positions.yaml"
if [ -f "$POSITIONS" ]; then
    if grep -q "nfl" "$POSITIONS"; then
        echo -e "${GREEN}✓${NC} NFL log is being tracked:"
        grep "nfl" "$POSITIONS" | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠${NC} NFL log is NOT in positions file"
        echo "Current positions:"
        cat "$POSITIONS" | sed 's/^/  /'
    fi
else
    echo -e "${RED}✗${NC} Positions file not found"
fi

echo ""
echo -e "${BLUE}5. CREATING TEST NFL LOG ENTRY${NC}"
echo "────────────────────────────────"

if [ -f "$NFL_LOG" ] || [ -w "$(dirname "$NFL_LOG")" ]; then
    echo "Adding test entry to NFL log..."
    
    # Create log file if it doesn't exist
    if [ ! -f "$NFL_LOG" ]; then
        sudo touch "$NFL_LOG"
        sudo chmod 644 "$NFL_LOG"
        echo -e "${GREEN}✓${NC} Created $NFL_LOG"
    fi
    
    # Add test entry
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$TIMESTAMP INFO Test NFL log entry from diagnostic script" | sudo tee -a "$NFL_LOG" > /dev/null
    echo "$TIMESTAMP INFO Game Patriots vs Jets: 21-14 (Q3 5:23)" | sudo tee -a "$NFL_LOG" > /dev/null
    echo "$TIMESTAMP INFO API Response: 200 OK, latency: 145ms" | sudo tee -a "$NFL_LOG" > /dev/null
    
    echo -e "${GREEN}✓${NC} Added test entries to NFL log"
    
    # Set permissions
    sudo chmod 644 "$NFL_LOG"
    echo -e "${GREEN}✓${NC} Set permissions to 644"
else
    echo -e "${RED}✗${NC} Cannot create/write to $NFL_LOG"
fi

echo ""
echo -e "${BLUE}6. RESTARTING AGENT TO PICK UP NFL LOGS${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
echo -e "${GREEN}✓${NC} Agent restarted"

sleep 5

# Check if agent picked up the file
AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    NFL_OPEN=$(sudo lsof -p $AGENT_PID 2>/dev/null | grep -i "nfl" || echo "")
    if [ -n "$NFL_OPEN" ]; then
        echo -e "${GREEN}✓${NC} Agent is now reading NFL log!"
    else
        echo -e "${YELLOW}⚠${NC} Agent still not reading NFL log"
    fi
fi

echo ""
echo -e "${BLUE}7. TESTING NFL LOG QUERY${NC}"
echo "────────────────────────────────"

echo "Wait 30 seconds then check Grafana Explore with:"
echo ""
echo -e "${CYAN}{job=\"nfl_updater\"}${NC}"
echo ""
echo "Or check for the test entries:"
echo -e "${CYAN}{job=\"nfl_updater\"} |= \"Test NFL\"${NC}"
echo -e "${CYAN}{job=\"nfl_updater\"} |= \"Patriots\"${NC}"

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ -f "$NFL_LOG" ]; then
    echo -e "${GREEN}✓${NC} NFL log file exists with test data"
    echo "The agent should now be collecting NFL logs."
else
    echo -e "${YELLOW}⚠${NC} NFL log file was created with test data"
    echo "Check Grafana in 1-2 minutes for the test entries."
fi

echo ""
echo "If NFL logs still don't appear:"
echo "1. Check agent logs: sudo journalctl -u grafana-agent -f | grep -i nfl"
echo "2. Verify path in agent.yaml matches: $NFL_LOG"
echo "3. Check positions file gets updated: watch cat /var/lib/grafana-agent/positions.yaml"