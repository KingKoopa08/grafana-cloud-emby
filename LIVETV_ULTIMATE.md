# 🚀 Emby Live TV Ultimate Monitoring

The most comprehensive Live TV monitoring solution for Emby Media Server with Grafana Cloud.

## 🎯 Features

### Real-Time Analytics
- **Active Stream Monitoring**: Track concurrent streams, users, and bandwidth in real-time
- **Channel Analytics**: Popular channels, viewer distribution, channel availability
- **User Behavior**: Watch time, channel switches, concurrent streams per user
- **Quality Metrics**: Stream resolution, bitrate, transcoding vs direct play

### Infrastructure Monitoring
- **Tuner Management**: Utilization, availability, channel assignments
- **DVR/Recording**: Active recordings, scheduled timers, storage usage
- **Performance Metrics**: API response times, buffer health, channel switch time
- **Bandwidth Analysis**: Total usage, per-stream bandwidth, quality distribution

### Advanced Capabilities
- **Peak Usage Tracking**: 24-hour peak concurrent streams
- **Hourly Activity Patterns**: User activity by hour of day
- **Prime Time Analytics**: Usage patterns during peak hours
- **Channel Popularity Scoring**: Normalized popularity metrics
- **EPG Integration**: Program guide data, genre analysis, schedule monitoring

## 📊 Metrics Collected

### Core Metrics (70+ unique metrics)
```
emby_livetv_streams_active          # Active Live TV streams
emby_livetv_users_watching          # Users currently watching
emby_livetv_bandwidth_total_mbps    # Total bandwidth usage
emby_livetv_channels_total          # Total available channels
emby_livetv_tuner_utilization_percent # Tuner usage percentage
emby_livetv_channel_popularity      # Channel popularity scores
emby_livetv_stream_bitrate_kbps    # Per-stream bitrate
emby_livetv_transcoding_active      # Active transcoding sessions
```

### User Experience Metrics
```
emby_livetv_user_watch_time_seconds_total  # Total watch time
emby_livetv_channel_switches_total         # Channel switch count
emby_livetv_concurrent_streams             # Concurrent streams per user
emby_livetv_hourly_active_users           # Active users by hour
emby_livetv_prime_time_usage              # Prime time usage %
```

### Quality & Performance
```
emby_livetv_streams_by_quality    # Streams by quality (4K/1080p/720p/etc)
emby_livetv_stream_resolution     # Stream resolution height
emby_livetv_stream_framerate      # Stream framerate
emby_livetv_buffer_health_percent # Buffer health percentage
emby_livetv_channel_switch_seconds # Channel switch time histogram
```

## 🚀 Quick Deployment

### 1. Prerequisites
- Emby Server with Live TV enabled
- Grafana Cloud account (free tier works)
- API keys for both services

### 2. Deploy Ultimate Monitoring
```bash
# Clone repository
git clone https://github.com/KingKoopa08/grafana-cloud-emby.git
cd grafana-cloud-emby

# Configure API keys
cp config/config.env.example config/config.env
nano config/config.env  # Add your API keys

# Deploy Ultimate Live TV monitoring
chmod +x scripts/deploy-ultimate.sh
./scripts/deploy-ultimate.sh
```

### 3. Import Dashboard
1. Log in to Grafana Cloud
2. Go to **Dashboards** > **Import**
3. Upload `dashboards/emby-livetv-ultimate.json`
4. Select your Prometheus datasource
5. Click **Import**

## 📈 Dashboard Features

### Live Status Overview
- Server status with real-time health monitoring
- Active streams gauge with trend graph
- User count with activity indicators
- Total bandwidth usage with color coding
- Tuner utilization gauge (0-100%)
- Stream quality distribution pie chart

### Real-Time Analytics
- Time series graphs for streaming activity
- Bandwidth usage over time with stacking
- User activity patterns
- Channel popularity trends

### Channel Analytics
- Sortable table with viewer counts
- Popularity scores (0-100%)
- Channel status indicators
- Top 10 popular channels pie chart

### User Experience
- Hourly activity histogram (24h view)
- User activity table with metrics:
  - Watch time (minutes)
  - Concurrent streams
  - Channel switches
- Per-user bandwidth tracking

### Infrastructure
- Tuner utilization over time
- Tuner status table with channel assignments
- DVR status with recording counts
- Storage usage tracking

## 🔔 Alert Rules

### Critical Alerts
- `EmbyServerDown`: Server offline > 2 minutes
- `AllTunersInUse`: 100% tuner utilization
- `RecordingFailed`: DVR recording failures
- `NoChannelsAvailable`: All channels offline

### Performance Alerts
- `HighBandwidthUsage`: > 500 Mbps total
- `ExcessiveTranscoding`: > 70% transcoding ratio
- `StreamingErrors`: Error rate > 0.1/sec
- `APIResponseSlow`: 95th percentile > 2s

### Capacity Alerts
- `PeakStreamingLoad`: > 50 concurrent streams
- `RecordingStorageFull`: > 1TB storage used
- `HighTunerUtilization`: > 80% tuners in use

### User Experience Alerts
- `HighChannelSwitchTime`: > 5 seconds
- `PoorStreamQuality`: > 50% low quality
- `BufferingIssues`: Buffer health < 80%

## 🛠️ Advanced Configuration

### Customize Scrape Interval
Edit `/etc/systemd/system/emby-livetv-ultimate.service`:
```bash
Environment="SCRAPE_INTERVAL=15"  # Faster updates (15 seconds)
```

### Adjust Metrics Retention
In Grafana Agent config:
```yaml
metrics:
  wal_truncate_frequency: 1h
  min_wal_time: 30m
  max_wal_time: 2h
```

### Performance Tuning
For high-load environments:
```python
# In emby_livetv_ultimate.py
CACHE_TTL = 120  # Increase cache time
SCRAPE_INTERVAL = 60  # Reduce frequency
```

## 📝 Troubleshooting

### Check Service Status
```bash
sudo systemctl status emby-livetv-ultimate
```

### View Logs
```bash
sudo journalctl -u emby-livetv-ultimate -f
```

### Test Metrics Endpoint
```bash
curl http://localhost:9119/metrics | grep emby_livetv_
```

### Debug Emby API
```bash
curl -H "X-Emby-Token: YOUR_API_KEY" \
     http://localhost:8096/LiveTv/Channels
```

### Common Issues

#### No Live TV Metrics
- Ensure Live TV is enabled in Emby
- Check API key has Live TV permissions
- Verify channels are configured

#### High CPU Usage
- Increase scrape interval
- Enable metric caching
- Reduce histogram buckets

#### Missing Channel Data
- Check tuner configuration
- Verify EPG data is available
- Ensure channels are not disabled

## 📊 Example Queries

### Prometheus Queries for Custom Panels

**Average Streams per Hour**
```promql
avg_over_time(emby_livetv_streams_active[1h])
```

**Top Channels by Watch Time**
```promql
topk(5, sum by (channel_name) (
  rate(emby_livetv_user_watch_time_seconds_total[24h])
))
```

**Transcoding Percentage**
```promql
100 * (emby_livetv_transcoding_active / emby_livetv_streams_active)
```

**Peak Concurrent Users Today**
```promql
max_over_time(emby_livetv_users_watching[24h])
```

**Channel Switch Frequency**
```promql
rate(emby_livetv_channel_switches_total[1h])
```

## 🎨 Dashboard Customization

### Add Custom Panels
1. Edit dashboard in Grafana
2. Add panel with query
3. Choose visualization type
4. Configure thresholds and colors

### Create User-Specific Views
Filter by user label:
```promql
emby_livetv_concurrent_streams{user="john"}
```

### Build Channel-Specific Dashboards
```promql
emby_livetv_streams_by_channel{channel_name="CNN"}
```

## 🔄 Updates

### Update Exporter
```bash
cd /opt/grafana-cloud-emby
git pull
./scripts/deploy-ultimate.sh
```

### Update Dashboard
1. Export current dashboard (save customizations)
2. Import new version
3. Merge customizations

## 📚 Resources

- [Emby API Documentation](https://dev.emby.media/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [Grafana Dashboard Guide](https://grafana.com/docs/grafana/latest/dashboards/)
- [Grafana Cloud Docs](https://grafana.com/docs/grafana-cloud/)

## 🤝 Contributing

Contributions welcome! Areas for improvement:
- Additional metrics collection
- Dashboard templates
- Alert rule refinements
- Performance optimizations
- Documentation improvements

## 📄 License

MIT License - See LICENSE file for details

## 🙏 Acknowledgments

- Emby Team for the excellent media server
- Grafana Labs for Grafana Cloud
- Prometheus community for metrics standards
- Contributors and testers

---

**Built with ❤️ for the Emby community**