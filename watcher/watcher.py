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
import threading
from datetime import datetime, timedelta

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
lock = threading.Lock()
recent = collections.deque(maxlen=WINDOW_SIZE)  # store booleans: True=5xx, False=not 5xx
last_alert = {'failover': None, 'error_rate': None}


def post_slack(text, title=None):
    if MAINTENANCE_MODE:
        print('Maintenance mode - suppressing alert:', text)
        return
    if not SLACK_WEBHOOK:
        print('No SLACK_WEBHOOK_URL configured; would alert:', text)
        return
    payload = {"text": (f"*{title}*\n" if title else "") + text}
    try:
        r = requests.post(SLACK_WEBHOOK, json=payload, timeout=5)
        r.raise_for_status()
    except Exception as e:
        print('Failed to post Slack alert:', e)


def send_failover_alert(old_pool, new_pool, sample_line):
    now = datetime.utcnow()
    if last_alert['failover'] and (now - last_alert['failover']).total_seconds() < ALERT_COOLDOWN:
        print('Failover alert suppressed (cooldown)')
        return
    last_alert['failover'] = now
    text = f'Failover detected: {old_pool} -> {new_pool}\nSample: {sample_line}'
    print('Sending failover alert:', text)
    post_slack(text, title='Failover Detected')


def send_error_rate_alert(rate, window_lines):
    now = datetime.utcnow()
    if last_alert['error_rate'] and (now - last_alert['error_rate']).total_seconds() < ALERT_COOLDOWN:
        print('Error-rate alert suppressed (cooldown)')
        return
    last_alert['error_rate'] = now
    text = f'High upstream error rate: {rate:.2f}% over last {len(window_lines)} requests\nSample lines:\n' + '\n'.join(window_lines[-5:])
    print('Sending error-rate alert:', text)
    post_slack(text, title='High Upstream Error Rate')


def parse_log_line(line):
    import sys
    try:
        line = line.strip()
        if not line:
            return None, None, None
            
        print(f"Parsing log line: {line[:200]}")  # Debug: show the start of the line
        sys.stdout.flush()
        
        data = json.loads(line)
        status = int(data.get('status', 0))
        pool = data.get('pool') or data.get('upstream_pool') or None
        
        print(f"Parsed line - status: {status}, pool: {pool}")  # Debug output
        sys.stdout.flush()
        return status, pool, data
    except Exception as e:
        print(f"Error parsing log line: {e}, line: {line[:200]}")  # Debug: show parsing error
        sys.stdout.flush()
        return None, None, None


def tail_log(path):
    """Follow a file by reading in chunks"""
    import sys
    print(f"Starting tail_log for {path}")
    sys.stdout.flush()
    position = 0
    
    while True:
        try:
            if not os.path.exists(path):
                print(f"Waiting for {path} to be created...")
                sys.stdout.flush()
                time.sleep(1)
                continue
                
            size = os.path.getsize(path)
            if size > position:
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    if position > 0:
                        f.seek(position)
                    new_data = f.read()
                    if new_data:
                        position = f.tell()
                        print(f"Read {len(new_data)} bytes from log file")
                        sys.stdout.flush()
                        for line in new_data.splitlines():
                            yield line.strip()
            elif size < position:
                # File was truncated or rotated
                print("Log file was truncated, resetting position")
                sys.stdout.flush()
                position = 0
            time.sleep(0.1)
        except Exception as e:
            print(f"Error reading log file: {e}")
            sys.stdout.flush()
            time.sleep(1)


def monitor():
    global last_pool
    window_lines = []
    print("Starting monitor function")
    print(f"Initial configuration:")
    print(f"SLACK_WEBHOOK configured: {bool(SLACK_WEBHOOK)}")
    print(f"ERROR_RATE_THRESHOLD: {ERROR_RATE_THRESHOLD}%")
    print(f"WINDOW_SIZE: {WINDOW_SIZE}")
    print(f"ALERT_COOLDOWN: {ALERT_COOLDOWN}s")
    print(f"ACTIVE_POOL: {ACTIVE_POOL}")
    print(f"MAINTENANCE_MODE: {MAINTENANCE_MODE}")
    
    for line in tail_log(LOG_PATH):
        try:
            status, pool, data = parse_log_line(line)
            if status is None:
                print(f"Failed to parse log line: {line[:200]}...")
                continue
                
            print(f"Processed line - status: {status}, pool: {pool}")
            is_5xx = 500 <= status <= 599
            
            with lock:
                recent.append(is_5xx)
                window_lines.append(line)
                if len(window_lines) > WINDOW_SIZE:
                    window_lines = window_lines[-WINDOW_SIZE:]

                # detect pool change
                if pool and pool != last_pool:
                    old = last_pool
                    last_pool = pool
                    send_failover_alert(old, pool, line)

                # error rate
                if len(recent) >= max(10, WINDOW_SIZE//4):
                    rate = (sum(recent) / len(recent)) * 100.0
                    if rate >= ERROR_RATE_THRESHOLD:
                        send_error_rate_alert(rate, window_lines)
        except Exception as e:
            print(f"Error processing log line: {e}")


if __name__ == '__main__':
    print('Watcher starting. LOG_PATH=', LOG_PATH)
    
    # Test Slack webhook
    if SLACK_WEBHOOK:
        print("Testing Slack webhook...")
        try:
            post_slack("Alert watcher starting up", title="Watcher Test")
            print("Slack webhook test successful")
        except Exception as e:
            print(f"Warning: Slack webhook test failed: {e}")
    else:
        print("Warning: No SLACK_WEBHOOK_URL configured")
    
    # wait for log file to appear
    timeout = 60
    waited = 0
    while not os.path.exists(LOG_PATH) and waited < timeout:
        time.sleep(0.5)
        waited += 0.5
    if not os.path.exists(LOG_PATH):
        print('Log file not found, exiting')
        exit(1)
    
    try:
        monitor()
    except KeyboardInterrupt:
        print('Watcher exiting')
    except Exception as e:
        print(f'Fatal error in watcher: {e}')
