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
CONFIG_FILE="${SCRIPT_DIR}/config/config.env"
BACKUP_DIR="${SCRIPT_DIR}/backups"

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

# Function to check for uncommitted changes
check_git_status() {
    print_status "Checking for local changes..."
    
    if ! git diff --quiet || ! git diff --cached --quiet; then
        print_warning "You have uncommitted local changes:"
        git status --short
        echo ""
        read -p "Do you want to stash these changes? (y/n): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git stash push -m "Auto-stash before update $(date +%Y%m%d-%H%M%S)"
            print_success "Changes stashed"
        else
            print_error "Cannot proceed with uncommitted changes"
            exit 1
        fi
    fi
}

# Function to backup configuration
backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_status "Backing up configuration..."
        mkdir -p "$BACKUP_DIR"
        
        BACKUP_FILE="${BACKUP_DIR}/config.env.$(date +%Y%m%d-%H%M%S)"
        cp "$CONFIG_FILE" "$BACKUP_FILE"
        print_success "Configuration backed up to: $BACKUP_FILE"
    fi
}

# Function to pull latest changes
pull_updates() {
    print_status "Fetching latest changes from GitHub..."
    
    # Fetch latest changes
    git fetch origin
    
    # Check if there are updates
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})
    BASE=$(git merge-base @ @{u})
    
    if [ "$LOCAL" = "$REMOTE" ]; then
        print_success "Already up to date"
        return 1
    elif [ "$LOCAL" = "$BASE" ]; then
        print_status "Updates available. Pulling changes..."
        git pull origin main
        print_success "Repository updated successfully"
        return 0
    elif [ "$REMOTE" = "$BASE" ]; then
        print_warning "You have local commits not pushed to remote"
        echo "Consider pushing your changes: git push origin main"
        return 1
    else
        print_error "Diverged from remote. Manual intervention required"
        exit 1
    fi
}

# Function to restore configuration
restore_config() {
    if [ ! -f "$CONFIG_FILE" ] && [ -n "$(ls -A ${BACKUP_DIR}/*.env.* 2>/dev/null)" ]; then
        print_status "Restoring configuration from backup..."
        
        # Get most recent backup
        LATEST_BACKUP=$(ls -t ${BACKUP_DIR}/config.env.* 2>/dev/null | head -1)
        
        if [ -f "$LATEST_BACKUP" ]; then
            cp "$LATEST_BACKUP" "$CONFIG_FILE"
            print_success "Configuration restored from backup"
        fi
    fi
}

# Function to update services
update_services() {
    print_status "Updating services..."
    
    # Check if services need updating
    local services_updated=false
    
    # Check Grafana Agent configuration
    if [ -f "/etc/grafana-agent/grafana-agent.yaml" ]; then
        if ! diff -q "${SCRIPT_DIR}/config/grafana-agent.yaml" "/etc/grafana-agent/grafana-agent.yaml" > /dev/null 2>&1; then
            print_status "Updating Grafana Agent configuration..."
            source "$CONFIG_FILE"
            envsubst < "${SCRIPT_DIR}/config/grafana-agent.yaml" | sudo tee /etc/grafana-agent/grafana-agent.yaml > /dev/null
            services_updated=true
        fi
    fi
    
    # Check Emby exporter
    if [ -f "/opt/emby-exporter/emby_exporter.py" ]; then
        if ! diff -q "${SCRIPT_DIR}/exporters/emby_exporter.py" "/opt/emby-exporter/emby_exporter.py" > /dev/null 2>&1; then
            print_status "Updating Emby exporter..."
            sudo cp "${SCRIPT_DIR}/exporters/emby_exporter.py" /opt/emby-exporter/
            sudo chown emby-exporter:emby-exporter /opt/emby-exporter/emby_exporter.py
            
            # Update Python dependencies if requirements changed
            if ! diff -q "${SCRIPT_DIR}/exporters/requirements.txt" "/opt/emby-exporter/requirements.txt" > /dev/null 2>&1; then
                print_status "Updating Python dependencies..."
                sudo cp "${SCRIPT_DIR}/exporters/requirements.txt" /opt/emby-exporter/
                sudo /opt/emby-exporter/venv/bin/pip install -r /opt/emby-exporter/requirements.txt
            fi
            
            services_updated=true
        fi
    fi
    
    if [ "$services_updated" = true ]; then
        print_status "Restarting services..."
        sudo systemctl restart grafana-agent
        sudo systemctl restart emby-exporter
        print_success "Services updated and restarted"
    else
        print_success "Services are already up to date"
    fi
}

# Function to show changelog
show_changelog() {
    print_status "Recent changes:"
    echo ""
    git log --oneline -10 --decorate
    echo ""
}

# Main update flow
main() {
    print_status "Starting Grafana Cloud Emby monitoring update..."
    echo ""
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "This is not a git repository. Please run from the repository directory."
        exit 1
    fi
    
    # Check git status
    check_git_status
    
    # Backup configuration
    backup_config
    
    # Pull updates
    if pull_updates; then
        # Show what changed
        show_changelog
        
        # Restore configuration
        restore_config
        
        # Update services if needed
        update_services
        
        # Run verification
        print_status "Running verification..."
        if [ -x "${SCRIPT_DIR}/scripts/debug.sh" ]; then
            "${SCRIPT_DIR}/scripts/debug.sh" | tail -20
        fi
        
        print_success "Update completed successfully!"
        echo ""
        echo "Next steps:"
        echo "1. Check service status: sudo systemctl status grafana-agent emby-exporter"
        echo "2. View logs if needed: sudo journalctl -u grafana-agent -f"
        echo "3. Import updated dashboards to Grafana Cloud if dashboard files changed"
    else
        print_status "No updates needed"
    fi
}

# Run main function
main "$@"