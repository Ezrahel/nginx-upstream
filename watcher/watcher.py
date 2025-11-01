#!/usr/bin/env python3
"""
Simple log watcher that tails nginx JSON access log lines and alerts to Slack on
- failover events (pool changes)
- elevated 5xx error rates over a sliding window

Configuration via environment variables:
- SLACK_WEBHOOK_URL
- ERROR_RATE_THRESHOLD (percentage, default 2)
- WINDOW_SIZE (default 200)
- ALERT_COOLDOWN_SEC (default 300)
- ACTIVE_POOL (initial expected pool)
- MAINTENANCE_MODE (true/false suppresses alerts)

This is intentionally lightweight and avoids external dependencies beyond requests.
"""
import os
import time
import json
import collections
import sys
from datetime import datetime

import requests

LOG_PATH = '/var/log/nginx/access.log'
SLACK_WEBHOOK = os.environ.get('SLACK_WEBHOOK_URL')
ERROR_RATE_THRESHOLD = float(os.environ.get('ERROR_RATE_THRESHOLD', '2'))
WINDOW_SIZE = int(os.environ.get('WINDOW_SIZE', '200'))
ALERT_COOLDOWN = int(os.environ.get('ALERT_COOLDOWN_SEC', '300'))
ACTIVE_POOL = os.environ.get('ACTIVE_POOL', 'blue')
MAINTENANCE_MODE = os.environ.get('MAINTENANCE_MODE', 'false').lower() in ('1','true','yes')

# state
last_pool = ACTIVE_POOL
recent = collections.deque(maxlen=WINDOW_SIZE)  # store booleans: True=5xx, False=not 5xx
last_alert = {'failover': None, 'error_rate': None}


def post_slack(text, title=None):
    """Post alert to Slack webhook"""
    if MAINTENANCE_MODE:
        print(f'[MAINTENANCE MODE] Suppressing alert: {text}')
        sys.stdout.flush()
        return
    if not SLACK_WEBHOOK:
        print(f'[NO WEBHOOK] Would alert: {text}')
        sys.stdout.flush()
        return
    
    payload = {"text": (f"*{title}*\n" if title else "") + text}
    try:
        r = requests.post(SLACK_WEBHOOK, json=payload, timeout=5)
        r.raise_for_status()
        print(f'[SLACK] Posted alert: {title}')
        sys.stdout.flush()
    except Exception as e:
        print(f'[ERROR] Failed to post Slack alert: {e}')
        sys.stdout.flush()


def send_failover_alert(old_pool, new_pool, sample_line):
    """Send failover detection alert with cooldown"""
    now = datetime.utcnow()
    if last_alert['failover']:
        elapsed = (now - last_alert['failover']).total_seconds()
        if elapsed < ALERT_COOLDOWN:
            print(f'[COOLDOWN] Failover alert suppressed ({elapsed:.0f}s < {ALERT_COOLDOWN}s)')
            sys.stdout.flush()
            return
    
    last_alert['failover'] = now
    text = (f'🔄 Pool changed from *{old_pool}* to *{new_pool}*\n'
            f'Time: {now.strftime("%Y-%m-%d %H:%M:%S")} UTC\n'
            f'```{sample_line[:500]}```')
    print(f'[ALERT] Failover: {old_pool} -> {new_pool}')
    sys.stdout.flush()
    post_slack(text, title='🚨 Failover Detected')


def send_error_rate_alert(rate, total_requests, error_count):
    """Send high error rate alert with cooldown"""
    now = datetime.utcnow()
    if last_alert['error_rate']:
        elapsed = (now - last_alert['error_rate']).total_seconds()
        if elapsed < ALERT_COOLDOWN:
            print(f'[COOLDOWN] Error-rate alert suppressed ({elapsed:.0f}s < {ALERT_COOLDOWN}s)')
            sys.stdout.flush()
            return
    
    last_alert['error_rate'] = now
    text = (f'⚠️ High upstream error rate detected\n'
            f'Error Rate: *{rate:.2f}%* ({error_count}/{total_requests} requests)\n'
            f'Threshold: {ERROR_RATE_THRESHOLD}%\n'
            f'Window: {total_requests} requests\n'
            f'Time: {now.strftime("%Y-%m-%d %H:%M:%S")} UTC')
    print(f'[ALERT] Error rate: {rate:.2f}% ({error_count}/{total_requests})')
    sys.stdout.flush()
    post_slack(text, title='🚨 High Upstream Error Rate')


def parse_log_line(line):
    """Parse nginx JSON log line and extract status, pool, and full data"""
    try:
        line = line.strip()
        if not line:
            return None, None, None
        
        data = json.loads(line)
        status = int(data.get('status', 0))
        
        # Extract pool - nginx log format uses "pool" field with $upstream_http_x_app_pool
        pool = data.get('pool', '').strip()
        
        # Handle cases where pool might be empty string or "-"
        if not pool or pool == '-':
            pool = None
        
        return status, pool, data
        
    except json.JSONDecodeError as e:
        print(f'[ERROR] JSON parse error: {e} | Line: {line[:100]}...')
        sys.stdout.flush()
        return None, None, None
    except Exception as e:
        print(f'[ERROR] Parse error: {e} | Line: {line[:100]}...')
        sys.stdout.flush()
        return None, None, None


def tail_log(path):
    """Follow a file by reading in chunks, handling rotation"""
    print(f'[TAIL] Starting tail on {path}')
    sys.stdout.flush()
    
    position = 0
    
    while True:
        try:
            if not os.path.exists(path):
                print(f'[TAIL] Waiting for {path} to be created...')
                sys.stdout.flush()
                time.sleep(1)
                continue
            
            size = os.path.getsize(path)
            
            if size > position:
                # File has grown, read new data
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    if position > 0:
                        f.seek(position)
                    new_data = f.read()
                    if new_data:
                        position = f.tell()
                        for line in new_data.splitlines():
                            if line.strip():
                                yield line.strip()
            elif size < position:
                # File was truncated or rotated, reset position
                print('[TAIL] Log file truncated/rotated, resetting position')
                sys.stdout.flush()
                position = 0
            
            time.sleep(0.1)
            
        except Exception as e:
            print(f'[ERROR] Error reading log file: {e}')
            sys.stdout.flush()
            time.sleep(1)


def monitor():
    """Main monitoring loop - tail logs and detect failovers/error rates"""
    global last_pool
    
    print('[MONITOR] Starting monitoring')
    print(f'[CONFIG] SLACK_WEBHOOK: {"configured" if SLACK_WEBHOOK else "NOT SET"}')
    print(f'[CONFIG] ERROR_RATE_THRESHOLD: {ERROR_RATE_THRESHOLD}%')
    print(f'[CONFIG] WINDOW_SIZE: {WINDOW_SIZE}')
    print(f'[CONFIG] ALERT_COOLDOWN: {ALERT_COOLDOWN}s')
    print(f'[CONFIG] INITIAL ACTIVE_POOL: {ACTIVE_POOL}')
    print(f'[CONFIG] MAINTENANCE_MODE: {MAINTENANCE_MODE}')
    sys.stdout.flush()
    
    request_count = 0
    
    for line in tail_log(LOG_PATH):
        try:
            status, pool, data = parse_log_line(line)
            
            if status is None:
                continue
            
            request_count += 1
            is_5xx = 500 <= status <= 599
            
            # Track error rate
            recent.append(is_5xx)
            
            # Log occasionally for visibility
            if request_count % 50 == 0:
                error_count = sum(recent)
                current_rate = (error_count / len(recent)) * 100 if recent else 0
                print(f'[STATS] Requests: {request_count} | Window: {len(recent)} | '
                      f'Errors: {error_count} ({current_rate:.2f}%) | Pool: {pool or "unknown"}')
                sys.stdout.flush()
            
            # Detect pool change (failover)
            if pool:
                if pool != last_pool:
                    print(f'[FAILOVER] Pool changed: {last_pool} -> {pool}')
                    sys.stdout.flush()
                    old_pool = last_pool
                    last_pool = pool
                    send_failover_alert(old_pool, pool, line)
            
            # Check error rate threshold
            if len(recent) >= max(10, WINDOW_SIZE // 4):
                error_count = sum(recent)
                rate = (error_count / len(recent)) * 100.0
                
                if rate >= ERROR_RATE_THRESHOLD:
                    send_error_rate_alert(rate, len(recent), error_count)
        
        except Exception as e:
            print(f'[ERROR] Processing log line: {e}')
            sys.stdout.flush()


if __name__ == '__main__':
    print('='*60)
    print('Log Watcher Starting')
    print(f'LOG_PATH: {LOG_PATH}')
    print('='*60)
    sys.stdout.flush()
    
    # Wait for log file to appear
    timeout = 60
    waited = 0
    while not os.path.exists(LOG_PATH) and waited < timeout:
        time.sleep(0.5)
        waited += 0.5
    
    if not os.path.exists(LOG_PATH):
        print('[FATAL] Log file not found after timeout, exiting')
        sys.stdout.flush()
        exit(1)
    
    print(f'[OK] Log file found: {LOG_PATH}')
    sys.stdout.flush()
    
    try:
        monitor()
    except KeyboardInterrupt:
        print('\n[EXIT] Watcher stopped by user')
        sys.stdout.flush()
    except Exception as e:
        print(f'[FATAL] Watcher crashed: {e}')
        sys.stdout.flush()
        raise