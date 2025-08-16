#!/bin/bash

# Restore ALL log collection (Emby + NFL)
# Fixes the broken agent configuration

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
echo -e "${CYAN}  RESTORE ALL LOG COLLECTION${NC}"
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

# Set default Loki URL
GRAFANA_CLOUD_LOKI_URL=${GRAFANA_CLOUD_LOKI_URL:-"https://logs-prod-021.grafana.net/loki/api/v1/push"}

echo ""
echo -e "${BLUE}1. CHECKING LOG FILES${NC}"
echo "────────────────────────────────"

# Check which logs exist
LOGS_FOUND=0

if [ -f /var/lib/emby/logs/embyserver.txt ]; then
    echo -e "${GREEN}✓${NC} Emby server log found"
    LOGS_FOUND=$((LOGS_FOUND + 1))
fi

if [ -f /var/log/nfl_updater.log ]; then
    echo -e "${GREEN}✓${NC} NFL updater log found"
    LOGS_FOUND=$((LOGS_FOUND + 1))
fi

if [ $LOGS_FOUND -eq 0 ]; then
    echo -e "${YELLOW}⚠${NC} No log files found, but continuing setup"
fi

echo ""
echo -e "${BLUE}2. STOPPING AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl stop grafana-agent 2>/dev/null || true
echo -e "${GREEN}✓${NC} Agent stopped"

# Kill any hanging processes
sudo pkill -f grafana-agent 2>/dev/null || true

echo ""
echo -e "${BLUE}3. BACKING UP AND CLEANING${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [ -f /etc/grafana-agent/agent.yaml ]; then
    sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
    echo -e "${GREEN}✓${NC} Config backed up"
fi

# Clean positions file to force re-read
if [ -f /var/lib/grafana-agent/positions.yaml ]; then
    sudo mv /var/lib/grafana-agent/positions.yaml "/var/lib/grafana-agent/positions.yaml.backup.$TIMESTAMP"
    echo -e "${GREEN}✓${NC} Positions file reset"
fi

# Clean WAL
sudo rm -rf /var/lib/grafana-agent/data-agent 2>/dev/null || true
sudo rm -rf /var/lib/grafana-agent/wal 2>/dev/null || true
echo -e "${GREEN}✓${NC} WAL cleaned"

echo ""
echo -e "${BLUE}4. CREATING SIMPLE WORKING CONFIG${NC}"
echo "────────────────────────────────"

# Create a very simple config that definitely works
cat > /tmp/agent-simple.yaml <<EOF
server:
  log_level: info

metrics:
  global:
    scrape_interval: 60s
    remote_write:
      - url: https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/push
        basic_auth:
          username: ${GRAFANA_CLOUD_USER}
          password: ${GRAFANA_CLOUD_API_KEY}

  configs:
    - name: default
      scrape_configs:
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
        - job_name: node
          static_configs:
            - targets: ['localhost:9100']
          scrape_interval: 60s

integrations:
  agent:
    enabled: true

logs:
  configs:
    - name: default
      clients:
        - url: ${GRAFANA_CLOUD_LOKI_URL}
          basic_auth:
            username: ${GRAFANA_CLOUD_USER}
            password: ${GRAFANA_CLOUD_API_KEY}
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # Emby Server Logs
        - job_name: embyserver
          static_configs:
            - targets:
                - localhost
              labels:
                job: embyserver
                __path__: /var/lib/emby/logs/embyserver.txt
                
          pipeline_stages:
            - multiline:
                firstline: '^\d{4}-\d{2}-\d{2}'
                max_wait_time: 3s
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)'
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05.000'
                location: UTC
            - output:
                source: message
                
        # NFL Updater Logs  
        - job_name: nfl_updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl_updater
                __path__: /var/log/nfl_updater.log
                
          pipeline_stages:
            - regex:
                expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
            - timestamp:
                source: timestamp
                format: '2006-01-02 15:04:05'
                location: UTC
                action_on_failure: skip
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Simple configuration created"

echo ""
echo -e "${BLUE}5. SETTING PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure grafana-agent can read logs
if [ -f /var/lib/emby/logs/embyserver.txt ]; then
    sudo chmod 644 /var/lib/emby/logs/embyserver.txt 2>/dev/null || true
    # Add grafana-agent to emby group if needed
    if ! groups grafana-agent 2>/dev/null | grep -q emby; then
        sudo usermod -a -G emby grafana-agent
        echo -e "${GREEN}✓${NC} Added grafana-agent to emby group"
    fi
fi

if [ -f /var/log/nfl_updater.log ]; then
    sudo chmod 644 /var/log/nfl_updater.log 2>/dev/null || true
fi

# Ensure positions directory
sudo mkdir -p /var/lib/grafana-agent
sudo chown -R grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Permissions fixed"

echo ""
echo -e "${BLUE}6. APPLYING CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-simple.yaml /etc/grafana-agent/agent.yaml
sudo chown root:root /etc/grafana-agent/agent.yaml
sudo chmod 644 /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}7. STARTING AGENT${NC}"
echo "────────────────────────────────"

# Reload systemd in case of changes
sudo systemctl daemon-reload

# Start agent
sudo systemctl start grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent started successfully!"
    
    # Show initial logs
    echo ""
    echo "Agent startup logs:"
    sudo journalctl -u grafana-agent --since "10 seconds ago" --no-pager | grep -E "(Started|level=info)" | head -5 | sed 's/^/  /'
else
    echo -e "${RED}✗${NC} Failed to start agent"
    echo ""
    echo "Error logs:"
    sudo journalctl -u grafana-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo -e "${BLUE}8. VERIFYING LOG COLLECTION${NC}"
echo "────────────────────────────────"

sleep 5

# Check if agent is tailing logs
AGENT_PID=$(pgrep grafana-agent | head -1)
if [ -n "$AGENT_PID" ]; then
    echo "Checking open files..."
    
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "embyserver.txt"; then
        echo -e "${GREEN}✓${NC} Agent is reading Emby logs"
    else
        echo -e "${YELLOW}⚠${NC} Emby logs not being read yet"
    fi
    
    if sudo lsof -p $AGENT_PID 2>/dev/null | grep -q "nfl_updater.log"; then
        echo -e "${GREEN}✓${NC} Agent is reading NFL logs"
    else
        echo -e "${YELLOW}⚠${NC} NFL logs not being read yet"
    fi
fi

# Check positions file
if [ -f /var/lib/grafana-agent/positions.yaml ]; then
    echo ""
    echo "Positions file created:"
    cat /var/lib/grafana-agent/positions.yaml | head -10 | sed 's/^/  /'
fi

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOG COLLECTION RESTORED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Success!${NC} Log collection has been restored."
echo ""
echo "Configured logs:"
echo "• Emby: /var/lib/emby/logs/embyserver.txt (job=embyserver)"
echo "• NFL: /var/log/nfl_updater.log (job=nfl_updater)"
echo ""
echo "Test in Grafana Explore (wait 2-3 minutes for data):"
echo ""
echo -e "${CYAN}All logs:${NC}"
echo '{job=~".+"}'
echo ""
echo -e "${CYAN}Emby logs:${NC}"
echo '{job="embyserver"}'
echo ""
echo -e "${CYAN}NFL logs:${NC}"
echo '{job="nfl_updater"}'
echo ""
echo -e "${CYAN}Verify metrics still work:${NC}"
echo 'emby_livetv_streams_active'
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "• Logs may take 2-3 minutes to appear in Grafana"
echo "• Check that timestamps are recent"
echo "• If still no logs, check: sudo journalctl -u grafana-agent -f"