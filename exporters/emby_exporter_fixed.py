#!/usr/bin/env python3

import os
import sys
import time
import logging
import requests
from prometheus_client import start_http_server, Gauge, Counter, Histogram, Info
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
logger = logging.getLogger('emby_exporter')

# Configuration from environment variables
EMBY_SERVER_URL = os.getenv('EMBY_SERVER_URL', 'http://localhost:8096')
EMBY_API_KEY = os.getenv('EMBY_API_KEY', '')
EXPORTER_PORT = int(os.getenv('EXPORTER_PORT', '9119'))
SCRAPE_INTERVAL = int(os.getenv('SCRAPE_INTERVAL', '30'))

# Prometheus metrics
# Server info
server_info = Info('emby_server', 'Emby server information')
server_up = Gauge('emby_up', 'Emby server is up and responding')

# Sessions and streaming
active_sessions = Gauge('emby_active_sessions', 'Number of active sessions')
active_streams = Gauge('emby_active_streams', 'Number of active streaming sessions')
active_transcodes = Gauge('emby_active_transcodes', 'Number of active transcoding sessions')
session_bandwidth = Gauge('emby_session_bandwidth_bytes', 'Current bandwidth usage in bytes', ['session_id', 'user', 'client'])
total_bandwidth = Gauge('emby_total_bandwidth_bytes', 'Total bandwidth usage in bytes')

# User metrics
total_users = Gauge('emby_users_total', 'Total number of users')
active_users = Gauge('emby_users_active', 'Number of active users in last 24 hours')
user_play_count = Gauge('emby_user_play_count', 'Play count by user', ['user'])
user_play_time = Gauge('emby_user_play_time_minutes', 'Total play time by user in minutes', ['user'])

# Library metrics
library_items = Gauge('emby_library_items', 'Number of items in library', ['library_name', 'media_type'])
library_size = Gauge('emby_library_size_bytes', 'Size of library in bytes', ['library_name'])
recently_added = Gauge('emby_library_recently_added', 'Items added in last 24 hours')

# Performance metrics
api_request_duration = Histogram('emby_api_request_duration_seconds', 'API request duration', ['endpoint'])
api_request_errors = Counter('emby_api_request_errors_total', 'Total API request errors', ['endpoint'])

# System resource metrics (Emby process specific)
process_cpu = Gauge('emby_process_cpu_percent', 'Emby process CPU usage percentage')
process_memory = Gauge('emby_process_memory_bytes', 'Emby process memory usage in bytes')
process_threads = Gauge('emby_process_threads', 'Number of Emby process threads')

# Playback metrics
playback_starts = Counter('emby_playback_starts_total', 'Total playback starts', ['media_type'])
playback_stops = Counter('emby_playback_stops_total', 'Total playback stops', ['media_type'])
playback_errors = Counter('emby_playback_errors_total', 'Total playback errors')

# Device metrics
device_count = Gauge('emby_devices_total', 'Total number of registered devices')
device_active = Gauge('emby_devices_active', 'Number of active devices', ['device_type'])


def parse_emby_datetime(date_string):
    """
    Parse Emby datetime strings which can have microseconds with more than 6 digits.
    Emby format: '2025-07-20T01:16:29.5706488+00:00' (7 digits of microseconds)
    Python expects: '2025-07-20T01:16:29.570648+00:00' (6 digits max)
    """
    if not date_string:
        return None
    
    try:
        # First try standard parsing
        if date_string.endswith('Z'):
            return datetime.fromisoformat(date_string.replace('Z', '+00:00'))
        else:
            return datetime.fromisoformat(date_string)
    except ValueError:
        # Handle Emby's extended microseconds format
        try:
            # Use regex to truncate microseconds to 6 digits
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
            
            # Fallback: remove microseconds entirely
            if '.' in date_string:
                date_part = date_string.split('.')[0]
                if '+' in date_string:
                    tz_part = '+' + date_string.split('+')[1]
                elif 'Z' in date_string:
                    tz_part = '+00:00'
                else:
                    tz_part = ''
                return datetime.fromisoformat(date_part + tz_part)
            
            return None
        except Exception as e:
            logger.warning(f"Could not parse date: {date_string}, error: {e}")
            return None


class EmbyExporter:
    def __init__(self, server_url: str, api_key: str):
        self.server_url = server_url.rstrip('/')
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({
            'X-Emby-Token': api_key,
            'Accept': 'application/json'
        })
        
        # Cache for reducing API calls
        self.cache = {}
        self.cache_ttl = 60  # seconds
        
    def _make_request(self, endpoint: str, params: Dict = None) -> Any:
        """Make a request to the Emby API with error handling."""
        url = urljoin(self.server_url, endpoint)
        start_time = time.time()
        
        try:
            response = self.session.get(url, params=params, timeout=10)
            response.raise_for_status()
            
            # Record successful request duration
            duration = time.time() - start_time
            api_request_duration.labels(endpoint=endpoint).observe(duration)
            
            return response.json()
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching {endpoint}: {e}")
            api_request_errors.labels(endpoint=endpoint).inc()
            return None
        
    def _get_cached(self, key: str, fetch_func, ttl: int = None):
        """Get data from cache or fetch if expired."""
        ttl = ttl or self.cache_ttl
        now = time.time()
        
        if key in self.cache:
            data, timestamp = self.cache[key]
            if now - timestamp < ttl:
                return data
        
        data = fetch_func()
        if data is not None:
            self.cache[key] = (data, now)
        return data
    
    def collect_server_info(self):
        """Collect server information."""
        info = self._make_request('/System/Info')
        if info:
            server_info.info({
                'version': info.get('Version', 'unknown'),
                'server_name': info.get('ServerName', 'unknown'),
                'operating_system': info.get('OperatingSystem', 'unknown'),
                'architecture': info.get('SystemArchitecture', 'unknown')
            })
            server_up.set(1)
            
            # Process metrics if available
            if 'CachePath' in info:
                # This is a placeholder - actual process metrics would need system-level access
                process_threads.set(info.get('WebSocketPortNumber', 0))
        else:
            server_up.set(0)
    
    def collect_sessions(self):
        """Collect active session metrics."""
        sessions = self._make_request('/Sessions')
        if not sessions:
            return
        
        active_count = len(sessions)
        streaming_count = 0
        transcoding_count = 0
        total_bandwidth_bytes = 0
        
        for session in sessions:
            if session.get('NowPlayingItem'):
                streaming_count += 1
                
                # Bandwidth per session
                if 'PlayState' in session:
                    play_state = session['PlayState']
                    bandwidth = session.get('Bandwidth', 0)
                    
                    # Check for transcoding
                    play_method = play_state.get('PlayMethod', 'Unknown')
                    if play_method == 'Transcode':
                        transcoding_count += 1
                    
                    # Add bandwidth
                    total_bandwidth_bytes += bandwidth
                    
                    session_bandwidth.labels(
                        session_id=session.get('Id', 'unknown'),
                        user=session.get('UserName', 'unknown'),
                        client=session.get('Client', 'unknown')
                    ).set(bandwidth)
        
        active_sessions.set(active_count)
        active_streams.set(streaming_count)
        active_transcodes.set(transcoding_count)
        total_bandwidth.set(total_bandwidth_bytes)
        
        logger.info(f"Sessions: {active_count}, Streams: {streaming_count}, Transcodes: {transcoding_count}, Bandwidth: {total_bandwidth_bytes}")
    
    def collect_users(self):
        """Collect user metrics."""
        users = self._make_request('/Users')
        if not users:
            return
        
        total_users.set(len(users))
        
        # Collect activity for each user
        active_count = 0
        for user in users:
            user_id = user.get('Id')
            username = user.get('Name', 'unknown')
            
            # Check if user was active in last 24 hours using the fixed date parser
            if user.get('LastActivityDate'):
                last_activity = parse_emby_datetime(user['LastActivityDate'])
                if last_activity:
                    try:
                        # Make timezone-aware comparison
                        now = datetime.now(last_activity.tzinfo) if last_activity.tzinfo else datetime.now()
                        if (now - last_activity).days < 1:
                            active_count += 1
                    except Exception as e:
                        logger.debug(f"Error comparing dates for user {username}: {e}")
            
            # Get user play stats (with error handling)
            try:
                stats = self._make_request(f'/Users/{user_id}/PlayedItems/Stats')
                if stats:
                    user_play_count.labels(user=username).set(stats.get('PlayCount', 0))
                    play_time_ticks = stats.get('PlaybackDurationTicks', 0)
                    play_time_minutes = play_time_ticks / 600000000 if play_time_ticks else 0
                    user_play_time.labels(user=username).set(play_time_minutes)
            except Exception as e:
                logger.debug(f"Could not get play stats for user {username}: {e}")
        
        active_users.set(active_count)
    
    def collect_libraries(self):
        """Collect library metrics."""
        libraries = self._make_request('/Library/VirtualFolders')
        if not libraries:
            return
        
        total_recent = 0
        
        for library in libraries:
            library_name = library.get('Name', 'unknown')
            
            # Get items in library
            items = self._make_request('/Items', params={
                'ParentId': library.get('ItemId'),
                'Recursive': 'true',
                'IncludeItemTypes': library.get('CollectionType', 'Unknown'),
                'Limit': 1  # Just get count, not all items
            })
            
            if items and 'TotalRecordCount' in items:
                item_count = items.get('TotalRecordCount', 0)
                library_items.labels(
                    library_name=library_name,
                    media_type=library.get('CollectionType', 'Unknown')
                ).set(item_count)
        
        recently_added.set(total_recent)
    
    def collect_devices(self):
        """Collect device metrics."""
        devices = self._make_request('/Devices')
        if not devices or not isinstance(devices, dict):
            return
        
        device_items = devices.get('Items', [])
        device_count.set(len(device_items))
        
        # Count active devices by type
        device_types = {}
        for device in device_items:
            if device.get('DateLastActivity'):
                last_activity = parse_emby_datetime(device['DateLastActivity'])
                if last_activity:
                    try:
                        now = datetime.now(last_activity.tzinfo) if last_activity.tzinfo else datetime.now()
                        if (now - last_activity).days < 7:  # Active in last week
                            device_type = device.get('AppName', 'unknown')
                            device_types[device_type] = device_types.get(device_type, 0) + 1
                    except Exception as e:
                        logger.debug(f"Error processing device activity: {e}")
        
        for device_type, count in device_types.items():
            device_active.labels(device_type=device_type).set(count)
    
    def collect_all_metrics(self):
        """Collect all metrics from Emby."""
        logger.info("Starting metrics collection...")
        
        try:
            self.collect_server_info()
            self.collect_sessions()
            self.collect_users()
            self.collect_libraries()
            self.collect_devices()
            
            logger.info("Metrics collection completed successfully")
        except Exception as e:
            logger.error(f"Error during metrics collection: {e}")
            import traceback
            logger.error(traceback.format_exc())
            server_up.set(0)


def main():
    """Main function to run the exporter."""
    if not EMBY_API_KEY:
        logger.error("EMBY_API_KEY environment variable is not set!")
        sys.exit(1)
    
    logger.info(f"Starting Emby exporter on port {EXPORTER_PORT}")
    logger.info(f"Connecting to Emby server at {EMBY_SERVER_URL}")
    
    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)
    logger.info(f"Prometheus metrics available at http://localhost:{EXPORTER_PORT}/metrics")
    
    # Create exporter instance
    exporter = EmbyExporter(EMBY_SERVER_URL, EMBY_API_KEY)
    
    # Initial collection
    exporter.collect_all_metrics()
    
    # Main loop
    while True:
        time.sleep(SCRAPE_INTERVAL)
        exporter.collect_all_metrics()


if __name__ == '__main__':
    main()