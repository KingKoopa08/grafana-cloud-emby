#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
EXPORTERS_DIR="${SCRIPT_DIR}/exporters"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
LOG_FILE="/var/log/grafana-cloud-emby-deploy.log"
GITHUB_REPO="https://github.com/KingKoopa08/grafana-cloud-emby.git"

# Function to print colored output
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

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sudo tee -a "$LOG_FILE" > /dev/null
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root. It will use sudo when needed."
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    local missing_deps=()
    
    # Check for required commands
    for cmd in curl wget python3 pip3 systemctl; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_status "Installing missing dependencies..."
        
        sudo apt-get update
        for dep in "${missing_deps[@]}"; do
            case $dep in
                pip3)
                    sudo apt-get install -y python3-pip
                    ;;
                *)
                    sudo apt-get install -y "$dep"
                    ;;
            esac
        done
    fi
    
    print_success "All prerequisites are installed"
}

# Function to load configuration
load_configuration() {
    print_status "Loading configuration..."
    
    if [ ! -f "${CONFIG_DIR}/config.env" ]; then
        if [ -f "${CONFIG_DIR}/config.env.example" ]; then
            print_warning "Configuration file not found. Creating from template..."
            cp "${CONFIG_DIR}/config.env.example" "${CONFIG_DIR}/config.env"
            print_error "Please edit ${CONFIG_DIR}/config.env with your actual values before continuing."
            print_status "Required values:"
            echo "  - GRAFANA_CLOUD_API_KEY: Your Grafana Cloud API key"
            echo "  - EMBY_API_KEY: Your Emby server API key"
            echo "  - EMBY_SERVER_URL: Your Emby server URL (default: http://localhost:8096)"
            exit 1
        else
            print_error "Configuration template not found!"
            exit 1
        fi
    fi
    
    # Source the configuration
    source "${CONFIG_DIR}/config.env"
    
    # Validate required variables
    if [ -z "${GRAFANA_CLOUD_API_KEY:-}" ]; then
        print_error "GRAFANA_CLOUD_API_KEY is not set in config.env"
        exit 1
    fi
    
    if [ -z "${EMBY_API_KEY:-}" ]; then
        print_error "EMBY_API_KEY is not set in config.env"
        exit 1
    fi
    
    print_success "Configuration loaded successfully"
}

# Function to install Grafana Agent
install_grafana_agent() {
    print_status "Installing Grafana Agent..."
    
    if systemctl is-active --quiet grafana-agent; then
        print_warning "Grafana Agent is already running. Stopping it for reconfiguration..."
        sudo systemctl stop grafana-agent
    fi
    
    # Run the installation script
    bash "${SCRIPTS_DIR}/install-agent.sh"
    
    print_success "Grafana Agent installed"
}

# Function to setup Emby exporter
setup_emby_exporter() {
    print_status "Setting up Emby exporter..."
    
    # Run the exporter setup script
    bash "${SCRIPTS_DIR}/setup-exporter.sh"
    
    print_success "Emby exporter setup completed"
}

# Function to configure Grafana Agent
configure_grafana_agent() {
    print_status "Configuring Grafana Agent..."
    
    # Create agent configuration from template
    sudo mkdir -p /etc/grafana-agent
    
    # Process the template with actual values
    envsubst < "${CONFIG_DIR}/grafana-agent.yaml" | sudo tee /etc/grafana-agent/grafana-agent.yaml > /dev/null
    
    # Validate configuration
    if grafana-agent -config.check /etc/grafana-agent/grafana-agent.yaml 2>/dev/null; then
        print_success "Grafana Agent configuration is valid"
    else
        print_warning "Grafana Agent configuration validation failed. The agent may still work."
    fi
    
    print_success "Grafana Agent configured"
}

# Function to start services
start_services() {
    print_status "Starting services..."
    
    # Start Emby exporter
    if systemctl is-enabled --quiet emby-exporter 2>/dev/null; then
        sudo systemctl restart emby-exporter
        if systemctl is-active --quiet emby-exporter; then
            print_success "Emby exporter started"
        else
            print_error "Failed to start Emby exporter"
            sudo systemctl status emby-exporter --no-pager
        fi
    fi
    
    # Start Grafana Agent
    sudo systemctl enable grafana-agent
    sudo systemctl restart grafana-agent
    
    if systemctl is-active --quiet grafana-agent; then
        print_success "Grafana Agent started"
    else
        print_error "Failed to start Grafana Agent"
        sudo systemctl status grafana-agent --no-pager
        exit 1
    fi
}

# Function to verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    
    local all_good=true
    
    # Check if Emby exporter is responding
    if curl -s http://localhost:9119/metrics > /dev/null 2>&1; then
        print_success "Emby exporter is responding on port 9119"
    else
        print_error "Emby exporter is not responding on port 9119"
        all_good=false
    fi
    
    # Check if Grafana Agent is running
    if systemctl is-active --quiet grafana-agent; then
        print_success "Grafana Agent is running"
    else
        print_error "Grafana Agent is not running"
        all_good=false
    fi
    
    # Check agent logs for errors
    if sudo journalctl -u grafana-agent -n 10 --no-pager | grep -q ERROR; then
        print_warning "Found errors in Grafana Agent logs. Check with: sudo journalctl -u grafana-agent -f"
    fi
    
    if [ "$all_good" = true ]; then
        print_success "Deployment verification completed successfully"
    else
        print_error "Deployment verification failed. Please check the logs."
        exit 1
    fi
}

# Function to display next steps
display_next_steps() {
    echo ""
    print_success "Grafana Cloud Emby monitoring deployment completed!"
    echo ""
    echo "Next steps:"
    echo "1. Import dashboards to Grafana Cloud:"
    echo "   - Log in to ${GRAFANA_CLOUD_URL:-https://grafana.com}"
    echo "   - Go to Dashboards > Import"
    echo "   - Upload JSON files from ${SCRIPT_DIR}/dashboards/"
    echo ""
    echo "2. Verify metrics are being received:"
    echo "   - Check Explore in Grafana Cloud"
    echo "   - Query: emby_server_info"
    echo ""
    echo "3. Monitor services:"
    echo "   - Emby Exporter: sudo systemctl status emby-exporter"
    echo "   - Grafana Agent: sudo systemctl status grafana-agent"
    echo ""
    echo "4. View logs:"
    echo "   - Emby Exporter: sudo journalctl -u emby-exporter -f"
    echo "   - Grafana Agent: sudo journalctl -u grafana-agent -f"
    echo ""
    echo "5. Debug issues:"
    echo "   - Run: ${SCRIPTS_DIR}/debug.sh"
    echo ""
}

# Main deployment flow
main() {
    print_status "Starting Grafana Cloud Emby monitoring deployment..."
    log_message "Deployment started"
    
    check_root
    check_prerequisites
    load_configuration
    install_grafana_agent
    setup_emby_exporter
    configure_grafana_agent
    start_services
    verify_deployment
    display_next_steps
    
    log_message "Deployment completed successfully"
}

# Handle errors
trap 'print_error "Deployment failed. Check ${LOG_FILE} for details."' ERR

# Run main function
main "$@"