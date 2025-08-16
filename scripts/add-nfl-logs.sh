#!/bin/bash

# Add NFL log collection to existing Grafana Agent configuration
# This adds Loki log ingestion for NFL updater logs

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
echo -e "${CYAN}  ADD NFL LOG COLLECTION${NC}"
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

# Set default Loki URL if not provided
GRAFANA_CLOUD_LOKI_URL=${GRAFANA_CLOUD_LOKI_URL:-"https://logs-prod-021.grafana.net/loki/api/v1/push"}

echo ""
echo -e "${BLUE}1. CHECKING NFL LOGS${NC}"
echo "────────────────────────────────"

# Check which log files exist
LOG_DIR="/var/log/nfl-updater"
if [ -d "$LOG_DIR" ]; then
    echo -e "${GREEN}✓${NC} NFL log directory exists: $LOG_DIR"
    echo ""
    echo "Log files found:"
    ls -lah $LOG_DIR/*.log 2>/dev/null | sed 's/^/  /' || echo "  No log files yet"
else
    echo -e "${YELLOW}⚠${NC} NFL log directory not found at $LOG_DIR"
    echo "  NFL updater service may not be installed yet"
fi

echo ""
echo -e "${BLUE}2. BACKING UP CURRENT CONFIG${NC}"
echo "────────────────────────────────"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/grafana-agent/agent.yaml "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP"
echo -e "${GREEN}✓${NC} Config backed up"

echo ""
echo -e "${BLUE}3. CREATING CONFIG WITH LOGS${NC}"
echo "────────────────────────────────"

# Create new config with logs section added
cat > /tmp/agent-with-logs.yaml <<EOF
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
        # Emby Live TV exporter
        - job_name: emby
          static_configs:
            - targets: ['localhost:9119']
          scrape_interval: 30s
          metrics_path: /metrics
          
        # Node exporter
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
          external_labels:
            environment: 'prod'
            hostname: 'ns1017440'
            
      positions:
        filename: /var/lib/grafana-agent/positions.yaml
        
      scrape_configs:
        # NFL Updater Application Logs
        - job_name: nfl-updater
          static_configs:
            - targets:
                - localhost
              labels:
                job: nfl-updater
                service: nfl-updater
                __path__: /var/log/nfl-updater/*.log
                
          pipeline_stages:
            # Match different log formats
            - match:
                selector: '{job="nfl-updater"} |= "nfl_updater.log"'
                stages:
                  # Python log format
                  - regex:
                      expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - (?P<logger>\S+) - (?P<level>\w+) - (?P<message>.*)'
                  - timestamp:
                      source: timestamp
                      format: '2006-01-02 15:04:05,000'
                      location: UTC
                  - labels:
                      level:
                      logger:
                      log_file: "application"
                  
            - match:
                selector: '{job="nfl-updater"} |= "service.log"'
                stages:
                  - labels:
                      log_file: "service"
                      level: "info"
                      
            - match:
                selector: '{job="nfl-updater"} |= "service-error.log"'
                stages:
                  - labels:
                      log_file: "service-error"
                      level: "error"
            
            # Extract game updates from any log
            - regex:
                expression: 'Updated: (?P<away_team>[\w\s]+) \((?P<away_score>\d+)\) at (?P<home_team>[\w\s]+) \((?P<home_score>\d+)\)'
            - labels:
                away_team:
                home_team:
                
            # Extract game state
            - regex:
                expression: 'Game.*:\s+\d+-\d+\s+\((?P<game_state>LIVE|HALFTIME|FINAL|SCHEDULED)\)'
            - labels:
                game_state:
            
            # Extract API info
            - regex:
                expression: '(?P<api_name>ESPN|Emby) API'
            - labels:
                api_name:
                
            # Output final log line
            - output:
                source: message
                
        # Systemd Journal for NFL service
        - job_name: nfl-updater-journal
          journal:
            matches: _SYSTEMD_UNIT=nfl-updater.service
            labels:
              job: nfl-updater-journal
              service: nfl-updater
              log_type: systemd
          relabel_configs:
            - source_labels: ['__journal__systemd_unit']
              target_label: 'unit'
            - source_labels: ['__journal__hostname']
              target_label: 'hostname'
          pipeline_stages:
            - output:
                source: message
EOF

echo -e "${GREEN}✓${NC} Configuration with logs created"

echo ""
echo -e "${BLUE}4. SETTING UP LOG PERMISSIONS${NC}"
echo "────────────────────────────────"

# Ensure grafana-agent can read the log directory
if [ -d "$LOG_DIR" ]; then
    # Make logs readable
    sudo chmod 755 $LOG_DIR
    sudo chmod 644 $LOG_DIR/*.log 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Log directory permissions set"
    
    # Add grafana-agent to necessary groups if needed
    if [ -f "$LOG_DIR/nfl_updater.log" ]; then
        LOG_OWNER=$(stat -c '%U' $LOG_DIR/nfl_updater.log)
        if [ "$LOG_OWNER" != "root" ] && [ "$LOG_OWNER" != "grafana-agent" ]; then
            if ! groups grafana-agent 2>/dev/null | grep -q $LOG_OWNER; then
                sudo usermod -a -G $LOG_OWNER grafana-agent 2>/dev/null || true
                echo -e "${GREEN}✓${NC} Added grafana-agent to $LOG_OWNER group"
            fi
        fi
    fi
else
    echo -e "${YELLOW}⚠${NC} Log directory doesn't exist yet"
fi

# Create positions directory
sudo mkdir -p /var/lib/grafana-agent
sudo chown grafana-agent:grafana-agent /var/lib/grafana-agent
echo -e "${GREEN}✓${NC} Positions directory ready"

echo ""
echo -e "${BLUE}5. APPLYING NEW CONFIG${NC}"
echo "────────────────────────────────"

sudo cp /tmp/agent-with-logs.yaml /etc/grafana-agent/agent.yaml
echo -e "${GREEN}✓${NC} Configuration applied"

echo ""
echo -e "${BLUE}6. RESTARTING GRAFANA AGENT${NC}"
echo "────────────────────────────────"

sudo systemctl restart grafana-agent
sleep 5

if systemctl is-active --quiet grafana-agent; then
    echo -e "${GREEN}✓${NC} Grafana Agent restarted successfully"
    
    # Check for log collection
    if sudo journalctl -u grafana-agent --since "30 seconds ago" --no-pager | grep -q "nfl-updater"; then
        echo -e "${GREEN}✓${NC} NFL log collection configured"
    else
        echo -e "${YELLOW}⚠${NC} NFL logs not being collected yet (may need logs to exist first)"
    fi
else
    echo -e "${RED}✗${NC} Failed to restart agent"
    echo "Recent logs:"
    sudo journalctl -u grafana-agent -n 10 --no-pager
    
    echo ""
    echo "Reverting to backup..."
    sudo cp "/etc/grafana-agent/agent.yaml.backup.$TIMESTAMP" /etc/grafana-agent/agent.yaml
    sudo systemctl restart grafana-agent
    echo -e "${YELLOW}⚠${NC} Reverted to previous config"
    exit 1
fi

echo ""
echo -e "${BLUE}7. TESTING LOG QUERIES${NC}"
echo "────────────────────────────────"

echo "You can now query NFL logs in Grafana Explore with:"
echo ""
echo -e "${CYAN}All NFL logs:${NC}"
echo '{job="nfl-updater"}'
echo ""
echo -e "${CYAN}Score updates:${NC}"
echo '{job="nfl-updater"} |= "Updated:"'
echo ""
echo -e "${CYAN}Errors only:${NC}"
echo '{job="nfl-updater", level="ERROR"}'
echo ""
echo -e "${CYAN}Service logs:${NC}"
echo '{job="nfl-updater", log_file="service"}'
echo ""
echo -e "${CYAN}Live games:${NC}"
echo '{job="nfl-updater", game_state="LIVE"}'

echo ""
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOG COLLECTION CONFIGURED${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${GREEN}Success!${NC} NFL log collection is now configured."
echo ""
echo "Log sources:"
echo "• /var/log/nfl-updater/*.log - All NFL updater logs"
echo "• systemd journal - Service start/stop events"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Start the NFL updater service to generate logs"
echo "2. Check Grafana Explore for log data"
echo "3. Import the NFL dashboard from dashboards/nfl-updater-monitoring.json"
echo ""
echo -e "${CYAN}Commands:${NC}"
echo "• Check agent: sudo systemctl status grafana-agent"
echo "• View logs: sudo journalctl -u grafana-agent -f"
echo "• Test locally: ls -la /var/log/nfl-updater/"