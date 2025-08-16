#!/bin/bash

# Comprehensive debug script for Grafana Agent issues
# This provides deep diagnostics for scraping and remote write problems

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
echo -e "${CYAN}  GRAFANA AGENT DEEP DEBUG${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

echo -e "${BLUE}1. AGENT PROCESS ANALYSIS${NC}"
echo "────────────────────────────────"

# Get detailed agent process info
if pgrep grafana-agent > /dev/null; then
    echo -e "${GREEN}✓${NC} Grafana Agent is running"
    
    # Get process details
    PID=$(pgrep grafana-agent | head -1)
    echo "  PID: $PID"
    
    # Get command line
    CMD=$(ps -p $PID -o args= || echo "Unknown")
    echo "  Command: $CMD"
    
    # Get config file from command
    CONFIG_FILE=$(echo "$CMD" | grep -oE '(agent\.yaml|grafana-agent\.yaml)' | head -1 || echo "agent.yaml")
    CONFIG_PATH="/etc/grafana-agent/$CONFIG_FILE"
    echo "  Config: $CONFIG_PATH"
    
    # Get memory usage
    MEM=$(ps -p $PID -o rss= || echo "0")
    MEM_MB=$((MEM / 1024))
    echo "  Memory: ${MEM_MB}MB"
    
    # Get CPU usage
    CPU=$(ps -p $PID -o %cpu= || echo "0")
    echo "  CPU: ${CPU}%"
    
    # Get uptime
    UPTIME=$(ps -p $PID -o etime= || echo "Unknown")
    echo "  Uptime: $UPTIME"
else
    echo -e "${RED}✗${NC} Grafana Agent is not running!"
fi

echo ""
echo -e "${BLUE}2. CONFIGURATION VALIDATION${NC}"
echo "────────────────────────────────"

if [ -f "$CONFIG_PATH" ]; then
    echo -e "${GREEN}✓${NC} Config file exists: $CONFIG_PATH"
    
    # Check for required sections
    echo ""
    echo "Checking configuration sections:"
    
    if grep -q "metrics:" "$CONFIG_PATH"; then
        echo -e "  ${GREEN}✓${NC} metrics section found"
    else
        echo -e "  ${RED}✗${NC} metrics section missing"
    fi
    
    if grep -q "remote_write:" "$CONFIG_PATH"; then
        echo -e "  ${GREEN}✓${NC} remote_write section found"
    else
        echo -e "  ${RED}✗${NC} remote_write section missing"
    fi
    
    if grep -q "scrape_configs:" "$CONFIG_PATH"; then
        echo -e "  ${GREEN}✓${NC} scrape_configs section found"
        
        # List all job names
        echo ""
        echo "Configured scrape jobs:"
        grep "job_name:" "$CONFIG_PATH" | sed 's/.*job_name:/  •/' || echo "  None found"
    else
        echo -e "  ${RED}✗${NC} scrape_configs section missing"
    fi
    
    # Check for Emby jobs
    echo ""
    if grep -q "localhost:9119" "$CONFIG_PATH"; then
        echo -e "${GREEN}✓${NC} Live TV Ultimate exporter target found (port 9119)"
    else
        echo -e "${YELLOW}⚠${NC} Live TV Ultimate exporter target not found"
    fi
    
    if grep -q "localhost:9101" "$CONFIG_PATH"; then
        echo -e "${GREEN}✓${NC} Basic Emby exporter target found (port 9101)"
    else
        echo -e "${YELLOW}⚠${NC} Basic Emby exporter target not found"
    fi
else
    echo -e "${RED}✗${NC} Config file not found: $CONFIG_PATH"
fi

echo ""
echo -e "${BLUE}3. NETWORK CONNECTIVITY${NC}"
echo "────────────────────────────────"

# Check local exporters
echo "Local exporter endpoints:"
for PORT in 9119 9101 9100; do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/metrics" | grep -q "200"; then
        METRICS=$(curl -s "http://localhost:$PORT/metrics" | wc -l)
        echo -e "  ${GREEN}✓${NC} Port $PORT: Responding ($METRICS lines)"
    else
        echo -e "  ${RED}✗${NC} Port $PORT: Not responding"
    fi
done

# Check agent metrics endpoint
echo ""
echo "Agent metrics endpoint:"
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:12345/metrics" | grep -q "200"; then
    echo -e "  ${GREEN}✓${NC} Agent metrics available at :12345"
else
    echo -e "  ${RED}✗${NC} Agent metrics not accessible"
fi

# Check Grafana Cloud connectivity
echo ""
echo "Grafana Cloud connectivity:"
if curl -s -o /dev/null -w "%{http_code}" \
    -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=up" | grep -q "200"; then
    echo -e "  ${GREEN}✓${NC} Can connect to Grafana Cloud"
else
    echo -e "  ${RED}✗${NC} Cannot connect to Grafana Cloud"
fi

echo ""
echo -e "${BLUE}4. SCRAPING STATUS${NC}"
echo "────────────────────────────────"

# Get agent metrics if available
AGENT_METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null || echo "")

if [ -n "$AGENT_METRICS" ]; then
    echo "Target discovery:"
    DISCOVERED=$(echo "$AGENT_METRICS" | grep 'prometheus_sd_discovered_targets' | grep -oE '[0-9]+$' | head -1 || echo "0")
    echo "  Discovered targets: $DISCOVERED"
    
    echo ""
    echo "Scrape results by job:"
    echo "$AGENT_METRICS" | grep '^up{' | while read -r line; do
        JOB=$(echo "$line" | grep -oE 'job="[^"]*"' | sed 's/job="/  • /;s/"//')
        VALUE=$(echo "$line" | grep -oE '[0-9]+$')
        if [ "$VALUE" = "1" ]; then
            echo -e "${GREEN}✓${NC} $JOB: UP"
        else
            echo -e "${RED}✗${NC} $JOB: DOWN"
        fi
    done
    
    echo ""
    echo "Scrape statistics:"
    TOTAL_SCRAPED=$(echo "$AGENT_METRICS" | grep 'prometheus_target_scrapes_exceeded_sample_limit_total' | grep -oE '[0-9]+$' | head -1 || echo "0")
    SAMPLE_LIMIT=$(echo "$AGENT_METRICS" | grep 'prometheus_target_scrapes_sample_limit' | grep -oE '[0-9]+$' | head -1 || echo "0")
    echo "  Sample limit exceeded: $TOTAL_SCRAPED times"
    if [ "$SAMPLE_LIMIT" -gt 0 ]; then
        echo "  Sample limit: $SAMPLE_LIMIT"
    fi
    
    # Check for scrape errors
    SCRAPE_ERRORS=$(echo "$AGENT_METRICS" | grep 'prometheus_target_scrape_pool_exceeded_target_limit_total' | grep -oE '[0-9]+$' | head -1 || echo "0")
    if [ "$SCRAPE_ERRORS" -gt 0 ]; then
        echo -e "  ${RED}✗${NC} Scrape errors: $SCRAPE_ERRORS"
    fi
else
    echo -e "${YELLOW}⚠${NC} Cannot access agent metrics for detailed analysis"
fi

echo ""
echo -e "${BLUE}5. REMOTE WRITE STATUS${NC}"
echo "────────────────────────────────"

# Check recent logs
echo "Checking recent logs for remote write status..."

# Get last 5 minutes of logs
RECENT_LOGS=$(sudo journalctl -u grafana-agent --since="5 minutes ago" --no-pager 2>/dev/null || echo "")

if [ -n "$RECENT_LOGS" ]; then
    # Count different log types
    INFO_COUNT=$(echo "$RECENT_LOGS" | grep -c "level=info" || echo "0")
    WARN_COUNT=$(echo "$RECENT_LOGS" | grep -c "level=warn" || echo "0")
    ERROR_COUNT=$(echo "$RECENT_LOGS" | grep -c "level=error" || echo "0")
    
    echo "  Info messages: $INFO_COUNT"
    echo "  Warnings: $WARN_COUNT"
    echo "  Errors: $ERROR_COUNT"
    
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${RED}Recent errors:${NC}"
        echo "$RECENT_LOGS" | grep "level=error" | tail -3 | sed 's/^/  /'
    fi
    
    # Check for specific remote write issues
    if echo "$RECENT_LOGS" | grep -q "401"; then
        echo -e "${RED}✗${NC} Authentication errors detected (401)"
        echo "  Check your GRAFANA_CLOUD_USER and GRAFANA_CLOUD_API_KEY"
    fi
    
    if echo "$RECENT_LOGS" | grep -q "404"; then
        echo -e "${RED}✗${NC} Endpoint not found errors (404)"
        echo "  Check your remote_write URL"
    fi
    
    if echo "$RECENT_LOGS" | grep -q "connection refused"; then
        echo -e "${RED}✗${NC} Connection refused errors"
        echo "  Check network connectivity and firewall rules"
    fi
    
    if echo "$RECENT_LOGS" | grep -q "deadline exceeded"; then
        echo -e "${YELLOW}⚠${NC} Timeout errors detected"
        echo "  Metrics may be delayed"
    fi
else
    echo -e "${YELLOW}⚠${NC} Cannot access agent logs"
fi

echo ""
echo -e "${BLUE}6. LIVE DIAGNOSTICS${NC}"
echo "────────────────────────────────"

echo "Starting 30-second live monitoring..."
echo "(Press Ctrl+C to stop early)"
echo ""

# Start background log monitoring
(sudo journalctl -u grafana-agent -f --no-pager 2>/dev/null | while read -r line; do
    if echo "$line" | grep -q "error"; then
        echo -e "${RED}ERROR:${NC} $line"
    elif echo "$line" | grep -q "warn"; then
        echo -e "${YELLOW}WARN:${NC} $line"
    elif echo "$line" | grep -q "scrape_duration_seconds"; then
        echo -e "${GREEN}SCRAPE:${NC} $line"
    elif echo "$line" | grep -q "remote_write"; then
        echo -e "${BLUE}REMOTE:${NC} $line"
    fi
done) &
LOG_PID=$!

# Monitor for 30 seconds
sleep 30

# Stop log monitoring
kill $LOG_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}7. RECOMMENDATIONS${NC}"
echo "────────────────────────────────"

# Provide specific recommendations based on findings
if ! pgrep grafana-agent > /dev/null; then
    echo -e "${RED}Critical:${NC} Start Grafana Agent"
    echo "  sudo systemctl start grafana-agent"
fi

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}Critical:${NC} Fix errors in agent logs"
    echo "  sudo journalctl -u grafana-agent -n 100 --no-pager | grep error"
fi

if ! curl -s http://localhost:9119/metrics > /dev/null 2>&1; then
    echo -e "${YELLOW}Important:${NC} Deploy Ultimate Live TV exporter"
    echo "  ./scripts/deploy-ultimate.sh"
fi

if [ "$DISCOVERED" = "0" ]; then
    echo -e "${YELLOW}Important:${NC} No targets discovered - check scrape_configs"
    echo "  Review: $CONFIG_PATH"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DEBUG COMPLETE${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Summary files created:${NC}"
echo "• Agent config: $CONFIG_PATH"
echo "• Agent logs: sudo journalctl -u grafana-agent -f"
echo "• Agent metrics: http://localhost:12345/metrics"
echo "• Exporter metrics: http://localhost:9119/metrics"