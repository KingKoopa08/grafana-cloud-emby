#!/usr/bin/env python3

"""
Enhanced Emby Exporter with Debugging for Streaming Metrics
This version includes verbose logging and better error handling
"""

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
import traceback

# Configure detailed logging
logging.basicConfig(
    level=logging.DEBUG,  # Set to DEBUG for maximum verbosity
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/var/log/emby_exporter_debug.log')
    ]
)
logger = logging.getLogger('emby_exporter_debug')

# Configuration from environment variables
EMBY_SERVER_URL = os.getenv('EMBY_SERVER_URL', 'http://localhost:8096')
EMBY_API_KEY = os.getenv('EMBY_API_KEY', '')
EXPORTER_PORT = int(os.getenv('EXPORTER_PORT', '9119'))
SCRAPE_INTERVAL = int(os.getenv('SCRAPE_INTERVAL', '30'))

# Prometheus metrics
server_info = Info('emby_server', 'Emby server information')
server_up = Gauge('emby_up', 'Emby server is up and responding')

# Sessions and streaming - with detailed labels
active_sessions = Gauge('emby_active_sessions', 'Number of active sessions')
active_streams = Gauge('emby_active_streams', 'Number of active streaming sessions')
active_transcodes = Gauge('emby_active_transcodes', 'Number of active transcoding sessions')
session_bandwidth = Gauge('emby_session_bandwidth_bytes', 'Current bandwidth usage in bytes', ['session_id', 'user', 'client', 'media_type', 'play_method'])
total_bandwidth = Gauge('emby_total_bandwidth_bytes', 'Total bandwidth usage in bytes')

# Debug metrics
debug_last_scrape = Gauge('emby_debug_last_scrape_timestamp', 'Timestamp of last successful scrape')
debug_api_calls = Counter('emby_debug_api_calls_total', 'Total API calls made', ['endpoint', 'status'])
debug_sessions_found = Gauge('emby_debug_sessions_found', 'Number of sessions found in last scrape')
debug_streams_found = Gauge('emby_debug_streams_found', 'Number of streams found in last scrape')

# User metrics
total_users = Gauge('emby_users_total', 'Total number of users')
active_users = Gauge('emby_users_active', 'Number of active users in last 24 hours')
user_play_count = Gauge('emby_user_play_count', 'Play count by user', ['user'])
user_play_time = Gauge('emby_user_play_time_minutes', 'Total play time by user in minutes', ['user'])

# Library metrics
library_items = Gauge('emby_library_items', 'Number of items in library', ['library_name', 'media_type'])
library_size = Gauge('emby_library_size_bytes', 'Size of library in bytes', ['library_name'])

# Performance metrics
api_request_duration = Histogram('emby_api_request_duration_seconds', 'API request duration', ['endpoint'])
api_request_errors = Counter('emby_api_request_errors_total', 'Total API request errors', ['endpoint'])


class EmbyExporterDebug:
    def __init__(self, server_url: str, api_key: str):
        self.server_url = server_url.rstrip('/')
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({
            'X-Emby-Token': api_key,
            'Accept': 'application/json'
        })
        
        logger.info(f"Initialized Emby Exporter Debug")
        logger.info(f"Server URL: {self.server_url}")
        logger.info(f"API Key: {api_key[:10]}..." if api_key else "No API key provided!")
        
    def _make_request(self, endpoint: str, params: Dict = None) -> Any:
        """Make a request to the Emby API with detailed error handling."""
        url = urljoin(self.server_url, endpoint)
        start_time = time.time()
        
        logger.debug(f"Making request to: {url}")
        
        try:
            response = self.session.get(url, params=params, timeout=10)
            duration = time.time() - start_time
            
            logger.debug(f"Response status: {response.status_code}")
            logger.debug(f"Response time: {duration:.2f}s")
            
            # Record metrics
            api_request_duration.labels(endpoint=endpoint).observe(duration)
            debug_api_calls.labels(endpoint=endpoint, status=str(response.status_code)).inc()
            
            response.raise_for_status()
            
            data = response.json()
            logger.debug(f"Response data type: {type(data)}, length: {len(data) if isinstance(data, list) else 'N/A'}")
            
            return data
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Request failed for {endpoint}: {str(e)}")
            logger.error(f"Full error: {traceback.format_exc()}")
            api_request_errors.labels(endpoint=endpoint).inc()
            debug_api_calls.labels(endpoint=endpoint, status='error').inc()
            return None
    
    def collect_server_info(self):
        """Collect server information."""
        logger.info("Collecting server info...")
        info = self._make_request('/System/Info')
        
        if info:
            server_info.info({
                'version': str(info.get('Version', 'unknown')),
                'server_name': str(info.get('ServerName', 'unknown')),
                'operating_system': str(info.get('OperatingSystem', 'unknown')),
                'architecture': str(info.get('SystemArchitecture', 'unknown'))
            })
            server_up.set(1)
            logger.info(f"Server info collected: {info.get('ServerName', 'unknown')} v{info.get('Version', 'unknown')}")
        else:
            server_up.set(0)
            logger.error("Failed to collect server info - server appears to be down")
    
    def collect_sessions(self):
        """Collect active session metrics with detailed debugging."""
        logger.info("=" * 60)
        logger.info("COLLECTING SESSION METRICS")
        logger.info("=" * 60)
        
        sessions = self._make_request('/Sessions')
        
        if sessions is None:
            logger.error("Failed to fetch sessions - API request returned None")
            debug_sessions_found.set(0)
            debug_streams_found.set(0)
            return
        
        # Log raw session data for debugging
        logger.debug(f"Raw sessions response: {json.dumps(sessions[:1] if sessions else [], indent=2)[:500]}...")
        
        active_count = len(sessions)
        streaming_count = 0
        transcoding_count = 0
        total_bandwidth_bytes = 0
        
        logger.info(f"Found {active_count} total session(s)")
        debug_sessions_found.set(active_count)
        
        for i, session in enumerate(sessions):
            session_id = session.get('Id', f'unknown_{i}')
            user_name = session.get('UserName', 'unknown')
            client = session.get('Client', 'unknown')
            device_name = session.get('DeviceName', 'unknown')
            
            logger.debug(f"Session {i+1}/{active_count}: User={user_name}, Client={client}, Device={device_name}")
            
            # Check if actively playing
            now_playing = session.get('NowPlayingItem')
            if now_playing:
                streaming_count += 1
                
                media_name = now_playing.get('Name', 'Unknown')
                media_type = now_playing.get('MediaType', 'Unknown')
                item_type = now_playing.get('Type', 'Unknown')
                
                logger.info(f"  ✓ STREAMING: {user_name} is watching '{media_name}' (Type: {media_type}/{item_type})")
                
                # Get play state details
                play_state = session.get('PlayState', {})
                play_method = play_state.get('PlayMethod', 'Unknown')
                is_paused = play_state.get('IsPaused', False)
                position_ticks = play_state.get('PositionTicks', 0)
                position_seconds = position_ticks / 10000000 if position_ticks else 0
                
                logger.debug(f"    Play Method: {play_method}, Paused: {is_paused}, Position: {position_seconds:.0f}s")
                
                # Check for transcoding
                if play_method == 'Transcode':
                    transcoding_count += 1
                    logger.info(f"    → Transcoding session detected")
                
                # Get bandwidth information
                bandwidth = 0
                
                # Try different bandwidth fields
                if 'Bandwidth' in session:
                    bandwidth = session['Bandwidth']
                elif 'TranscodingInfo' in session:
                    trans_info = session['TranscodingInfo']
                    bandwidth = trans_info.get('Bitrate', 0)
                    logger.debug(f"    Transcoding Info: {json.dumps(trans_info, indent=2)[:200]}...")
                
                if bandwidth > 0:
                    total_bandwidth_bytes += bandwidth
                    bandwidth_mbps = bandwidth / 1000000
                    logger.info(f"    Bandwidth: {bandwidth_mbps:.2f} Mbps ({bandwidth} bytes/s)")
                    
                    # Set bandwidth metric with labels
                    session_bandwidth.labels(
                        session_id=session_id,
                        user=user_name,
                        client=client,
                        media_type=media_type,
                        play_method=play_method
                    ).set(bandwidth)
                else:
                    logger.warning(f"    No bandwidth data available for this session")
                    # Still set the metric but with 0 bandwidth
                    session_bandwidth.labels(
                        session_id=session_id,
                        user=user_name,
                        client=client,
                        media_type=media_type,
                        play_method=play_method
                    ).set(0)
            else:
                logger.debug(f"  Session is idle (not playing anything)")
        
        # Set all metrics
        active_sessions.set(active_count)
        active_streams.set(streaming_count)
        active_transcodes.set(transcoding_count)
        total_bandwidth.set(total_bandwidth_bytes)
        debug_streams_found.set(streaming_count)
        
        logger.info("=" * 60)
        logger.info(f"SESSION METRICS SUMMARY:")
        logger.info(f"  Total Sessions: {active_count}")
        logger.info(f"  Active Streams: {streaming_count}")
        logger.info(f"  Transcoding: {transcoding_count}")
        logger.info(f"  Total Bandwidth: {total_bandwidth_bytes / 1000000:.2f} Mbps")
        logger.info("=" * 60)
    
    def collect_users(self):
        """Collect user metrics."""
        logger.info("Collecting user metrics...")
        users = self._make_request('/Users')
        
        if not users:
            logger.error("Failed to fetch users")
            return
        
        total_users.set(len(users))
        logger.info(f"Found {len(users)} total users")
        
        active_count = 0
        for user in users:
            user_id = user.get('Id')
            username = user.get('Name', 'unknown')
            
            # Check last activity
            if user.get('LastActivityDate'):
                try:
                    last_activity = datetime.fromisoformat(user['LastActivityDate'].replace('Z', '+00:00'))
                    if (datetime.now(last_activity.tzinfo) - last_activity).days < 1:
                        active_count += 1
                        logger.debug(f"User {username} was active in last 24 hours")
                except Exception as e:
                    logger.error(f"Error parsing activity date for {username}: {e}")
        
        active_users.set(active_count)
        logger.info(f"{active_count} users active in last 24 hours")
    
    def collect_all_metrics(self):
        """Collect all metrics from Emby."""
        logger.info("=" * 80)
        logger.info(f"Starting metrics collection at {datetime.now().isoformat()}")
        logger.info("=" * 80)
        
        try:
            # Update debug timestamp
            debug_last_scrape.set(time.time())
            
            # Collect all metrics
            self.collect_server_info()
            self.collect_sessions()  # This is the most important for streaming
            self.collect_users()
            
            logger.info("Metrics collection completed successfully")
            
        except Exception as e:
            logger.error(f"Critical error during metrics collection: {str(e)}")
            logger.error(f"Traceback: {traceback.format_exc()}")
            server_up.set(0)


def main():
    """Main function to run the exporter."""
    logger.info("=" * 80)
    logger.info("EMBY EXPORTER DEBUG MODE STARTING")
    logger.info("=" * 80)
    
    if not EMBY_API_KEY:
        logger.error("EMBY_API_KEY environment variable is not set!")
        sys.exit(1)
    
    logger.info(f"Configuration:")
    logger.info(f"  Server URL: {EMBY_SERVER_URL}")
    logger.info(f"  Exporter Port: {EXPORTER_PORT}")
    logger.info(f"  Scrape Interval: {SCRAPE_INTERVAL}s")
    logger.info(f"  API Key: {EMBY_API_KEY[:10]}..." if EMBY_API_KEY else "NOT SET")
    
    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)
    logger.info(f"Prometheus metrics available at http://localhost:{EXPORTER_PORT}/metrics")
    
    # Create exporter instance
    exporter = EmbyExporterDebug(EMBY_SERVER_URL, EMBY_API_KEY)
    
    # Initial collection
    exporter.collect_all_metrics()
    
    # Main loop
    while True:
        time.sleep(SCRAPE_INTERVAL)
        logger.info(f"\n{'=' * 40} SCRAPE CYCLE {'=' * 40}")
        exporter.collect_all_metrics()


if __name__ == '__main__':
    main()