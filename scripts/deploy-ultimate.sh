#!/bin/bash

# Ultimate Live TV Deployment Script
# Deploy the enhanced Live TV monitoring with all features

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
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${PROJECT_DIR}/config"
EXPORTERS_DIR="${PROJECT_DIR}/exporters"
DASHBOARDS_DIR="${PROJECT_DIR}/dashboards"

print_banner() {
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║     🚀 EMBY LIVE TV ULTIMATE MONITORING DEPLOYMENT 🚀       ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if configuration exists
check_config() {
    print_status "Checking configuration..."
    
    if [ ! -f "${CONFIG_DIR}/config.env" ]; then
        print_error "Configuration file not found!"
        print_warning "Please create ${CONFIG_DIR}/config.env with your API keys"
        echo ""
        echo "Required values:"
        echo "  EMBY_API_KEY=your-emby-api-key"
        echo "  GRAFANA_CLOUD_API_KEY=your-grafana-api-key"
        echo "  GRAFANA_CLOUD_USER=your-instance-id"
        echo ""
        exit 1
    fi
    
    source "${CONFIG_DIR}/config.env"
    
    if [ -z "${EMBY_API_KEY:-}" ] || [ -z "${GRAFANA_CLOUD_API_KEY:-}" ]; then
        print_error "API keys not configured properly"
        exit 1
    fi
    
    print_success "Configuration loaded"
}

# Stop existing services
stop_existing_services() {
    print_status "Stopping existing services..."
    
    # Stop old exporter if running
    if systemctl is-active --quiet emby-exporter 2>/dev/null; then
        sudo systemctl stop emby-exporter
        print_success "Stopped emby-exporter"
    fi
    
    # Stop Live TV exporter if running
    if systemctl is-active --quiet emby-livetv-exporter 2>/dev/null; then
        sudo systemctl stop emby-livetv-exporter
        print_success "Stopped emby-livetv-exporter"
    fi
}

# Install Ultimate Live TV Exporter
install_ultimate_exporter() {
    print_status "Installing Ultimate Live TV Exporter..."
    
    # Create directory
    sudo mkdir -p /opt/emby-livetv-ultimate
    
    # Copy exporter
    sudo cp "${EXPORTERS_DIR}/emby_livetv_ultimate.py" /opt/emby-livetv-ultimate/
    sudo chmod +x /opt/emby-livetv-ultimate/emby_livetv_ultimate.py
    
    # Create virtual environment
    print_status "Setting up Python environment..."
    sudo python3 -m venv /opt/emby-livetv-ultimate/venv
    
    # Install dependencies
    sudo /opt/emby-livetv-ultimate/venv/bin/pip install --upgrade pip
    sudo /opt/emby-livetv-ultimate/venv/bin/pip install \
        prometheus-client==0.19.0 \
        requests==2.31.0 \
        python-dateutil==2.8.2
    
    # Create user if not exists
    if ! id -u emby-exporter &>/dev/null; then
        sudo useradd --system --no-create-home --shell /bin/false emby-exporter
    fi
    
    # Set permissions
    sudo chown -R emby-exporter:emby-exporter /opt/emby-livetv-ultimate
    
    print_success "Ultimate exporter installed"
}

# Create systemd service
create_systemd_service() {
    print_status "Creating systemd service..."
    
    sudo tee /etc/systemd/system/emby-livetv-ultimate.service > /dev/null <<EOF
[Unit]
Description=Emby Live TV Ultimate Prometheus Exporter
Documentation=https://github.com/yourusername/grafana-cloud-emby
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=emby-exporter
Group=emby-exporter
Environment="EMBY_SERVER_URL=${EMBY_SERVER_URL:-http://localhost:8096}"
Environment="EMBY_API_KEY=${EMBY_API_KEY}"
Environment="EXPORTER_PORT=9119"
Environment="SCRAPE_INTERVAL=30"
ExecStart=/opt/emby-livetv-ultimate/venv/bin/python3 /opt/emby-livetv-ultimate/emby_livetv_ultimate.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=emby-livetv-ultimate

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    print_success "Systemd service created"
}

# Update Grafana Agent configuration
update_grafana_agent() {
    print_status "Updating Grafana Agent configuration..."
    
    # Backup existing config
    if [ -f /etc/grafana-agent/grafana-agent.yaml ]; then
        sudo cp /etc/grafana-agent/grafana-agent.yaml /etc/grafana-agent/grafana-agent.yaml.backup
    fi
    
    # Update with new scrape config
    envsubst < "${CONFIG_DIR}/grafana-agent.yaml" | sudo tee /etc/grafana-agent/grafana-agent.yaml > /dev/null
    
    # Restart Grafana Agent
    sudo systemctl restart grafana-agent
    
    print_success "Grafana Agent updated"
}

# Start services
start_services() {
    print_status "Starting services..."
    
    # Enable and start ultimate exporter
    sudo systemctl enable emby-livetv-ultimate
    sudo systemctl start emby-livetv-ultimate
    
    sleep 3
    
    # Check if running
    if systemctl is-active --quiet emby-livetv-ultimate; then
        print_success "Ultimate Live TV exporter is running"
    else
        print_error "Failed to start Ultimate Live TV exporter"
        sudo journalctl -u emby-livetv-ultimate -n 20 --no-pager
        exit 1
    fi
    
    # Check metrics endpoint
    if curl -s http://localhost:9119/metrics | grep -q "emby_livetv_"; then
        print_success "Metrics endpoint is responding"
    else
        print_warning "Metrics endpoint not fully ready yet"
    fi
}

# Deploy dashboards
deploy_dashboards() {
    print_status "Dashboard deployment instructions..."
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}IMPORT DASHBOARDS TO GRAFANA CLOUD:${NC}"
    echo ""
    echo "1. Log in to your Grafana Cloud instance"
    echo "   URL: ${GRAFANA_CLOUD_URL:-https://grafana.com}"
    echo ""
    echo "2. Navigate to: Dashboards > Import"
    echo ""
    echo "3. Import these dashboard files:"
    echo -e "   ${GREEN}• ${DASHBOARDS_DIR}/emby-livetv-ultimate.json${NC} (Main Ultimate Dashboard)"
    echo -e "   ${BLUE}• ${DASHBOARDS_DIR}/emby-livetv.json${NC} (Standard Live TV Dashboard)"
    echo -e "   ${BLUE}• ${DASHBOARDS_DIR}/emby-overview.json${NC} (Server Overview)"
    echo ""
    echo "4. For each dashboard:"
    echo "   - Click 'Upload JSON file'"
    echo "   - Select the dashboard file"
    echo "   - Choose your Prometheus datasource"
    echo "   - Click 'Import'"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# Deploy alert rules
deploy_alerts() {
    print_status "Alert rules deployment..."
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}CONFIGURE ALERT RULES:${NC}"
    echo ""
    echo "1. In Grafana Cloud, go to: Alerting > Alert rules"
    echo ""
    echo "2. Click 'New alert rule' and create rules from:"
    echo "   ${CONFIG_DIR}/alerts.yaml"
    echo ""
    echo "3. Key alerts to configure:"
    echo "   • EmbyServerDown - Critical server monitoring"
    echo "   • AllTunersInUse - Capacity alerts"
    echo "   • HighBandwidthUsage - Performance monitoring"
    echo "   • RecordingFailed - DVR failure detection"
    echo ""
    echo "4. Configure notification channels:"
    echo "   • Email"
    echo "   • Slack"
    echo "   • PagerDuty"
    echo "   • Webhook"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# Verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    echo ""
    
    local all_good=true
    
    # Check exporter
    if systemctl is-active --quiet emby-livetv-ultimate; then
        echo -e "  ${GREEN}✓${NC} Ultimate Live TV Exporter: Running"
    else
        echo -e "  ${RED}✗${NC} Ultimate Live TV Exporter: Not running"
        all_good=false
    fi
    
    # Check Grafana Agent
    if systemctl is-active --quiet grafana-agent; then
        echo -e "  ${GREEN}✓${NC} Grafana Agent: Running"
    else
        echo -e "  ${RED}✗${NC} Grafana Agent: Not running"
        all_good=false
    fi
    
    # Check metrics
    local metrics_count=$(curl -s http://localhost:9119/metrics 2>/dev/null | grep -c "emby_livetv_" || echo "0")
    if [ "$metrics_count" -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} Metrics Available: $metrics_count Live TV metrics"
    else
        echo -e "  ${RED}✗${NC} No Live TV metrics found"
        all_good=false
    fi
    
    # Check Emby API
    if curl -s -H "X-Emby-Token: ${EMBY_API_KEY}" "${EMBY_SERVER_URL}/System/Info" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Emby API: Accessible"
    else
        echo -e "  ${RED}✗${NC} Emby API: Not accessible"
        all_good=false
    fi
    
    echo ""
    if [ "$all_good" = true ]; then
        print_success "Deployment verified successfully!"
    else
        print_warning "Some components need attention"
    fi
}

# Show metrics sample
show_metrics_sample() {
    print_status "Sample metrics..."
    echo ""
    echo -e "${CYAN}Key metrics now being collected:${NC}"
    
    curl -s http://localhost:9119/metrics 2>/dev/null | grep "^emby_livetv_" | head -20 | while read -r line; do
        echo "  • $line"
    done
    
    echo ""
    echo -e "${YELLOW}View all metrics:${NC} http://localhost:9119/metrics"
}

# Main deployment flow
main() {
    print_banner
    
    print_status "Starting Ultimate Live TV deployment..."
    echo ""
    
    check_config
    stop_existing_services
    install_ultimate_exporter
    create_systemd_service
    update_grafana_agent
    start_services
    
    echo ""
    print_success "Ultimate Live TV Exporter deployed!"
    echo ""
    
    verify_deployment
    echo ""
    
    deploy_dashboards
    echo ""
    
    deploy_alerts
    echo ""
    
    show_metrics_sample
    echo ""
    
    print_success "Deployment complete!"
    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo "1. Import the Ultimate dashboard to Grafana Cloud"
    echo "2. Configure alert rules"
    echo "3. Start streaming content in Emby to see metrics"
    echo "4. Monitor at: ${GRAFANA_CLOUD_URL:-https://grafana.com}"
    echo ""
    echo -e "${YELLOW}Service commands:${NC}"
    echo "  View logs:     sudo journalctl -u emby-livetv-ultimate -f"
    echo "  Restart:       sudo systemctl restart emby-livetv-ultimate"
    echo "  Status:        sudo systemctl status emby-livetv-ultimate"
    echo ""
}

# Run main function
main "$@"