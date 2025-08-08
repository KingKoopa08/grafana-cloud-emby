.PHONY: help install update deploy config status logs restart stop clean debug dashboard-export dashboard-import

# Default target
help:
	@echo "Grafana Cloud Emby Monitoring - Management Commands"
	@echo ""
	@echo "Setup & Deployment:"
	@echo "  make install       - Initial installation (clone from GitHub)"
	@echo "  make deploy        - Deploy/redeploy all components"
	@echo "  make update        - Pull latest changes from GitHub and update"
	@echo "  make config        - Edit configuration file"
	@echo ""
	@echo "Service Management:"
	@echo "  make status        - Check status of all services"
	@echo "  make restart       - Restart all services"
	@echo "  make stop          - Stop all services"
	@echo "  make logs          - Tail logs from all services"
	@echo ""
	@echo "Troubleshooting:"
	@echo "  make debug         - Run diagnostic script"
	@echo "  make test-emby     - Test Emby API connection"
	@echo "  make test-grafana  - Test Grafana Cloud connection"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean         - Clean temporary files and caches"
	@echo "  make backup        - Backup configuration"
	@echo "  make restore       - Restore configuration from backup"

# Installation from GitHub
install:
	@echo "Installing from GitHub..."
	@bash setup.sh

# Deploy all components
deploy:
	@echo "Deploying all components..."
	@bash deploy.sh

# Update from GitHub
update:
	@echo "Updating from GitHub..."
	@bash update.sh

# Edit configuration
config:
	@if [ ! -f config/config.env ]; then \
		echo "Creating configuration from template..."; \
		cp config/config.env.example config/config.env; \
	fi
	@$${EDITOR:-nano} config/config.env

# Check service status
status:
	@echo "=== Service Status ==="
	@sudo systemctl status grafana-agent --no-pager | head -15
	@echo ""
	@sudo systemctl status emby-exporter --no-pager | head -15
	@echo ""
	@echo "=== Metrics Endpoints ==="
	@curl -s http://localhost:9119/metrics > /dev/null 2>&1 && echo "✓ Emby Exporter: http://localhost:9119/metrics" || echo "✗ Emby Exporter: Not responding"
	@curl -s http://localhost:12345/metrics > /dev/null 2>&1 && echo "✓ Grafana Agent: http://localhost:12345/metrics" || echo "✗ Grafana Agent: Not responding"

# Tail logs
logs:
	@echo "Tailing logs (Ctrl+C to exit)..."
	@sudo journalctl -u grafana-agent -u emby-exporter -f

# Restart services
restart:
	@echo "Restarting services..."
	@sudo systemctl restart grafana-agent
	@sudo systemctl restart emby-exporter
	@echo "Services restarted"
	@sleep 3
	@make status

# Stop services
stop:
	@echo "Stopping services..."
	@sudo systemctl stop grafana-agent
	@sudo systemctl stop emby-exporter
	@echo "Services stopped"

# Run debug script
debug:
	@bash scripts/debug.sh

# Test Emby connection
test-emby:
	@echo "Testing Emby API connection..."
	@if [ -f config/config.env ]; then \
		source config/config.env; \
		curl -s -H "X-Emby-Token: $$EMBY_API_KEY" "$$EMBY_SERVER_URL/System/Info" | python3 -m json.tool | head -20; \
	else \
		echo "Error: config/config.env not found"; \
		exit 1; \
	fi

# Test Grafana Cloud connection
test-grafana:
	@echo "Testing Grafana Cloud connection..."
	@if [ -f config/config.env ]; then \
		source config/config.env; \
		response=$$(curl -s -o /dev/null -w "%{http_code}" -u "$$GRAFANA_CLOUD_USER:$$GRAFANA_CLOUD_API_KEY" \
			"https://prometheus-prod-36-prod-us-west-0.grafana.net/api/prom/api/v1/query?query=up"); \
		if [ "$$response" = "200" ]; then \
			echo "✓ Grafana Cloud connection successful"; \
		else \
			echo "✗ Grafana Cloud connection failed (HTTP $$response)"; \
		fi; \
	else \
		echo "Error: config/config.env not found"; \
		exit 1; \
	fi

# Clean temporary files
clean:
	@echo "Cleaning temporary files..."
	@find . -type f -name "*.pyc" -delete
	@find . -type d -name "__pycache__" -delete
	@find . -type f -name "*.log" -delete
	@find . -type f -name "*.pid" -delete
	@find . -type f -name ".DS_Store" -delete
	@echo "Cleanup complete"

# Backup configuration
backup:
	@mkdir -p backups
	@if [ -f config/config.env ]; then \
		backup_file="backups/config.env.$$(date +%Y%m%d-%H%M%S)"; \
		cp config/config.env "$$backup_file"; \
		echo "Configuration backed up to: $$backup_file"; \
	else \
		echo "No configuration file to backup"; \
	fi

# Restore latest backup
restore:
	@if [ -d backups ] && [ "$$(ls -A backups/config.env.* 2>/dev/null)" ]; then \
		latest=$$(ls -t backups/config.env.* | head -1); \
		cp "$$latest" config/config.env; \
		echo "Restored configuration from: $$latest"; \
	else \
		echo "No backup found to restore"; \
	fi

# Export dashboards from Grafana Cloud
dashboard-export:
	@echo "Exporting dashboards from Grafana Cloud..."
	@echo "This feature requires Grafana API access"
	@echo "TODO: Implement dashboard export via API"

# Import dashboards to Grafana Cloud
dashboard-import:
	@echo "To import dashboards to Grafana Cloud:"
	@echo "1. Log in to your Grafana Cloud instance"
	@echo "2. Go to Dashboards > Import"
	@echo "3. Upload these JSON files:"
	@ls -la dashboards/*.json

# Git shortcuts
pull:
	@git pull origin main

push:
	@git add -A
	@git commit -m "Update configuration and deployment scripts"
	@git push origin main

# Show current version/commit
version:
	@echo "Current version:"
	@git describe --tags --always --dirty
	@echo ""
	@echo "Latest commit:"
	@git log -1 --oneline