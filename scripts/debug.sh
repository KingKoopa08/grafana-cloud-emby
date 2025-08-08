#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Grafana Cloud Emby Monitoring Debug ===${NC}"
echo ""

# Function to check service status
check_service() {
    local service=$1
    echo -e "${BLUE}Checking $service...${NC}"
    
    if systemctl is-active --quiet "$service"; then
        echo -e "  Status: ${GREEN}Running${NC}"
        echo -e "  Uptime: $(systemctl show "$service" --property=ActiveEnterTimestamp --value)"
        
        # Show recent logs
        echo -e "  Recent logs:"
        sudo journalctl -u "$service" -n 5 --no-pager | sed 's/^/    /'
    else
        echo -e "  Status: ${RED}Not running${NC}"
        echo -e "  Last logs:"
        sudo journalctl -u "$service" -n 10 --no-pager | sed 's/^/    /'
    fi
    echo ""
}

# Function to check endpoint
check_endpoint() {
    local url=$1
    local name=$2
    
    echo -e "${BLUE}Checking $name endpoint...${NC}"
    if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200"; then
        echo -e "  ${GREEN}✓${NC} $url is accessible"
        
        # Show sample metrics for exporter
        if [[ "$name" == "Emby Exporter" ]]; then
            echo -e "  Sample metrics:"
            curl -s "$url" | grep "^emby_" | head -5 | sed 's/^/    /'
        fi
    else
        echo -e "  ${RED}✗${NC} $url is not accessible"
    fi
    echo ""
}

# Function to check configuration
check_config() {
    local config_file="/etc/grafana-agent/grafana-agent.yaml"
    
    echo -e "${BLUE}Checking Grafana Agent configuration...${NC}"
    if [ -f "$config_file" ]; then
        echo -e "  ${GREEN}✓${NC} Configuration file exists"
        
        # Validate configuration
        if grafana-agent -config.check "$config_file" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Configuration is valid"
        else
            echo -e "  ${RED}✗${NC} Configuration validation failed"
            grafana-agent -config.check "$config_file" 2>&1 | head -10 | sed 's/^/    /'
        fi
    else
        echo -e "  ${RED}✗${NC} Configuration file not found at $config_file"
    fi
    echo ""
}

# Function to check connectivity
check_connectivity() {
    echo -e "${BLUE}Checking connectivity...${NC}"
    
    # Check Emby server
    if curl -s -o /dev/null -w "%{http_code}" "${EMBY_SERVER_URL:-http://localhost:8096}/System/Info" | grep -q "200\|401"; then
        echo -e "  ${GREEN}✓${NC} Emby server is reachable"
    else
        echo -e "  ${RED}✗${NC} Cannot reach Emby server at ${EMBY_SERVER_URL:-http://localhost:8096}"
    fi
    
    # Check Grafana Cloud
    if curl -s -o /dev/null -w "%{http_code}" "https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query" | grep -q "401\|403"; then
        echo -e "  ${GREEN}✓${NC} Grafana Cloud Prometheus endpoint is reachable"
    else
        echo -e "  ${YELLOW}⚠${NC} Cannot verify Grafana Cloud Prometheus endpoint (may require auth)"
    fi
    
    if curl -s -o /dev/null -w "%{http_code}" "https://logs-prod-012.grafana.net/loki/api/v1/labels" | grep -q "401\|403"; then
        echo -e "  ${GREEN}✓${NC} Grafana Cloud Loki endpoint is reachable"
    else
        echo -e "  ${YELLOW}⚠${NC} Cannot verify Grafana Cloud Loki endpoint (may require auth)"
    fi
    echo ""
}

# Function to check metrics in Grafana Cloud
check_metrics_push() {
    echo -e "${BLUE}Checking metrics push status...${NC}"
    
    # Check agent metrics
    local agent_metrics=$(curl -s http://localhost:12345/metrics 2>/dev/null | grep "prometheus_remote_write_samples_total" | tail -1)
    if [ -n "$agent_metrics" ]; then
        echo -e "  Samples pushed: $(echo "$agent_metrics" | awk '{print $2}')"
    else
        echo -e "  ${YELLOW}⚠${NC} Cannot retrieve push metrics from agent"
    fi
    
    # Check for errors
    local errors=$(sudo journalctl -u grafana-agent -n 100 --no-pager | grep -c "remote write.*error" || true)
    if [ "$errors" -gt 0 ]; then
        echo -e "  ${RED}✗${NC} Found $errors remote write errors in last 100 log lines"
        echo -e "  Recent errors:"
        sudo journalctl -u grafana-agent -n 100 --no-pager | grep "remote write.*error" | tail -3 | sed 's/^/    /'
    else
        echo -e "  ${GREEN}✓${NC} No recent remote write errors"
    fi
    echo ""
}

# Function to show system resources
check_resources() {
    echo -e "${BLUE}System resource usage...${NC}"
    
    # CPU and Memory for services
    for service in grafana-agent emby-exporter; do
        if systemctl is-active --quiet "$service"; then
            local pid=$(systemctl show "$service" --property=MainPID --value)
            if [ "$pid" != "0" ]; then
                local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "N/A")
                local mem=$(ps -p "$pid" -o %mem= 2>/dev/null || echo "N/A")
                echo -e "  $service: CPU: ${cpu}%, Memory: ${mem}%"
            fi
        fi
    done
    
    # Disk usage
    echo -e "  Disk usage (/):"
    df -h / | tail -1 | awk '{print "    Used: "$3" / "$2" ("$5")"}'
    echo ""
}

# Function to provide troubleshooting tips
show_tips() {
    echo -e "${BLUE}Troubleshooting tips:${NC}"
    echo -e "  • View Grafana Agent logs: ${YELLOW}sudo journalctl -u grafana-agent -f${NC}"
    echo -e "  • View Emby Exporter logs: ${YELLOW}sudo journalctl -u emby-exporter -f${NC}"
    echo -e "  • Test Emby API: ${YELLOW}curl -H 'X-Emby-Token: YOUR_API_KEY' http://localhost:8096/System/Info${NC}"
    echo -e "  • Check metrics locally: ${YELLOW}curl http://localhost:9119/metrics${NC}"
    echo -e "  • Restart services: ${YELLOW}sudo systemctl restart grafana-agent emby-exporter${NC}"
    echo -e "  • Check config: ${YELLOW}cat /etc/grafana-agent/grafana-agent.yaml${NC}"
    echo ""
}

# Main debug flow
echo -e "${YELLOW}Timestamp: $(date)${NC}"
echo ""

# Load configuration if available
CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/config/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Configuration loaded from config.env"
else
    echo -e "${YELLOW}⚠${NC} Configuration file not found, using defaults"
fi
echo ""

# Run all checks
check_service "grafana-agent"
check_service "emby-exporter"
check_endpoint "http://localhost:9119/metrics" "Emby Exporter"
check_endpoint "http://localhost:12345/metrics" "Grafana Agent"
check_config
check_connectivity
check_metrics_push
check_resources
show_tips

echo -e "${BLUE}=== Debug complete ===${NC}"