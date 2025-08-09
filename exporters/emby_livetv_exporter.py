#!/usr/bin/env python3

"""
Emby Live TV Exporter for Prometheus
Focused exclusively on Live TV metrics and monitoring
"""

import os
import sys
import time
import logging
import requests
from prometheus_client import start_http_server, Gauge, Counter, Info, Histogram
from datetime import datetime
from typing import Dict, List, Any
import json
from urllib.parse import urljoin
import re

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('emby_livetv_exporter')

# Configuration from environment variables
EMBY_SERVER_URL = os.getenv('EMBY_SERVER_URL', 'http://localhost:8096')
EMBY_API_KEY = os.getenv('EMBY_API_KEY', '')
EXPORTER_PORT = int(os.getenv('EXPORTER_PORT', '9119'))
SCRAPE_INTERVAL = int(os.getenv('SCRAPE_INTERVAL', '30'))

# Prometheus metrics for Live TV
# Server status
server_info = Info('emby_server', 'Emby server information')
server_up = Gauge('emby_up', 'Emby server is up and responding')

# Live TV Sessions
livetv_active_streams = Gauge('emby_livetv_active_streams', 'Number of active Live TV streams')
livetv_sessions = Gauge('emby_livetv_sessions', 'Live TV sessions by channel', ['channel_name', 'channel_number', 'user', 'client', 'device'])
livetv_stream_info = Info('emby_livetv_stream', 'Current Live TV stream information')

# Channel metrics
livetv_total_channels = Gauge('emby_livetv_channels_total', 'Total number of Live TV channels')
livetv_channel_status = Gauge('emby_livetv_channel_status', 'Channel availability status', ['channel_name', 'channel_number'])
livetv_current_program = Info('emby_livetv_current_program', 'Currently playing program information')

# Tuner metrics
livetv_tuners_total = Gauge('emby_livetv_tuners_total', 'Total number of tuners')
livetv_tuners_in_use = Gauge('emby_livetv_tuners_in_use', 'Number of tuners currently in use')
livetv_tuner_status = Gauge('emby_livetv_tuner_status', 'Tuner status (1=in use, 0=free)', ['tuner_id', 'tuner_name', 'tuner_type'])

# Recording metrics (if using DVR)
livetv_recordings_active = Gauge('emby_livetv_recordings_active', 'Number of active recordings')
livetv_recordings_scheduled = Gauge('emby_livetv_recordings_scheduled', 'Number of scheduled recordings')
livetv_recording_space_gb = Gauge('emby_livetv_recording_space_gb', 'Recording storage space used in GB')

# Stream quality metrics
livetv_stream_bitrate = Gauge('emby_livetv_stream_bitrate_mbps', 'Live TV stream bitrate in Mbps', ['channel_name', 'user'])
livetv_stream_resolution = Gauge('emby_livetv_stream_resolution', 'Stream resolution (height in pixels)', ['channel_name', 'user'])
livetv_stream_method = Gauge('emby_livetv_stream_method', 'Streaming method (1=Direct, 0=Transcode)', ['channel_name', 'user'])

# User watching metrics
livetv_users_watching = Gauge('emby_livetv_users_watching', 'Number of users watching Live TV')
livetv_channel_viewers = Gauge('emby_livetv_channel_viewers', 'Number of viewers per channel', ['channel_name', 'channel_number'])
livetv_watch_time_minutes = Counter('emby_livetv_watch_time_minutes_total', 'Total Live TV watch time in minutes', ['user', 'channel_name'])

# EPG/Guide metrics
livetv_guide_days = Gauge('emby_livetv_guide_days', 'Number of days of guide data available')
livetv_programs_today = Gauge('emby_livetv_programs_today', 'Number of programs in guide for today')

# Performance metrics
api_request_duration = Histogram('emby_api_request_duration_seconds', 'API request duration', ['endpoint'])
api_request_errors = Counter('emby_api_request_errors_total', 'Total API request errors', ['endpoint'])


def parse_emby_datetime(date_string):
    """Parse Emby datetime strings with extended microseconds."""
    if not date_string:
        return None
    
    try:
        if date_string.endswith('Z'):
            return datetime.fromisoformat(date_string.replace('Z', '+00:00'))
        else:
            return datetime.fromisoformat(date_string)
    except ValueError:
        try:
            # Handle extended microseconds
            pattern = r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d{6})\d*([+-]\d{2}:\d{2}|Z)?'
            match = re.match(pattern, date_string)
            if match:
                base_time = match.group(1)
                microseconds = match.group(2)
                timezone = match.group(3) or ''
                if timezone == 'Z':
                    timezone = '+00:00'
                fixed_date = f"{base_time}.{microseconds}{timezone}"
                return datetime.fromisoformat(fixed_date)
            return None
        except Exception:
            return None


class EmbyLiveTVExporter:
    def __init__(self, server_url: str, api_key: str):
        self.server_url = server_url.rstrip('/')
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({
            'X-Emby-Token': api_key,
            'Accept': 'application/json'
        })
        self.channel_watch_start = {}  # Track when users started watching channels
        
    def _make_request(self, endpoint: str, params: Dict = None) -> Any:
        """Make a request to the Emby API."""
        url = urljoin(self.server_url, endpoint)
        start_time = time.time()
        
        try:
            response = self.session.get(url, params=params, timeout=10)
            duration = time.time() - start_time
            api_request_duration.labels(endpoint=endpoint).observe(duration)
            
            if response.status_code == 404:
                logger.debug(f"Endpoint not found: {endpoint}")
                return None
                
            response.raise_for_status()
            return response.json()
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching {endpoint}: {e}")
            api_request_errors.labels(endpoint=endpoint).inc()
            return None
    
    def collect_server_info(self):
        """Collect server information."""
        info = self._make_request('/System/Info')
        if info:
            server_info.info({
                'version': str(info.get('Version', 'unknown')),
                'server_name': str(info.get('ServerName', 'unknown')),
                'has_livetv': str(info.get('HasLiveTv', False))
            })
            server_up.set(1)
            logger.info(f"Server: {info.get('ServerName')} v{info.get('Version')}, LiveTV: {info.get('HasLiveTv', False)}")
        else:
            server_up.set(0)
    
    def collect_livetv_sessions(self):
        """Collect Live TV streaming sessions."""
        sessions = self._make_request('/Sessions')
        if not sessions:
            return
        
        livetv_stream_count = 0
        users_watching_tv = set()
        channel_viewers = {}
        
        for session in sessions:
            now_playing = session.get('NowPlayingItem', {})
            
            # Check if this is Live TV
            if now_playing and now_playing.get('Type') == 'TvChannel':
                livetv_stream_count += 1
                
                # Extract session details
                user = session.get('UserName', 'unknown')
                client = session.get('Client', 'unknown')
                device = session.get('DeviceName', 'unknown')
                channel_name = now_playing.get('Name', 'Unknown Channel')
                channel_number = now_playing.get('ChannelNumber', 'N/A')
                
                users_watching_tv.add(user)
                
                # Track viewers per channel
                channel_key = f"{channel_name}|{channel_number}"
                channel_viewers[channel_key] = channel_viewers.get(channel_key, 0) + 1
                
                # Set session gauge
                livetv_sessions.labels(
                    channel_name=channel_name,
                    channel_number=channel_number,
                    user=user,
                    client=client,
                    device=device
                ).set(1)
                
                # Track watch time
                session_id = session.get('Id')
                if session_id not in self.channel_watch_start:
                    self.channel_watch_start[session_id] = time.time()
                
                # Get current program info
                current_program = now_playing.get('CurrentProgram', {})
                if current_program:
                    livetv_current_program.info({
                        'channel': channel_name,
                        'program_name': str(current_program.get('Name', 'Unknown')),
                        'start_time': str(current_program.get('StartDate', '')),
                        'end_time': str(current_program.get('EndDate', ''))
                    })
                
                # Stream quality metrics
                play_state = session.get('PlayState', {})
                play_method = play_state.get('PlayMethod', 'Unknown')
                
                # Set streaming method (1 for Direct, 0 for Transcode)
                is_direct = 1 if play_method in ['DirectStream', 'DirectPlay'] else 0
                livetv_stream_method.labels(
                    channel_name=channel_name,
                    user=user
                ).set(is_direct)
                
                # Get bitrate if available
                if 'TranscodingInfo' in session:
                    trans_info = session['TranscodingInfo']
                    bitrate = trans_info.get('Bitrate', 0)
                    if bitrate > 0:
                        bitrate_mbps = bitrate / 1000000
                        livetv_stream_bitrate.labels(
                            channel_name=channel_name,
                            user=user
                        ).set(bitrate_mbps)
                    
                    # Get resolution
                    height = trans_info.get('Height', 0)
                    if height > 0:
                        livetv_stream_resolution.labels(
                            channel_name=channel_name,
                            user=user
                        ).set(height)
                
                logger.info(f"LiveTV: {user} watching '{channel_name}' (Ch {channel_number}) on {device} via {play_method}")
        
        # Set metrics
        livetv_active_streams.set(livetv_stream_count)
        livetv_users_watching.set(len(users_watching_tv))
        
        # Set channel viewer counts
        for channel_key, count in channel_viewers.items():
            channel_name, channel_number = channel_key.split('|')
            livetv_channel_viewers.labels(
                channel_name=channel_name,
                channel_number=channel_number
            ).set(count)
        
        logger.info(f"Live TV Sessions: {livetv_stream_count} streams, {len(users_watching_tv)} users")
    
    def collect_channels(self):
        """Collect Live TV channel information."""
        # Get all Live TV channels
        channels = self._make_request('/LiveTv/Channels', params={'UserId': ''})
        
        if channels and 'Items' in channels:
            channel_count = channels.get('TotalRecordCount', 0)
            livetv_total_channels.set(channel_count)
            
            # Check channel status
            for channel in channels.get('Items', [])[:100]:  # Limit to first 100 channels
                channel_name = channel.get('Name', 'Unknown')
                channel_number = channel.get('Number', 'N/A')
                
                # Channel is available if it has a valid ID
                is_available = 1 if channel.get('Id') else 0
                livetv_channel_status.labels(
                    channel_name=channel_name,
                    channel_number=channel_number
                ).set(is_available)
            
            logger.info(f"Live TV Channels: {channel_count} total")
    
    def collect_tuners(self):
        """Collect tuner information."""
        tuners = self._make_request('/LiveTv/Tuners')
        
        if tuners and isinstance(tuners, list):
            total_tuners = len(tuners)
            tuners_in_use = 0
            
            for tuner in tuners:
                tuner_id = tuner.get('Id', 'unknown')
                tuner_name = tuner.get('Name', 'Unknown Tuner')
                tuner_type = tuner.get('Type', 'Unknown')
                
                # Check if tuner is in use
                is_in_use = 1 if tuner.get('ChannelId') or tuner.get('Status') == 'LiveTv' else 0
                if is_in_use:
                    tuners_in_use += 1
                
                livetv_tuner_status.labels(
                    tuner_id=tuner_id,
                    tuner_name=tuner_name,
                    tuner_type=tuner_type
                ).set(is_in_use)
            
            livetv_tuners_total.set(total_tuners)
            livetv_tuners_in_use.set(tuners_in_use)
            
            logger.info(f"Tuners: {tuners_in_use}/{total_tuners} in use")
    
    def collect_recordings(self):
        """Collect DVR recording information."""
        # Active recordings
        active_recordings = self._make_request('/LiveTv/Recordings', params={'IsInProgress': True})
        if active_recordings and 'Items' in active_recordings:
            livetv_recordings_active.set(active_recordings.get('TotalRecordCount', 0))
        
        # Scheduled recordings
        scheduled = self._make_request('/LiveTv/Timers')
        if scheduled and 'Items' in scheduled:
            livetv_recordings_scheduled.set(scheduled.get('TotalRecordCount', 0))
        
        # Recording storage (if available)
        recordings = self._make_request('/LiveTv/Recordings')
        if recordings and 'Items' in recordings:
            total_size_bytes = sum(item.get('Size', 0) for item in recordings.get('Items', []))
            total_size_gb = total_size_bytes / (1024 * 1024 * 1024)
            livetv_recording_space_gb.set(total_size_gb)
    
    def collect_guide(self):
        """Collect EPG/Guide information."""
        # Get guide info
        guide = self._make_request('/LiveTv/Programs', params={
            'MinStartDate': datetime.now().isoformat(),
            'MaxStartDate': (datetime.now().replace(hour=23, minute=59)).isoformat(),
            'Limit': 1
        })
        
        if guide and 'TotalRecordCount' in guide:
            livetv_programs_today.set(guide.get('TotalRecordCount', 0))
            logger.info(f"EPG: {guide.get('TotalRecordCount', 0)} programs today")
    
    def collect_all_metrics(self):
        """Collect all Live TV metrics."""
        logger.info("=" * 60)
        logger.info("Starting Live TV metrics collection...")
        
        try:
            self.collect_server_info()
            self.collect_livetv_sessions()
            self.collect_channels()
            self.collect_tuners()
            self.collect_recordings()
            self.collect_guide()
            
            logger.info("Live TV metrics collection completed")
            
        except Exception as e:
            logger.error(f"Error during metrics collection: {e}")
            import traceback
            logger.error(traceback.format_exc())
            server_up.set(0)


def main():
    """Main function to run the Live TV exporter."""
    if not EMBY_API_KEY:
        logger.error("EMBY_API_KEY environment variable is not set!")
        sys.exit(1)
    
    logger.info("=" * 60)
    logger.info("EMBY LIVE TV EXPORTER STARTING")
    logger.info("=" * 60)
    logger.info(f"Server URL: {EMBY_SERVER_URL}")
    logger.info(f"Exporter Port: {EXPORTER_PORT}")
    logger.info(f"Scrape Interval: {SCRAPE_INTERVAL}s")
    
    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)
    logger.info(f"Prometheus metrics available at http://localhost:{EXPORTER_PORT}/metrics")
    
    # Create exporter instance
    exporter = EmbyLiveTVExporter(EMBY_SERVER_URL, EMBY_API_KEY)
    
    # Initial collection
    exporter.collect_all_metrics()
    
    # Main loop
    while True:
        time.sleep(SCRAPE_INTERVAL)
        exporter.collect_all_metrics()


if __name__ == '__main__':
    main()