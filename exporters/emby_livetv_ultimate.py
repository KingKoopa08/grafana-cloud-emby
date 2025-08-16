#!/usr/bin/env python3

"""
Ultimate Emby Live TV Exporter for Prometheus
Advanced metrics collection for the most comprehensive Live TV monitoring
"""

import os
import sys
import time
import logging
import requests
from prometheus_client import start_http_server, Gauge, Counter, Info, Histogram, Summary
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional
import json
from urllib.parse import urljoin
import re
from collections import defaultdict, deque
import threading
import hashlib

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('emby_livetv_ultimate')

# Configuration from environment variables
EMBY_SERVER_URL = os.getenv('EMBY_SERVER_URL', 'http://localhost:8096')
EMBY_API_KEY = os.getenv('EMBY_API_KEY', '')
EXPORTER_PORT = int(os.getenv('EXPORTER_PORT', '9119'))
SCRAPE_INTERVAL = int(os.getenv('SCRAPE_INTERVAL', '30'))

# ============================================================================
# PROMETHEUS METRICS DEFINITIONS
# ============================================================================

# Server & Health Metrics
server_info = Info('emby_server', 'Emby server information')
server_up = Gauge('emby_up', 'Emby server is up and responding')
livetv_enabled = Gauge('emby_livetv_enabled', 'Live TV feature is enabled')
api_response_time = Summary('emby_api_response_time_seconds', 'API response time', ['endpoint'])

# Channel Metrics
channels_total = Gauge('emby_livetv_channels_total', 'Total number of Live TV channels')
channels_by_type = Gauge('emby_livetv_channels_by_type', 'Channels by type', ['channel_type'])
channels_hd = Gauge('emby_livetv_channels_hd', 'Number of HD channels')
channels_available = Gauge('emby_livetv_channels_available', 'Number of available channels')
channel_status = Gauge('emby_livetv_channel_status', 'Channel availability (1=available, 0=unavailable)', 
                      ['channel_name', 'channel_number', 'channel_id'])
channel_favorites = Gauge('emby_livetv_channel_favorites', 'Favorite channels count')

# Stream Metrics
streams_active = Gauge('emby_livetv_streams_active', 'Number of active Live TV streams')
streams_by_channel = Gauge('emby_livetv_streams_by_channel', 'Active streams per channel', 
                          ['channel_name', 'channel_number'])
streams_by_quality = Gauge('emby_livetv_streams_by_quality', 'Streams by quality', ['quality'])
streams_by_method = Gauge('emby_livetv_streams_by_method', 'Streams by method', ['method'])
stream_bitrate = Gauge('emby_livetv_stream_bitrate_kbps', 'Stream bitrate in kbps', 
                      ['user', 'channel_name', 'session_id'])
stream_bandwidth_total = Gauge('emby_livetv_bandwidth_total_mbps', 'Total Live TV bandwidth in Mbps')

# User Metrics
users_watching = Gauge('emby_livetv_users_watching', 'Number of users watching Live TV')
user_watch_time = Counter('emby_livetv_user_watch_time_seconds_total', 'Total watch time per user', 
                          ['user', 'channel_name'])
user_channel_switches = Counter('emby_livetv_channel_switches_total', 'Channel switch count', ['user'])
concurrent_streams_per_user = Gauge('emby_livetv_concurrent_streams', 'Concurrent streams per user', ['user'])
popular_channels = Gauge('emby_livetv_channel_popularity', 'Channel popularity score', 
                        ['channel_name', 'channel_number'])

# Tuner Metrics
tuners_total = Gauge('emby_livetv_tuners_total', 'Total number of tuners')
tuners_available = Gauge('emby_livetv_tuners_available', 'Number of available tuners')
tuners_in_use = Gauge('emby_livetv_tuners_in_use', 'Number of tuners in use')
tuner_utilization = Gauge('emby_livetv_tuner_utilization_percent', 'Tuner utilization percentage')
tuner_status = Gauge('emby_livetv_tuner_status', 'Tuner status (1=in use, 0=free)', 
                    ['tuner_id', 'tuner_name', 'tuner_type', 'channel'])

# Recording/DVR Metrics
recordings_active = Gauge('emby_livetv_recordings_active', 'Number of active recordings')
recordings_scheduled = Gauge('emby_livetv_recordings_scheduled', 'Number of scheduled recordings')
recordings_failed = Counter('emby_livetv_recordings_failed_total', 'Total failed recordings')
recording_storage_gb = Gauge('emby_livetv_recording_storage_gb', 'Recording storage used in GB')
recording_series = Gauge('emby_livetv_recording_series', 'Number of series recordings scheduled')
recording_conflicts = Gauge('emby_livetv_recording_conflicts', 'Number of recording conflicts')

# EPG/Program Metrics
epg_days_available = Gauge('emby_livetv_epg_days', 'Days of EPG data available')
epg_programs_today = Gauge('emby_livetv_epg_programs_today', 'Number of programs today')
epg_programs_by_genre = Gauge('emby_livetv_programs_by_genre', 'Programs by genre', ['genre'])
current_programs = Info('emby_livetv_current_programs', 'Currently airing programs')
upcoming_programs = Gauge('emby_livetv_upcoming_programs', 'Upcoming programs in next hour')
program_duration_avg = Gauge('emby_livetv_program_duration_avg_minutes', 'Average program duration')

# Quality & Performance Metrics
stream_resolution = Gauge('emby_livetv_stream_resolution', 'Stream resolution height', 
                         ['user', 'channel_name', 'session_id'])
stream_framerate = Gauge('emby_livetv_stream_framerate', 'Stream framerate', 
                        ['user', 'channel_name', 'session_id'])
transcoding_active = Gauge('emby_livetv_transcoding_active', 'Number of active transcoding sessions')
transcoding_cpu = Gauge('emby_livetv_transcoding_cpu_percent', 'CPU usage for transcoding')
buffer_health = Gauge('emby_livetv_buffer_health_percent', 'Stream buffer health', 
                     ['user', 'session_id'])
stream_errors = Counter('emby_livetv_stream_errors_total', 'Total stream errors', ['error_type'])

# Time-based Metrics
peak_concurrent_streams = Gauge('emby_livetv_peak_concurrent_streams', 'Peak concurrent streams (24h)')
hourly_active_users = Gauge('emby_livetv_hourly_active_users', 'Active users by hour', ['hour'])
prime_time_usage = Gauge('emby_livetv_prime_time_usage', 'Prime time usage percentage')

# Channel Switch Metrics
channel_switch_time = Histogram('emby_livetv_channel_switch_seconds', 'Time to switch channels', 
                               buckets=[0.5, 1, 2, 3, 5, 10, 30])
channel_load_time = Histogram('emby_livetv_channel_load_seconds', 'Time to load channel stream',
                             buckets=[0.5, 1, 2, 3, 5, 10, 30])

# Network Metrics
network_latency = Gauge('emby_livetv_network_latency_ms', 'Network latency to clients', ['client_ip'])
packet_loss = Gauge('emby_livetv_packet_loss_percent', 'Packet loss percentage', ['client_ip'])


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


class EmbyLiveTVUltimateExporter:
    def __init__(self, server_url: str, api_key: str):
        self.server_url = server_url.rstrip('/')
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({
            'X-Emby-Token': api_key,
            'Accept': 'application/json'
        })
        
        # State tracking
        self.channel_watch_start = {}  # session_id -> (user, channel, start_time)
        self.user_channel_history = defaultdict(list)  # user -> [(channel, timestamp)]
        self.stream_quality_history = defaultdict(lambda: deque(maxlen=100))  # session_id -> quality samples
        self.peak_streams_24h = 0
        self.hourly_users = defaultdict(set)  # hour -> set of users
        self.channel_popularity_scores = defaultdict(float)
        self.last_channel_switch = {}  # user -> (last_channel, timestamp)
        
        # Cache
        self.cache = {}
        self.cache_ttl = 60
        
        logger.info(f"Ultimate Live TV Exporter initialized - Server: {self.server_url}")
        
    def _make_request(self, endpoint: str, params: Dict = None) -> Any:
        """Make a request to the Emby API with performance tracking."""
        url = urljoin(self.server_url, endpoint)
        start_time = time.time()
        
        try:
            response = self.session.get(url, params=params, timeout=10)
            duration = time.time() - start_time
            api_response_time.labels(endpoint=endpoint).observe(duration)
            
            if response.status_code == 404:
                logger.debug(f"Endpoint not found: {endpoint}")
                return None
                
            response.raise_for_status()
            return response.json()
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching {endpoint}: {e}")
            stream_errors.labels(error_type='api_error').inc()
            return None
    
    def collect_server_info(self):
        """Collect server information and Live TV status."""
        info = self._make_request('/System/Info')
        if info:
            server_info.info({
                'version': str(info.get('Version', 'unknown')),
                'server_name': str(info.get('ServerName', 'unknown')),
                'operating_system': str(info.get('OperatingSystem', 'unknown')),
                'has_livetv': str(info.get('HasLiveTv', False)),
                'id': str(info.get('Id', 'unknown'))
            })
            server_up.set(1)
            livetv_enabled.set(1 if info.get('HasLiveTv', False) else 0)
            
            logger.info(f"Server: {info.get('ServerName')} v{info.get('Version')}, LiveTV: {info.get('HasLiveTv')}")
        else:
            server_up.set(0)
            livetv_enabled.set(0)
    
    def collect_channels(self):
        """Collect comprehensive channel metrics."""
        channels = self._make_request('/LiveTv/Channels')
        
        if not channels or 'Items' not in channels:
            channels_total.set(0)
            return
            
        channel_items = channels.get('Items', [])
        total = channels.get('TotalRecordCount', 0)
        channels_total.set(total)
        
        # Analyze channels
        hd_count = 0
        available_count = 0
        favorite_count = 0
        channel_types = defaultdict(int)
        
        for channel in channel_items:
            channel_id = channel.get('Id', 'unknown')
            channel_name = channel.get('Name', 'Unknown')
            channel_number = channel.get('ChannelNumber', channel.get('Number', 'N/A'))
            
            # Check if HD (look for HD in name or check video properties)
            if 'HD' in channel_name.upper() or channel.get('IsHD', False):
                hd_count += 1
            
            # Check availability
            is_available = 1 if channel.get('Id') and not channel.get('IsDisabled', False) else 0
            if is_available:
                available_count += 1
                
            channel_status.labels(
                channel_name=channel_name,
                channel_number=channel_number,
                channel_id=channel_id
            ).set(is_available)
            
            # Check if favorite
            if channel.get('UserData', {}).get('IsFavorite', False):
                favorite_count += 1
            
            # Channel type
            channel_type = channel.get('Type', 'Unknown')
            channel_types[channel_type] += 1
        
        # Set metrics
        channels_hd.set(hd_count)
        channels_available.set(available_count)
        channel_favorites.set(favorite_count)
        
        for ch_type, count in channel_types.items():
            channels_by_type.labels(channel_type=ch_type).set(count)
        
        logger.info(f"Channels: {total} total, {available_count} available, {hd_count} HD")
    
    def collect_sessions(self):
        """Collect detailed Live TV session metrics."""
        sessions = self._make_request('/Sessions')
        if not sessions:
            return
        
        current_hour = datetime.now().hour
        livetv_stream_count = 0
        users_watching_set = set()
        channel_viewers = defaultdict(int)
        quality_counts = defaultdict(int)
        method_counts = defaultdict(int)
        total_bandwidth_mbps = 0
        transcoding_count = 0
        user_streams = defaultdict(int)
        
        for session in sessions:
            now_playing = session.get('NowPlayingItem', {})
            
            # Check if this is Live TV
            if now_playing and now_playing.get('Type') == 'TvChannel':
                livetv_stream_count += 1
                
                # Extract session details
                session_id = session.get('Id', 'unknown')
                user = session.get('UserName', 'unknown')
                client = session.get('Client', 'unknown')
                device = session.get('DeviceName', 'unknown')
                channel_name = now_playing.get('Name', 'Unknown Channel')
                channel_number = now_playing.get('ChannelNumber', 'N/A')
                channel_id = now_playing.get('Id', 'unknown')
                
                users_watching_set.add(user)
                self.hourly_users[current_hour].add(user)
                channel_viewers[f"{channel_name}|{channel_number}"] += 1
                user_streams[user] += 1
                
                # Update channel popularity
                self.channel_popularity_scores[channel_name] += 1
                
                # Track channel switches
                if user in self.last_channel_switch:
                    last_channel, _ = self.last_channel_switch[user]
                    if last_channel != channel_name:
                        user_channel_switches.labels(user=user).inc()
                self.last_channel_switch[user] = (channel_name, time.time())
                
                # Track watch time
                if session_id not in self.channel_watch_start:
                    self.channel_watch_start[session_id] = (user, channel_name, time.time())
                else:
                    old_user, old_channel, start_time = self.channel_watch_start[session_id]
                    if old_channel == channel_name:
                        watch_duration = time.time() - start_time
                        user_watch_time.labels(user=user, channel_name=channel_name).inc(watch_duration)
                
                # Get current program info
                current_program = now_playing.get('CurrentProgram', {})
                if current_program:
                    program_info = {
                        'channel': channel_name,
                        'program': str(current_program.get('Name', 'Unknown')),
                        'genre': str(current_program.get('Genres', ['Unknown'])[0] if current_program.get('Genres') else 'Unknown'),
                        'start': str(current_program.get('StartDate', '')),
                        'end': str(current_program.get('EndDate', ''))
                    }
                    current_programs.info(program_info)
                
                # Stream quality and method metrics
                play_state = session.get('PlayState', {})
                play_method = play_state.get('PlayMethod', 'Unknown')
                method_counts[play_method] += 1
                
                if play_method == 'Transcode':
                    transcoding_count += 1
                
                # Get quality metrics from TranscodingInfo
                if 'TranscodingInfo' in session:
                    trans_info = session['TranscodingInfo']
                    
                    # Bitrate
                    bitrate = trans_info.get('Bitrate', 0)
                    if bitrate > 0:
                        bitrate_kbps = bitrate / 1000
                        stream_bitrate.labels(
                            user=user,
                            channel_name=channel_name,
                            session_id=session_id
                        ).set(bitrate_kbps)
                        total_bandwidth_mbps += bitrate / 1000000
                    
                    # Resolution
                    height = trans_info.get('Height', 0)
                    if height > 0:
                        stream_resolution.labels(
                            user=user,
                            channel_name=channel_name,
                            session_id=session_id
                        ).set(height)
                        
                        # Classify quality
                        if height >= 2160:
                            quality_counts['4K'] += 1
                        elif height >= 1080:
                            quality_counts['1080p'] += 1
                        elif height >= 720:
                            quality_counts['720p'] += 1
                        elif height >= 480:
                            quality_counts['480p'] += 1
                        else:
                            quality_counts['SD'] += 1
                    
                    # Framerate
                    framerate = trans_info.get('Framerate', 0)
                    if framerate > 0:
                        stream_framerate.labels(
                            user=user,
                            channel_name=channel_name,
                            session_id=session_id
                        ).set(framerate)
                
                # Buffer health (simulated based on play state)
                if not play_state.get('IsPaused', False):
                    buffer_health.labels(user=user, session_id=session_id).set(95)  # Healthy buffer
                
                logger.debug(f"LiveTV: {user} watching '{channel_name}' via {play_method}")
        
        # Set all metrics
        streams_active.set(livetv_stream_count)
        users_watching.set(len(users_watching_set))
        stream_bandwidth_total.set(total_bandwidth_mbps)
        transcoding_active.set(transcoding_count)
        
        # Update peak concurrent streams
        if livetv_stream_count > self.peak_streams_24h:
            self.peak_streams_24h = livetv_stream_count
        peak_concurrent_streams.set(self.peak_streams_24h)
        
        # Set channel viewer counts
        for channel_key, count in channel_viewers.items():
            channel_name, channel_number = channel_key.split('|')
            streams_by_channel.labels(
                channel_name=channel_name,
                channel_number=channel_number
            ).set(count)
        
        # Set quality distribution
        for quality, count in quality_counts.items():
            streams_by_quality.labels(quality=quality).set(count)
        
        # Set streaming method distribution
        for method, count in method_counts.items():
            streams_by_method.labels(method=method).set(count)
        
        # Set concurrent streams per user
        for user, count in user_streams.items():
            concurrent_streams_per_user.labels(user=user).set(count)
        
        # Calculate and set channel popularity
        max_popularity = max(self.channel_popularity_scores.values()) if self.channel_popularity_scores else 1
        for channel, score in self.channel_popularity_scores.items():
            normalized_score = (score / max_popularity) * 100
            popular_channels.labels(
                channel_name=channel,
                channel_number='N/A'  # Would need to track this separately
            ).set(normalized_score)
        
        # Set hourly active users
        for hour in range(24):
            hourly_active_users.labels(hour=str(hour)).set(len(self.hourly_users.get(hour, set())))
        
        # Calculate prime time usage (6 PM - 11 PM)
        prime_time_users = set()
        for hour in range(18, 23):
            prime_time_users.update(self.hourly_users.get(hour, set()))
        
        if users_watching_set:
            prime_time_percentage = (len(prime_time_users) / len(users_watching_set)) * 100
            prime_time_usage.set(prime_time_percentage)
        
        logger.info(f"Live TV: {livetv_stream_count} streams, {len(users_watching_set)} users, {total_bandwidth_mbps:.2f} Mbps")
    
    def collect_tuners(self):
        """Collect tuner metrics."""
        tuners = self._make_request('/LiveTv/Tuners')
        
        if not tuners or not isinstance(tuners, list):
            tuners_total.set(0)
            tuners_available.set(0)
            tuners_in_use.set(0)
            tuner_utilization.set(0)
            return
        
        total_tuners = len(tuners)
        in_use_count = 0
        available_count = 0
        
        for tuner in tuners:
            tuner_id = tuner.get('Id', 'unknown')
            tuner_name = tuner.get('Name', 'Unknown Tuner')
            tuner_type = tuner.get('Type', 'Unknown')
            
            # Check if tuner is in use
            channel_id = tuner.get('ChannelId')
            status = tuner.get('Status')
            is_in_use = 1 if (channel_id or status == 'LiveTv') else 0
            
            if is_in_use:
                in_use_count += 1
                channel_name = tuner.get('ChannelName', 'Unknown')
            else:
                available_count += 1
                channel_name = 'None'
            
            tuner_status.labels(
                tuner_id=tuner_id,
                tuner_name=tuner_name,
                tuner_type=tuner_type,
                channel=channel_name
            ).set(is_in_use)
        
        tuners_total.set(total_tuners)
        tuners_available.set(available_count)
        tuners_in_use.set(in_use_count)
        
        # Calculate utilization percentage
        if total_tuners > 0:
            utilization = (in_use_count / total_tuners) * 100
            tuner_utilization.set(utilization)
        else:
            tuner_utilization.set(0)
        
        logger.info(f"Tuners: {in_use_count}/{total_tuners} in use ({utilization:.1f}% utilization)")
    
    def collect_recordings(self):
        """Collect comprehensive recording/DVR metrics."""
        # Active recordings
        active = self._make_request('/LiveTv/Recordings', params={'IsInProgress': True})
        if active and 'Items' in active:
            recordings_active.set(active.get('TotalRecordCount', 0))
        
        # Scheduled recordings/timers
        timers = self._make_request('/LiveTv/Timers')
        if timers and 'Items' in timers:
            scheduled_count = timers.get('TotalRecordCount', 0)
            recordings_scheduled.set(scheduled_count)
            
            # Count series recordings
            series_count = sum(1 for timer in timers.get('Items', []) 
                             if timer.get('SeriesTimerId'))
            recording_series.set(series_count)
        
        # All recordings (for storage calculation)
        all_recordings = self._make_request('/LiveTv/Recordings')
        if all_recordings and 'Items' in all_recordings:
            total_size_bytes = sum(item.get('Size', 0) for item in all_recordings.get('Items', []))
            total_size_gb = total_size_bytes / (1024 * 1024 * 1024)
            recording_storage_gb.set(total_size_gb)
            
            logger.info(f"Recordings: {active.get('TotalRecordCount', 0)} active, "
                       f"{scheduled_count} scheduled, {total_size_gb:.2f} GB storage")
    
    def collect_epg(self):
        """Collect EPG/Program Guide metrics."""
        now = datetime.now()
        today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        today_end = now.replace(hour=23, minute=59, second=59, microsecond=999999)
        tomorrow = today_start + timedelta(days=1)
        
        # Get today's programs
        today_programs = self._make_request('/LiveTv/Programs', params={
            'MinStartDate': today_start.isoformat(),
            'MaxStartDate': today_end.isoformat(),
            'Limit': 1000
        })
        
        if today_programs and 'Items' in today_programs:
            epg_programs_today.set(today_programs.get('TotalRecordCount', 0))
            
            # Analyze programs by genre
            genre_counts = defaultdict(int)
            total_duration = 0
            program_count = 0
            
            for program in today_programs.get('Items', []):
                # Count by genre
                genres = program.get('Genres', ['Unknown'])
                for genre in genres:
                    genre_counts[genre] += 1
                
                # Calculate duration
                start = parse_emby_datetime(program.get('StartDate'))
                end = parse_emby_datetime(program.get('EndDate'))
                if start and end:
                    duration = (end - start).total_seconds() / 60  # minutes
                    total_duration += duration
                    program_count += 1
            
            # Set genre metrics
            for genre, count in genre_counts.items():
                epg_programs_by_genre.labels(genre=genre).set(count)
            
            # Set average duration
            if program_count > 0:
                program_duration_avg.set(total_duration / program_count)
        
        # Get upcoming programs (next hour)
        upcoming = self._make_request('/LiveTv/Programs', params={
            'MinStartDate': now.isoformat(),
            'MaxStartDate': (now + timedelta(hours=1)).isoformat(),
            'Limit': 100
        })
        
        if upcoming:
            upcoming_programs.set(upcoming.get('TotalRecordCount', 0))
        
        # Calculate EPG days available (check how far ahead we have data)
        max_days = 14  # Check up to 14 days ahead
        for days in range(1, max_days + 1):
            future_date = today_start + timedelta(days=days)
            future_programs = self._make_request('/LiveTv/Programs', params={
                'MinStartDate': future_date.isoformat(),
                'MaxStartDate': (future_date + timedelta(hours=1)).isoformat(),
                'Limit': 1
            })
            
            if not future_programs or future_programs.get('TotalRecordCount', 0) == 0:
                epg_days_available.set(days - 1)
                break
        else:
            epg_days_available.set(max_days)
        
        logger.info(f"EPG: {today_programs.get('TotalRecordCount', 0)} programs today, "
                   f"{upcoming.get('TotalRecordCount', 0)} upcoming")
    
    def collect_all_metrics(self):
        """Collect all Live TV metrics."""
        logger.info("=" * 60)
        logger.info("Starting Ultimate Live TV metrics collection...")
        
        try:
            self.collect_server_info()
            self.collect_channels()
            self.collect_sessions()
            self.collect_tuners()
            self.collect_recordings()
            self.collect_epg()
            
            logger.info("Ultimate Live TV metrics collection completed")
            
        except Exception as e:
            logger.error(f"Error during metrics collection: {e}")
            import traceback
            logger.error(traceback.format_exc())
            server_up.set(0)
            stream_errors.labels(error_type='collection_error').inc()


def main():
    """Main function to run the Ultimate Live TV exporter."""
    if not EMBY_API_KEY:
        logger.error("EMBY_API_KEY environment variable is not set!")
        sys.exit(1)
    
    logger.info("=" * 60)
    logger.info("EMBY ULTIMATE LIVE TV EXPORTER STARTING")
    logger.info("=" * 60)
    logger.info(f"Server URL: {EMBY_SERVER_URL}")
    logger.info(f"Exporter Port: {EXPORTER_PORT}")
    logger.info(f"Scrape Interval: {SCRAPE_INTERVAL}s")
    
    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)
    logger.info(f"Prometheus metrics available at http://localhost:{EXPORTER_PORT}/metrics")
    
    # Create exporter instance
    exporter = EmbyLiveTVUltimateExporter(EMBY_SERVER_URL, EMBY_API_KEY)
    
    # Initial collection
    exporter.collect_all_metrics()
    
    # Main loop
    while True:
        time.sleep(SCRAPE_INTERVAL)
        exporter.collect_all_metrics()


if __name__ == '__main__':
    main()