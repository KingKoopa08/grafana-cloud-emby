# Detailed Setup Guide

This guide provides step-by-step instructions for setting up Grafana Cloud monitoring for your Emby server.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Grafana Cloud Setup](#grafana-cloud-setup)
3. [Emby Configuration](#emby-configuration)
4. [Deployment](#deployment)
5. [Dashboard Configuration](#dashboard-configuration)
6. [Verification](#verification)

## Prerequisites

### System Requirements

- **Operating System**: Ubuntu 20.04+ or Debian 10+
- **Memory**: Minimum 512MB available RAM
- **Disk Space**: 1GB free space
- **Network**: Outbound HTTPS access to Grafana Cloud
- **Python**: Version 3.7 or higher

### Required Packages

The deployment script will automatically install these if missing:
- `curl`
- `wget`
- `python3`
- `python3-pip`
- `python3-venv`
- `systemctl`

## Grafana Cloud Setup

### 1. Create Grafana Cloud Account

1. Visit [https://grafana.com](https://grafana.com)
2. Click "Get Started for Free"
3. Sign up with email or social login
4. Choose a stack name (e.g., "emby-monitoring")
5. Select your region (choose closest to your server)

### 2. Get Your Stack Details

After creating your stack, note down:

```
Instance URL: https://[your-stack].grafana.net
Prometheus Endpoint: https://prometheus-[region].grafana.net/api/prom
Loki Endpoint: https://logs-[region].grafana.net
Username/Instance ID: [numeric-id]
```

### 3. Generate API Key

1. In Grafana Cloud, go to **Configuration** > **API Keys**
2. Click **Add API Key**
3. Set the following:
   - Key name: `emby-monitoring`
   - Role: `MetricsPublisher`
   - Time to live: Never (or set expiration)
4. Click **Create API Key**
5. **Important**: Copy the key immediately (shown only once)

## Emby Configuration

### 1. Enable API Access

1. Log in to Emby Server web interface
2. Navigate to **Settings** > **Advanced** > **API**
3. Ensure "Allow remote connections" is enabled
4. Note the HTTP port (default: 8096)

### 2. Create API Key

1. Go to **Settings** > **API Keys**
2. Click **New API Key**
3. Configure:
   - App name: `Grafana Monitoring`
   - Device name: `grafana-agent`
4. Click **Create**
5. Copy the generated API key

### 3. Test API Access

Verify API access with curl:

```bash
curl -H "X-Emby-Token: YOUR_API_KEY" \
     http://YOUR_EMBY_SERVER:8096/System/Info
```

You should receive a JSON response with server information.

## Deployment

### 1. Prepare the Server

SSH into your Emby server:

```bash
ssh user@15.204.198.42
```

### 2. Download the Repository

```bash
# Option 1: Using git
git clone https://github.com/KingKoopa08/grafana-cloud-emby.git
cd grafana-cloud-emby

# Option 2: Using wget (if git is not available)
wget https://github.com/KingKoopa08/grafana-cloud-emby/archive/main.zip
unzip main.zip
cd grafana-cloud-emby-main
```

### 3. Configure Environment

Create configuration from template:

```bash
cp config/config.env.example config/config.env
```

Edit configuration file:

```bash
nano config/config.env
```

Update these values:

```bash
# Grafana Cloud Configuration
GRAFANA_CLOUD_API_KEY="glc_eyJvIjoiMTIzNDU2Ii..."  # Your actual API key
GRAFANA_CLOUD_URL="https://kingkoopa08.grafana.net"
GRAFANA_CLOUD_USER="2607589"

# Emby Configuration
EMBY_SERVER_URL="http://localhost:8096"  # Or external URL
EMBY_API_KEY="abc123def456..."  # Your Emby API key
```

### 4. Run Deployment Script

Make the script executable and run:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Check prerequisites
2. Install Grafana Agent
3. Set up Python virtual environment
4. Install Emby exporter
5. Configure services
6. Start monitoring

### 5. Handle Prompts

During deployment, you may see:

```
[INFO] Configuration file not found. Creating from template...
[ERROR] Please edit /path/to/config.env with your actual values before continuing.
```

If this happens:
1. Edit the config.env file as shown above
2. Run `./deploy.sh` again

## Dashboard Configuration

### 1. Access Grafana Cloud

1. Log in to your Grafana Cloud instance
2. URL: `https://[your-stack].grafana.net`

### 2. Add Data Source (if needed)

Usually auto-configured, but if needed:

1. Go to **Configuration** > **Data Sources**
2. Click **Add data source**
3. Select **Prometheus**
4. Configure:
   - URL: Your Prometheus endpoint
   - Auth: Basic auth
   - User: Your instance ID
   - Password: Your API key

### 3. Import Dashboards

1. Go to **Dashboards** > **Browse**
2. Click **Import**
3. Upload JSON files from `dashboards/`:

   **emby-overview.json**:
   - Overall server health
   - Active sessions and bandwidth
   - Library statistics
   - System resources

   **emby-streaming.json**:
   - Detailed streaming metrics
   - User activity tracking
   - Device analytics
   - Playback statistics

### 4. Configure Dashboard Variables

After importing, configure the datasource variable:

1. Edit dashboard settings
2. Go to **Variables**
3. Update `datasource` variable
4. Set default to your Prometheus datasource

## Verification

### 1. Check Services

Verify all services are running:

```bash
# Check Grafana Agent
sudo systemctl status grafana-agent

# Check Emby Exporter
sudo systemctl status emby-exporter

# Check metrics endpoint
curl http://localhost:9119/metrics | grep emby_
```

### 2. Verify Data in Grafana

1. Go to **Explore** in Grafana Cloud
2. Select Prometheus datasource
3. Run test queries:

```promql
# Check if Emby is up
emby_up

# Check active streams
emby_active_streams

# Check system metrics
node_cpu_seconds_total
```

### 3. Run Debug Script

For comprehensive verification:

```bash
./scripts/debug.sh
```

This will show:
- Service status
- Endpoint connectivity
- Configuration validation
- Recent logs
- Resource usage

## Post-Installation

### 1. Set Up Alerts

Create alerts for critical metrics:

1. Go to **Alerting** > **Alert Rules**
2. Click **New alert rule**
3. Example alerts:
   - Emby server down: `emby_up == 0`
   - High CPU usage: `node_cpu_usage > 80`
   - Multiple transcodes: `emby_active_transcodes > 3`

### 2. Configure Retention

Manage data retention in Grafana Cloud:

1. Go to **Billing** > **Usage**
2. Check metrics and logs usage
3. Adjust retention if needed

### 3. Optimize Performance

If experiencing high resource usage:

1. Increase scrape interval in config.env
2. Reduce log verbosity
3. Disable unnecessary collectors

```bash
# Edit configuration
nano config/config.env

# Change scrape interval (seconds)
SCRAPE_INTERVAL="60"  # Increase from 30

# Restart services
sudo systemctl restart emby-exporter
sudo systemctl restart grafana-agent
```

## Troubleshooting

### Metrics Not Appearing

1. Check API key permissions
2. Verify network connectivity
3. Review agent logs:
   ```bash
   sudo journalctl -u grafana-agent -n 50
   ```

### Authentication Errors

1. Regenerate API key in Grafana Cloud
2. Update config.env
3. Restart services

### High Memory Usage

1. Check for memory leaks:
   ```bash
   ps aux | grep -E "grafana|emby_exporter"
   ```
2. Restart services if needed
3. Consider upgrading server resources

## Next Steps

- [Create custom dashboards](https://grafana.com/docs/grafana/latest/dashboards/)
- [Set up alert notifications](https://grafana.com/docs/grafana/latest/alerting/)
- [Explore Grafana Cloud features](https://grafana.com/docs/grafana-cloud/)
- [Join Grafana Community](https://community.grafana.com)