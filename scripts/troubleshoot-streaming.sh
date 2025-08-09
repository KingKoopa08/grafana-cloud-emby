#!/bin/bash

# Comprehensive Emby Streaming Activity Troubleshooting Script
# This script diagnoses why streaming metrics aren't appearing in Grafana

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/config.env"
LOG_FILE="/tmp/emby-streaming-debug-$(date +%Y%m%d-%H%M%S).log"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}Configuration file not found at $CONFIG_FILE${NC}"
    echo "Please ensure config.env exists with your API keys"
    exit 1
fi

# Default values if not in config
EMBY_SERVER_URL="${EMBY_SERVER_URL:-http://localhost:8096}"
EXPORTER_PORT="${EXPORTER_PORT:-9119}"

# Function to print section headers
print_header() {
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Function to test and display results
test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
        return 0
    else
        echo -e "${RED}✗${NC} $2"
        return 1
    fi
}

# Function to log output
log_output() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Start logging
echo "Emby Streaming Activity Troubleshooting - $(date)" > "$LOG_FILE"
echo "=================================================" >> "$LOG_FILE"

print_header "1. CHECKING EMBY API CONNECTION"

# Test Emby API connection
echo -e "${BLUE}Testing Emby API endpoint...${NC}"
EMBY_API_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/System/Info" 2>/dev/null || echo "000")

if [ "$EMBY_API_TEST" = "200" ]; then
    test_result 0 "Emby API is accessible"
    
    # Get Emby server info
    echo -e "${BLUE}Fetching Emby server information...${NC}"
    EMBY_INFO=$(curl -s -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/System/Info" | python3 -m json.tool 2>/dev/null || echo "{}")
    echo "Emby Version: $(echo "$EMBY_INFO" | grep -o '"Version"[^,]*' | cut -d'"' -f4)"
    echo "Server Name: $(echo "$EMBY_INFO" | grep -o '"ServerName"[^,]*' | cut -d'"' -f4)"
else
    test_result 1 "Emby API is not accessible (HTTP $EMBY_API_TEST)"
    echo -e "${YELLOW}Check:${NC}"
    echo "  - EMBY_SERVER_URL: $EMBY_SERVER_URL"
    echo "  - EMBY_API_KEY is correct"
    echo "  - Emby server is running"
fi

print_header "2. CHECKING ACTIVE SESSIONS"

echo -e "${BLUE}Fetching active sessions from Emby...${NC}"
SESSIONS_RESPONSE=$(curl -s -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/Sessions" 2>/dev/null)

if [ -n "$SESSIONS_RESPONSE" ] && [ "$SESSIONS_RESPONSE" != "[]" ]; then
    # Count sessions
    SESSION_COUNT=$(echo "$SESSIONS_RESPONSE" | python3 -c "import sys, json; data = json.load(sys.stdin); print(len(data))" 2>/dev/null || echo "0")
    echo -e "${GREEN}Found $SESSION_COUNT active session(s)${NC}"
    
    # Parse session details
    echo ""
    echo "Active Sessions Details:"
    echo "$SESSIONS_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for i, session in enumerate(data, 1):
        print(f'  Session {i}:')
        print(f'    - User: {session.get(\"UserName\", \"N/A\")}')
        print(f'    - Client: {session.get(\"Client\", \"N/A\")}')
        print(f'    - Device: {session.get(\"DeviceName\", \"N/A\")}')
        
        if 'NowPlayingItem' in session:
            item = session['NowPlayingItem']
            print(f'    - NOW PLAYING:')
            print(f'      * Title: {item.get(\"Name\", \"N/A\")}')
            print(f'      * Type: {item.get(\"Type\", \"N/A\")}')
            print(f'      * Media Type: {item.get(\"MediaType\", \"N/A\")}')
            
            if 'PlayState' in session:
                play_state = session['PlayState']
                print(f'      * Play Method: {play_state.get(\"PlayMethod\", \"N/A\")}')
                print(f'      * Is Paused: {play_state.get(\"IsPaused\", False)}')
                print(f'      * Position: {play_state.get(\"PositionTicks\", 0) / 10000000:.0f} seconds')
            
            # Check for transcoding
            if session.get('TranscodingInfo'):
                print(f'      * TRANSCODING: Yes')
                trans = session['TranscodingInfo']
                print(f'        - Video Codec: {trans.get(\"VideoCodec\", \"N/A\")}')
                print(f'        - Audio Codec: {trans.get(\"AudioCodec\", \"N/A\")}')
                print(f'        - Bitrate: {trans.get(\"Bitrate\", 0) / 1000:.0f} kbps')
            else:
                print(f'      * TRANSCODING: No (Direct Play)')
        else:
            print(f'    - Not currently playing anything')
        print()
except Exception as e:
    print(f'Error parsing sessions: {e}')
" 2>&1 | tee -a "$LOG_FILE"
else
    test_result 1 "No active sessions found"
    echo -e "${YELLOW}This means no one is currently connected to Emby${NC}"
fi

print_header "3. CHECKING EMBY EXPORTER"

echo -e "${BLUE}Checking if Emby exporter is running...${NC}"
if systemctl is-active --quiet emby-exporter 2>/dev/null; then
    test_result 0 "Emby exporter service is running"
    
    # Check recent logs for errors
    echo -e "${BLUE}Recent exporter logs:${NC}"
    sudo journalctl -u emby-exporter -n 20 --no-pager 2>/dev/null | grep -E "(ERROR|WARNING|emby_active|emby_session)" | tail -10 || echo "No relevant logs found"
else
    test_result 1 "Emby exporter service is not running"
    echo -e "${YELLOW}Starting emby-exporter service...${NC}"
    sudo systemctl start emby-exporter 2>/dev/null || echo "Failed to start service"
fi

print_header "4. CHECKING METRICS ENDPOINT"

echo -e "${BLUE}Testing metrics endpoint at http://localhost:${EXPORTER_PORT}/metrics${NC}"
METRICS_RESPONSE=$(curl -s "http://localhost:${EXPORTER_PORT}/metrics" 2>/dev/null)

if [ -n "$METRICS_RESPONSE" ]; then
    test_result 0 "Metrics endpoint is responding"
    
    # Check for streaming-related metrics
    echo ""
    echo "Streaming-related metrics:"
    echo -e "${CYAN}Active Sessions:${NC}"
    echo "$METRICS_RESPONSE" | grep "^emby_active_sessions" | head -5
    
    echo -e "${CYAN}Active Streams:${NC}"
    echo "$METRICS_RESPONSE" | grep "^emby_active_streams" | head -5
    
    echo -e "${CYAN}Active Transcodes:${NC}"
    echo "$METRICS_RESPONSE" | grep "^emby_active_transcodes" | head -5
    
    echo -e "${CYAN}Session Bandwidth:${NC}"
    echo "$METRICS_RESPONSE" | grep "^emby_session_bandwidth" | head -5
    
    echo -e "${CYAN}Total Bandwidth:${NC}"
    echo "$METRICS_RESPONSE" | grep "^emby_total_bandwidth" | head -5
    
    echo -e "${CYAN}User Activity:${NC}"
    echo "$METRICS_RESPONSE" | grep "^emby_user_play" | head -5
    
    # Count metrics
    STREAM_METRIC_COUNT=$(echo "$METRICS_RESPONSE" | grep -c "emby_active_streams" || echo "0")
    if [ "$STREAM_METRIC_COUNT" -eq 0 ]; then
        echo -e "${RED}WARNING: No streaming metrics found in exporter output${NC}"
    fi
else
    test_result 1 "Metrics endpoint is not responding"
    echo -e "${YELLOW}Check if exporter is running on port ${EXPORTER_PORT}${NC}"
fi

print_header "5. CHECKING GRAFANA AGENT"

echo -e "${BLUE}Checking Grafana Agent status...${NC}"
if systemctl is-active --quiet grafana-agent 2>/dev/null; then
    test_result 0 "Grafana Agent is running"
    
    # Check if agent is scraping the exporter
    echo -e "${BLUE}Checking if Grafana Agent is configured to scrape exporter...${NC}"
    if grep -q "localhost:${EXPORTER_PORT}" /etc/grafana-agent/grafana-agent.yaml 2>/dev/null; then
        test_result 0 "Exporter is configured in Grafana Agent"
    else
        test_result 1 "Exporter not found in Grafana Agent config"
    fi
    
    # Check for recent scrape errors
    echo -e "${BLUE}Recent Grafana Agent errors:${NC}"
    sudo journalctl -u grafana-agent -n 50 --no-pager 2>/dev/null | grep -E "(error|failed|emby)" | tail -5 || echo "No errors found"
    
    # Check remote write status
    echo -e "${BLUE}Checking remote write metrics:${NC}"
    AGENT_METRICS=$(curl -s http://localhost:12345/metrics 2>/dev/null)
    if [ -n "$AGENT_METRICS" ]; then
        echo "Samples sent: $(echo "$AGENT_METRICS" | grep "prometheus_remote_write_samples_total" | tail -1 | awk '{print $2}')"
        echo "Failed samples: $(echo "$AGENT_METRICS" | grep "prometheus_remote_write_samples_failed_total" | tail -1 | awk '{print $2}')"
    fi
else
    test_result 1 "Grafana Agent is not running"
    echo -e "${YELLOW}Start with: sudo systemctl start grafana-agent${NC}"
fi

print_header "6. TESTING EMBY API ENDPOINTS DIRECTLY"

echo -e "${BLUE}Testing specific API endpoints used by the exporter...${NC}"

# Test Sessions endpoint
echo -e "${CYAN}Testing /Sessions endpoint:${NC}"
SESSION_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/Sessions" 2>/dev/null)
test_result $([[ "$SESSION_TEST" == "200" ]] && echo 0 || echo 1) "/Sessions endpoint (HTTP $SESSION_TEST)"

# Test Users endpoint
echo -e "${CYAN}Testing /Users endpoint:${NC}"
USERS_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/Users" 2>/dev/null)
test_result $([[ "$USERS_TEST" == "200" ]] && echo 0 || echo 1) "/Users endpoint (HTTP $USERS_TEST)"

# Test Library endpoint
echo -e "${CYAN}Testing /Library/VirtualFolders endpoint:${NC}"
LIBRARY_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/Library/VirtualFolders" 2>/dev/null)
test_result $([[ "$LIBRARY_TEST" == "200" ]] && echo 0 || echo 1) "/Library/VirtualFolders endpoint (HTTP $LIBRARY_TEST)"

print_header "7. PYTHON EXPORTER DIAGNOSTIC"

echo -e "${BLUE}Testing Python exporter directly...${NC}"

# Create a test Python script
cat << 'EOF' > /tmp/test_emby_exporter.py
#!/usr/bin/env python3
import os
import sys
import requests
import json

# Get config from environment
EMBY_SERVER_URL = os.getenv('EMBY_SERVER_URL', 'http://localhost:8096').rstrip('/')
EMBY_API_KEY = os.getenv('EMBY_API_KEY', '')

if not EMBY_API_KEY:
    print("ERROR: EMBY_API_KEY not set")
    sys.exit(1)

print(f"Testing Emby API at: {EMBY_SERVER_URL}")
print(f"Using API key: {EMBY_API_KEY[:10]}...")

headers = {'X-Emby-Token': EMBY_API_KEY, 'Accept': 'application/json'}

# Test sessions
try:
    response = requests.get(f"{EMBY_SERVER_URL}/Sessions", headers=headers, timeout=5)
    response.raise_for_status()
    sessions = response.json()
    
    print(f"\n✓ Successfully fetched {len(sessions)} session(s)")
    
    streaming_count = 0
    transcoding_count = 0
    total_bandwidth = 0
    
    for session in sessions:
        if session.get('NowPlayingItem'):
            streaming_count += 1
            print(f"  - User '{session.get('UserName', 'Unknown')}' is streaming: {session['NowPlayingItem'].get('Name', 'Unknown')}")
            
            if 'PlayState' in session and session['PlayState'].get('PlayMethod') == 'Transcode':
                transcoding_count += 1
                print(f"    (Transcoding)")
            
            bandwidth = session.get('Bandwidth', 0)
            if bandwidth > 0:
                total_bandwidth += bandwidth
                print(f"    Bandwidth: {bandwidth / 1000000:.2f} Mbps")
    
    print(f"\nMetrics that should be exported:")
    print(f"  emby_active_sessions: {len(sessions)}")
    print(f"  emby_active_streams: {streaming_count}")
    print(f"  emby_active_transcodes: {transcoding_count}")
    print(f"  emby_total_bandwidth_bytes: {total_bandwidth}")
    
except requests.exceptions.RequestException as e:
    print(f"✗ Failed to fetch sessions: {e}")
except Exception as e:
    print(f"✗ Error processing sessions: {e}")

# Test if exporter would collect metrics
try:
    from prometheus_client import CollectorRegistry, generate_latest
    print("\n✓ Prometheus client library is available")
except ImportError:
    print("\n✗ Prometheus client library not found - exporter cannot run")
EOF

# Run the test script
echo -e "${CYAN}Running Python diagnostic...${NC}"
source "$CONFIG_FILE"
export EMBY_SERVER_URL EMBY_API_KEY
python3 /tmp/test_emby_exporter.py 2>&1 | tee -a "$LOG_FILE"

print_header "8. GRAFANA CLOUD CONNECTIVITY"

echo -e "${BLUE}Testing Grafana Cloud endpoints...${NC}"

# Test Prometheus endpoint
PROM_URL="https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query"
echo -e "${CYAN}Testing Prometheus endpoint:${NC}"
PROM_TEST=$(curl -s -o /dev/null -w "%{http_code}" -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" "$PROM_URL?query=up" 2>/dev/null)
test_result $([[ "$PROM_TEST" == "200" ]] && echo 0 || echo 1) "Prometheus endpoint (HTTP $PROM_TEST)"

# Query for Emby metrics in Grafana Cloud
echo -e "${BLUE}Querying Grafana Cloud for Emby metrics...${NC}"
METRICS_IN_CLOUD=$(curl -s -u "${GRAFANA_CLOUD_USER}:${GRAFANA_CLOUD_API_KEY}" \
    "$PROM_URL?query=emby_active_streams" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data['status'] == 'success':
        results = data['data']['result']
        if results:
            print(f'Found {len(results)} emby_active_streams series')
            for r in results:
                print(f'  Value: {r[\"value\"][1]}')
        else:
            print('No emby_active_streams metrics found in Grafana Cloud')
    else:
        print(f'Query failed: {data.get(\"error\", \"unknown\")}')
except:
    print('Failed to parse response')
" 2>&1)
echo "$METRICS_IN_CLOUD"

print_header "9. MANUAL EXPORTER RESTART"

echo -e "${BLUE}Restarting Emby exporter to force metric collection...${NC}"
sudo systemctl restart emby-exporter 2>/dev/null
sleep 5

echo -e "${BLUE}Checking metrics after restart...${NC}"
METRICS_AFTER=$(curl -s "http://localhost:${EXPORTER_PORT}/metrics" 2>/dev/null | grep -E "emby_active_streams|emby_active_sessions" | head -5)
if [ -n "$METRICS_AFTER" ]; then
    echo "$METRICS_AFTER"
else
    echo "Still no streaming metrics after restart"
fi

print_header "10. RECOMMENDATIONS"

echo -e "${CYAN}Based on the diagnostics:${NC}"
echo ""

# Provide recommendations based on findings
if [ "$EMBY_API_TEST" != "200" ]; then
    echo -e "${YELLOW}1. Fix Emby API Connection:${NC}"
    echo "   - Verify EMBY_SERVER_URL is correct: $EMBY_SERVER_URL"
    echo "   - Check EMBY_API_KEY is valid"
    echo "   - Ensure Emby server is running and accessible"
    echo ""
fi

if [ "${SESSION_COUNT:-0}" -eq 0 ]; then
    echo -e "${YELLOW}2. No Active Streaming Sessions:${NC}"
    echo "   - Start a stream in Emby to generate metrics"
    echo "   - Ensure the stream is actually playing (not paused)"
    echo "   - Wait 30-60 seconds for metrics to be collected"
    echo ""
fi

if [ "${STREAM_METRIC_COUNT:-0}" -eq 0 ]; then
    echo -e "${YELLOW}3. Exporter Not Generating Metrics:${NC}"
    echo "   - Check exporter logs: sudo journalctl -u emby-exporter -f"
    echo "   - Verify Python dependencies: sudo /opt/emby-exporter/venv/bin/pip list"
    echo "   - Try running exporter manually for debugging"
    echo ""
fi

echo -e "${YELLOW}4. Dashboard Configuration:${NC}"
echo "   - In Grafana, check the datasource variable is set correctly"
echo "   - Verify time range includes current time"
echo "   - Try a simple query in Explore: emby_active_streams"
echo ""

echo -e "${YELLOW}5. Full Service Restart:${NC}"
echo "   sudo systemctl restart emby-exporter"
echo "   sudo systemctl restart grafana-agent"
echo "   Wait 2-3 minutes for metrics to propagate"
echo ""

print_header "DIAGNOSTIC COMPLETE"

echo -e "${GREEN}Log file saved to: $LOG_FILE${NC}"
echo ""
echo "Next steps:"
echo "1. Start a stream in Emby if not already playing"
echo "2. Wait 1-2 minutes for metrics collection"
echo "3. Check Grafana Explore with query: emby_active_streams"
echo "4. If still no data, check the log file and service logs"
echo ""
echo "For manual debugging, run:"
echo "  sudo journalctl -u emby-exporter -f"
echo "  sudo journalctl -u grafana-agent -f"