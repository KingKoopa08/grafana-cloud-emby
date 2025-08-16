#!/bin/bash

# Troubleshooting script for Ultimate Live TV Dashboard
# This helps diagnose why the dashboard isn't showing data

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
echo -e "${CYAN}  ULTIMATE LIVE TV DASHBOARD TROUBLESHOOTING${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Load config if available
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded"
else
    echo -e "${RED}✗${NC} Configuration file not found at $CONFIG_FILE"
    exit 1
fi

echo ""
echo -e "${BLUE}1. CHECKING EXPORTER STATUS${NC}"
echo "────────────────────────────────"

# Check which exporter is running
EXPORTER_RUNNING="none"

if systemctl is-active --quiet emby-livetv-ultimate 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Ultimate Live TV exporter is running"
    EXPORTER_RUNNING="ultimate"
elif systemctl is-active --quiet emby-livetv-exporter 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} Standard Live TV exporter is running (not Ultimate)"
    EXPORTER_RUNNING="standard"
    echo "  To use Ultimate dashboard, deploy the Ultimate exporter:"
    echo "  ./scripts/deploy-ultimate.sh"
elif systemctl is-active --quiet emby-exporter 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC} Basic Emby exporter is running (not Live TV specific)"
    EXPORTER_RUNNING="basic"
    echo "  To use Ultimate dashboard, deploy the Ultimate exporter:"
    echo "  ./scripts/deploy-ultimate.sh"
else
    echo -e "${RED}✗${NC} No Emby exporter is running!"
    echo "  Deploy the Ultimate exporter with:"
    echo "  ./scripts/deploy-ultimate.sh"
fi

echo ""
echo -e "${BLUE}2. CHECKING METRICS AVAILABILITY${NC}"
echo "────────────────────────────────"

# Check metrics endpoint
METRICS_URL="http://localhost:9119/metrics"
echo -e "Checking ${METRICS_URL}..."

if curl -s -o /dev/null -w "%{http_code}" "$METRICS_URL" | grep -q "200"; then
    echo -e "${GREEN}✓${NC} Metrics endpoint is accessible"
    
    # Check for Ultimate metrics
    ULTIMATE_METRICS=$(curl -s "$METRICS_URL" 2>/dev/null | grep -c "emby_livetv_" || echo "0")
    BASIC_METRICS=$(curl -s "$METRICS_URL" 2>/dev/null | grep -c "emby_" || echo "0")
    
    echo -e "  Found ${YELLOW}$ULTIMATE_METRICS${NC} Live TV metrics"
    echo -e "  Found ${YELLOW}$BASIC_METRICS${NC} total Emby metrics"
    
    if [ "$ULTIMATE_METRICS" -eq 0 ]; then
        echo -e "${RED}✗${NC} No Live TV metrics found!"
        echo "  The Ultimate dashboard requires these metrics:"
        echo "    • emby_livetv_streams_active"
        echo "    • emby_livetv_users_watching"
        echo "    • emby_livetv_bandwidth_total_mbps"
        echo "    • emby_livetv_channels_total"
        echo "    • emby_livetv_tuner_utilization_percent"
        echo "    • emby_livetv_channel_popularity"
        echo "    • ... and 60+ more"
    else
        echo ""
        echo "  Sample Live TV metrics available:"
        curl -s "$METRICS_URL" 2>/dev/null | grep "^emby_livetv_" | head -5 | sed 's/^/    /'
    fi
else
    echo -e "${RED}✗${NC} Metrics endpoint is not accessible"
fi

echo ""
echo -e "${BLUE}3. CHECKING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

if systemctl is-active --quiet grafana-agent 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Grafana Agent is running"
    
    # Check if scraping our exporter
    if grep -q "localhost:9119" /etc/grafana-agent/grafana-agent.yaml 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Agent is configured to scrape localhost:9119"
    else
        echo -e "${RED}✗${NC} Agent not configured to scrape the exporter"
    fi
    
    # Check for remote write errors
    WRITE_ERRORS=$(sudo journalctl -u grafana-agent -n 100 --no-pager 2>/dev/null | grep -c "remote.write.*error" || echo "0")
    if [ "$WRITE_ERRORS" -gt 0 ]; then
        echo -e "${RED}✗${NC} Found $WRITE_ERRORS remote write errors in recent logs"
    else
        echo -e "${GREEN}✓${NC} No remote write errors"
    fi
else
    echo -e "${RED}✗${NC} Grafana Agent is not running"
fi

echo ""
echo -e "${BLUE}4. CHECKING GRAFANA CLOUD${NC}"
echo "────────────────────────────────"

# Test Grafana Cloud connectivity
PROM_URL="https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query"
echo "Testing Grafana Cloud connection..."

# Query for any emby metrics
RESPONSE=$(curl -s -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "${PROM_URL}?query=emby_up" 2>/dev/null || echo "{}")

if echo "$RESPONSE" | grep -q '"status":"success"'; then
    echo -e "${GREEN}✓${NC} Connected to Grafana Cloud"
    
    # Check for Live TV metrics
    LIVETV_CHECK=$(curl -s -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
        "${PROM_URL}?query=emby_livetv_streams_active" 2>/dev/null || echo "{}")
    
    if echo "$LIVETV_CHECK" | grep -q '"result":\[\]'; then
        echo -e "${YELLOW}⚠${NC} No Live TV metrics found in Grafana Cloud"
        echo "  This means either:"
        echo "    1. The Ultimate exporter isn't running"
        echo "    2. Metrics aren't being scraped/pushed"
        echo "    3. No Live TV activity to report"
    elif echo "$LIVETV_CHECK" | grep -q '"result":\['; then
        echo -e "${GREEN}✓${NC} Live TV metrics found in Grafana Cloud!"
        
        # Extract value if present
        VALUE=$(echo "$LIVETV_CHECK" | grep -o '"value":\[.*\]' | grep -o '[0-9.]*' | tail -1 || echo "0")
        echo "  Current emby_livetv_streams_active: ${VALUE}"
    fi
else
    echo -e "${RED}✗${NC} Cannot connect to Grafana Cloud"
    echo "  Check GRAFANA_CLOUD_USER and GRAFANA_CLOUD_API_KEY in config.env"
fi

echo ""
echo -e "${BLUE}5. CHECKING DASHBOARD CONFIGURATION${NC}"
echo "────────────────────────────────"

echo "In your Grafana dashboard, check:"
echo ""
echo "1. ${YELLOW}Data Source Variable:${NC}"
echo "   • Go to Dashboard Settings > Variables"
echo "   • Ensure 'datasource' variable is set to your Prometheus instance"
echo "   • It should match your Grafana Cloud Prometheus datasource name"
echo ""
echo "2. ${YELLOW}Time Range:${NC}"
echo "   • Ensure time range includes recent data (e.g., 'Last 6 hours')"
echo "   • If using 'Last 24 hours' and just deployed, wait for data"
echo ""
echo "3. ${YELLOW}Query Inspector:${NC}"
echo "   • Edit any panel showing 'No data'"
echo "   • Click 'Query Inspector' button"
echo "   • Check for errors in the response"

echo ""
echo -e "${BLUE}6. EMBY LIVE TV STATUS${NC}"
echo "────────────────────────────────"

# Check if Emby has Live TV
echo "Checking Emby Live TV configuration..."
EMBY_INFO=$(curl -s -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/System/Info" 2>/dev/null || echo "{}")

if echo "$EMBY_INFO" | grep -q '"HasLiveTv":true'; then
    echo -e "${GREEN}✓${NC} Live TV is enabled in Emby"
    
    # Check for channels
    CHANNELS=$(curl -s -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/LiveTv/Channels" 2>/dev/null || echo "{}")
    if echo "$CHANNELS" | grep -q '"TotalRecordCount":[1-9]'; then
        CHANNEL_COUNT=$(echo "$CHANNELS" | grep -o '"TotalRecordCount":[0-9]*' | grep -o '[0-9]*')
        echo -e "${GREEN}✓${NC} Found $CHANNEL_COUNT Live TV channels"
    else
        echo -e "${YELLOW}⚠${NC} No Live TV channels found"
        echo "  Configure channels in Emby before expecting data"
    fi
    
    # Check for active streams
    SESSIONS=$(curl -s -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/Sessions" 2>/dev/null || echo "[]")
    LIVETV_SESSIONS=$(echo "$SESSIONS" | grep -c '"Type":"TvChannel"' || echo "0")
    if [ "$LIVETV_SESSIONS" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Found $LIVETV_SESSIONS active Live TV session(s)"
    else
        echo -e "${YELLOW}⚠${NC} No active Live TV sessions"
        echo "  Start watching Live TV in Emby to generate metrics"
    fi
else
    echo -e "${RED}✗${NC} Live TV is not enabled in Emby!"
    echo "  Enable Live TV in Emby settings first"
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DIAGNOSIS SUMMARY${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Provide diagnosis
if [ "$EXPORTER_RUNNING" != "ultimate" ]; then
    echo -e "${RED}ISSUE:${NC} Ultimate exporter not running"
    echo ""
    echo -e "${YELLOW}SOLUTION:${NC}"
    echo "1. Deploy the Ultimate exporter:"
    echo "   cd /opt/grafana-cloud-emby"
    echo "   ./scripts/deploy-ultimate.sh"
    echo ""
elif [ "$ULTIMATE_METRICS" -eq 0 ]; then
    echo -e "${RED}ISSUE:${NC} Ultimate exporter running but no Live TV metrics"
    echo ""
    echo -e "${YELLOW}SOLUTION:${NC}"
    echo "1. Restart the exporter:"
    echo "   sudo systemctl restart emby-livetv-ultimate"
    echo "2. Check logs:"
    echo "   sudo journalctl -u emby-livetv-ultimate -f"
    echo ""
elif [ "$LIVETV_SESSIONS" -eq 0 ]; then
    echo -e "${YELLOW}ISSUE:${NC} No Live TV activity to monitor"
    echo ""
    echo -e "${YELLOW}SOLUTION:${NC}"
    echo "1. Start watching Live TV in Emby"
    echo "2. Wait 30-60 seconds for metrics to appear"
    echo "3. Refresh the Grafana dashboard"
    echo ""
else
    echo -e "${GREEN}Everything appears to be working!${NC}"
    echo ""
    echo "If dashboard still shows no data:"
    echo "1. Check the datasource variable in dashboard settings"
    echo "2. Ensure time range is appropriate"
    echo "3. Try a simple query in Explore: emby_livetv_streams_active"
fi

echo ""
echo -e "${CYAN}Need more help?${NC}"
echo "• Check exporter logs: sudo journalctl -u emby-livetv-ultimate -f"
echo "• Check agent logs: sudo journalctl -u grafana-agent -f"
echo "• Test metrics: curl http://localhost:9119/metrics | grep emby_livetv_"