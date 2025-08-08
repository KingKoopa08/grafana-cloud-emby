# Grafana Cloud Emby Monitoring

Complete monitoring solution for Emby Media Server using Grafana Cloud's managed Prometheus and Loki services.

## Features

- **Real-time Emby Metrics**: Active streams, transcoding sessions, bandwidth usage, user activity
- **System Monitoring**: CPU, memory, disk, and network metrics from the Emby server
- **Log Aggregation**: Centralized logging for Emby, system, and web server logs
- **Custom Dashboards**: Pre-built Grafana dashboards for comprehensive monitoring
- **Cloud-Native**: Leverages Grafana Cloud's managed infrastructure
- **Easy Deployment**: Single script deployment with automated configuration

## Architecture

```
Emby Server (15.204.198.42)
├── Emby Media Server
├── Emby Exporter (Port 9119)
└── Grafana Agent
    ├── Metrics → Grafana Cloud Prometheus
    └── Logs → Grafana Cloud Loki
```

## Prerequisites

- Ubuntu/Debian-based Linux server running Emby
- Grafana Cloud account (free tier available)
- Emby API key
- Basic Linux administration knowledge

## Quick Start

### Option 1: One-Line Installation (Recommended)

SSH into your Emby server and run:

```bash
curl -sSL https://raw.githubusercontent.com/KingKoopa08/grafana-cloud-emby/main/setup.sh | bash
```

This will:
- Clone the repository to `/opt/grafana-cloud-emby`
- Set up all necessary permissions
- Start the deployment process

### Option 2: Manual Installation

```bash
# Clone the repository
git clone https://github.com/KingKoopa08/grafana-cloud-emby.git /opt/grafana-cloud-emby
cd /opt/grafana-cloud-emby

# Configure credentials
cp config/config.env.example config/config.env
nano config/config.env

# Run deployment
./deploy.sh
```

### 3. Configure Credentials

Edit the configuration file:
```bash
cd /opt/grafana-cloud-emby
nano config/config.env
```

Set these values:
- `GRAFANA_CLOUD_API_KEY`: Your Grafana Cloud API key
- `EMBY_API_KEY`: Your Emby server API key
- `EMBY_SERVER_URL`: Your Emby server URL (if not localhost)

The script will:
1. Install Grafana Agent
2. Set up the custom Emby exporter
3. Configure metric and log collection
4. Start all services
5. Verify the deployment

### 4. Import Dashboards

1. Log in to your Grafana Cloud instance
2. Navigate to Dashboards > Import
3. Upload the JSON files from `dashboards/`:
   - `emby-overview.json` - Main overview dashboard
   - `emby-streaming.json` - Streaming activity dashboard

## Getting API Keys

### Grafana Cloud API Key

1. Log in to [Grafana Cloud](https://grafana.com)
2. Go to **My Account** > **API Keys**
3. Click **Create API Key**
4. Select role: **MetricsPublisher**
5. Copy the generated key

### Emby API Key

1. Log in to Emby Web UI
2. Go to **Settings** > **API Keys**
3. Click **New API Key**
4. Enter application name: "Grafana Monitoring"
5. Copy the generated key

## Collected Metrics

### Emby Metrics
- `emby_up` - Server availability
- `emby_active_sessions` - Active user sessions
- `emby_active_streams` - Active streaming sessions
- `emby_active_transcodes` - Active transcoding sessions
- `emby_total_bandwidth_bytes` - Total bandwidth usage
- `emby_user_play_count` - Play count by user
- `emby_library_items` - Items per library
- `emby_devices_active` - Active devices by type

### System Metrics
- CPU usage and load average
- Memory usage and availability
- Disk I/O and usage
- Network traffic
- Process statistics

## Service Management

### Check Service Status

```bash
sudo systemctl status grafana-agent
sudo systemctl status emby-exporter
```

### View Logs

```bash
# Grafana Agent logs
sudo journalctl -u grafana-agent -f

# Emby Exporter logs
sudo journalctl -u emby-exporter -f
```

### Restart Services

```bash
sudo systemctl restart grafana-agent
sudo systemctl restart emby-exporter
```

## Troubleshooting

Run the debug script for comprehensive diagnostics:

```bash
./scripts/debug.sh
```

This will check:
- Service status
- Endpoint accessibility
- Configuration validity
- Connectivity to Grafana Cloud
- Recent error logs

### Common Issues

1. **Metrics not appearing in Grafana**
   - Verify API key is correct
   - Check Grafana Agent logs for authentication errors
   - Ensure firewall allows outbound HTTPS

2. **Emby exporter not starting**
   - Verify Emby API key is correct
   - Check Emby server is accessible
   - Review exporter logs for Python errors

3. **High resource usage**
   - Adjust `SCRAPE_INTERVAL` in config.env
   - Reduce log verbosity in Grafana Agent config
   - Check for runaway Python processes

## Configuration Files

- `config/config.env` - Environment variables and API keys
- `config/grafana-agent.yaml` - Grafana Agent configuration
- `exporters/emby_exporter.py` - Custom Emby metrics exporter
- `/etc/systemd/system/grafana-agent.service` - Grafana Agent service
- `/etc/systemd/system/emby-exporter.service` - Emby exporter service

## Security Considerations

- Store API keys securely and never commit them to version control
- Use HTTPS for Emby server connections when possible
- Regularly rotate API keys
- Monitor access logs for suspicious activity
- Keep Grafana Agent and dependencies updated

## Monitoring Best Practices

1. **Set up alerts** for critical metrics (server down, high CPU, etc.)
2. **Create custom dashboards** for specific use cases
3. **Use annotations** to mark maintenance windows
4. **Regular backups** of dashboard configurations
5. **Monitor costs** if exceeding Grafana Cloud free tier

## Updates and Maintenance

### Update from GitHub

Pull latest changes and update services:

```bash
cd /opt/grafana-cloud-emby
./update.sh
```

Or use Make:

```bash
cd /opt/grafana-cloud-emby
make update
```

### Manual Component Updates

Update Grafana Agent only:
```bash
./scripts/install-agent.sh
sudo systemctl restart grafana-agent
```

Update Emby Exporter only:
```bash
./scripts/setup-exporter.sh
sudo systemctl restart emby-exporter
```

### Using Make Commands

The project includes a Makefile for easy management:

```bash
make help          # Show all available commands
make status        # Check service status
make logs          # Tail service logs
make restart       # Restart all services
make debug         # Run diagnostics
make config        # Edit configuration
make update        # Pull and apply updates
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

MIT License - See LICENSE file for details

## Support

- GitHub Issues: [Report bugs or request features](https://github.com/KingKoopa08/grafana-cloud-emby/issues)
- Grafana Community: [Grafana Community Forums](https://community.grafana.com)
- Emby Forums: [Emby Community](https://emby.media/community)

## Acknowledgments

- Grafana Labs for Grafana Cloud
- Emby Team for the media server
- Prometheus community for monitoring standards