#!/bin/bash
# Test script for blue/green deployment alert system
# Usage: ./test-alerts.sh [test_name]
# Available tests: all, failover, error-rate, maintenance

set -e

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

log_info() {
    echo -e "${COLOR_BLUE}ℹ ${1}${COLOR_RESET}"
}

log_success() {
    echo -e "${COLOR_GREEN}✓ ${1}${COLOR_RESET}"
}

log_warning() {
    echo -e "${COLOR_YELLOW}⚠ ${1}${COLOR_RESET}"
}

log_error() {
    echo -e "${COLOR_RED}✗ ${1}${COLOR_RESET}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker not found. Please install Docker."
        exit 1
    fi
    
    if ! command -v docker compose &> /dev/null; then
        log_error "Docker Compose not found. Please install Docker Compose."
        exit 1
    fi
    
    if ! docker compose ps | grep -q "nginx-bg"; then
        log_error "Services not running. Please start with: docker compose up -d"
        exit 1
    fi
    
    log_success "Prerequisites OK"
}

get_active_pool() {
    # Get current active pool from last log entry
    docker exec nginx-bg tail -1 /var/log/nginx/access.log 2>/dev/null | \
        grep -o '"pool":"[^"]*"' | cut -d'"' -f4 || echo "unknown"
}

wait_for_logs() {
    log_info "Waiting for log activity..."
    local count=0
    while [ $count -lt 10 ]; do
        if docker exec nginx-bg test -f /var/log/nginx/access.log; then
            local size=$(docker exec nginx-bg wc -l < /var/log/nginx/access.log)
            if [ "$size" -gt 0 ]; then
                log_success "Logs are active ($size lines)"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    log_warning "No log activity detected yet"
    return 1
}

test_basic_connectivity() {
    log_info "Testing basic connectivity..."
    
    local response=$(curl -s -w "%{http_code}" -o /dev/null http://localhost:8080/)
    if [ "$response" = "200" ]; then
        log_success "Nginx responding (HTTP $response)"
    else
        log_error "Nginx not responding correctly (HTTP $response)"
        return 1
    fi
    
    # Generate some traffic
    log_info "Generating baseline traffic..."
    for i in {1..10}; do
        curl -s http://localhost:8080/ > /dev/null
        sleep 0.1
    done
    
    log_success "Baseline traffic generated"
}

test_failover() {
    log_info "=========================================="
    log_info "TEST: Failover Detection"
    log_info "=========================================="
    
    # Determine active pool
    local active_pool=$(get_active_pool)
    log_info "Current active pool: $active_pool"
    
    if [ "$active_pool" = "unknown" ]; then
        log_warning "Cannot determine active pool, assuming blue"
        active_pool="blue"
    fi
    
    local container_name="app_${active_pool}"
    local backup_pool=$( [ "$active_pool" = "blue" ] && echo "green" || echo "blue" )
    
    log_info "Will stop: $container_name (backup: app_$backup_pool)"
    log_warning "This will trigger a failover alert in Slack"
    
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Test cancelled"
        return 0
    fi
    
    # Stop active pool
    log_info "Stopping $container_name..."
    docker stop $container_name
    
    sleep 2
    
    # Generate traffic to trigger failover
    log_info "Generating traffic (will failover to $backup_pool)..."
    for i in {1..20}; do
        response=$(curl -s -w "%{http_code}" -o /dev/null http://localhost:8080/)
        [ "$response" = "200" ] && echo -n "." || echo -n "!"
        sleep 0.2
    done
    echo
    
    # Check logs for failover
    sleep 2
    log_info "Checking for failover alert..."
    if docker logs alert_watcher --tail 50 | grep -q "FAILOVER"; then
        log_success "Failover detected in watcher logs"
    else
        log_warning "Failover not yet detected (may need more time)"
    fi
    
    # Show current pool
    local new_pool=$(get_active_pool)
    log_info "Current pool after failover: $new_pool"
    
    # Restart stopped pool
    log_info "Restarting $container_name..."
    docker start $container_name
    sleep 3
    
    log_success "Test complete"
    log_warning "Check Slack for '🚨 Failover Detected' alert"
    echo
}

test_error_rate() {
    log_info "=========================================="
    log_info "TEST: High Error Rate Detection"
    log_info "=========================================="
    
    local active_pool=$(get_active_pool)
    [ "$active_pool" = "unknown" ] && active_pool="blue"
    local container_name="app_${active_pool}"
    
    log_warning "This will generate 5xx errors to trigger error rate alert"
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Test cancelled"
        return 0
    fi
    
    # Generate traffic that will cause errors
    log_info "Generating error traffic pattern..."
    log_info "Strategy: Stop/start pool rapidly to cause timeouts"
    
    # Start generating traffic in background
    (
        for i in {1..150}; do
            curl -s -m 2 http://localhost:8080/ > /dev/null 2>&1 || true
            sleep 0.1
        done
    ) &
    local traffic_pid=$!
    
    sleep 1
    
    # Cause errors by stopping pool briefly
    docker stop $container_name
    sleep 3
    docker start $container_name
    
    # Wait for traffic generation to complete
    wait $traffic_pid
    
    sleep 3
    
    # Check for error rate alert
    log_info "Checking for error rate alert..."
    if docker logs alert_watcher --tail 50 | grep -q "Error rate"; then
        log_success "Error rate alert detected in logs"
    else
        log_warning "Error rate alert not detected (threshold may not be reached)"
    fi
    
    # Show recent error stats
    log_info "Recent statistics from watcher:"
    docker logs alert_watcher --tail 20 | grep -E "(STATS|Error rate)" || log_warning "No stats available yet"
    
    log_success "Test complete"
    log_warning "Check Slack for '🚨 High Upstream Error Rate' alert"
    echo
}

test_maintenance_mode() {
    log_info "=========================================="
    log_info "TEST: Maintenance Mode"
    log_info "=========================================="
    
    log_info "Enabling maintenance mode..."
    docker exec alert_watcher sh -c 'export MAINTENANCE_MODE=true'
    
    # Restart watcher with maintenance mode
    log_info "Note: Maintenance mode should be set in .env file"
    log_warning "Alerts will be suppressed in maintenance mode"
    
    # Show current env
    log_info "Current MAINTENANCE_MODE setting:"
    docker exec alert_watcher env | grep MAINTENANCE_MODE || log_info "Not set"
    
    log_info "To enable maintenance mode:"
    echo "  1. Add to .env: MAINTENANCE_MODE=true"
    echo "  2. Restart watcher: docker compose restart alert_watcher"
    echo "  3. Perform maintenance tasks"
    echo "  4. Set MAINTENANCE_MODE=false and restart again"
    echo
}

show_logs() {
    log_info "=========================================="
    log_info "Recent Logs"
    log_info "=========================================="
    
    log_info "Nginx access logs (last 5):"
    docker exec nginx-bg tail -5 /var/log/nginx/access.log | while read line; do
        echo "$line" | python3 -m json.tool 2>/dev/null || echo "$line"
    done
    echo
    
    log_info "Alert watcher logs (last 20):"
    docker logs alert_watcher --tail 20
    echo
}

show_status() {
    log_info "=========================================="
    log_info "System Status"
    log_info "=========================================="
    
    log_info "Container status:"
    docker compose ps
    echo
    
    log_info "Current configuration:"
    docker exec alert_watcher env | grep -E "(ACTIVE_POOL|ERROR_RATE|WINDOW_SIZE|COOLDOWN|MAINTENANCE)" || true
    echo
    
    local active_pool=$(get_active_pool)
    log_info "Currently serving from pool: $active_pool"
    echo
    
    log_info "Recent request count:"
    docker exec nginx-bg wc -l /var/log/nginx/access.log || log_warning "No logs yet"
    echo
}

show_help() {
    cat << EOF
Blue/Green Deployment Alert System - Test Script

Usage: $0 [command]

Commands:
    all             Run all tests (interactive)
    status          Show system status
    connectivity    Test basic connectivity
    failover        Test failover detection and alert
    error-rate      Test error rate detection and alert
    maintenance     Show maintenance mode info
    logs            Show recent logs
    help            Show this help message

Examples:
    $0 status           # Check system status
    $0 failover         # Test failover alert (interactive)
    $0 logs             # View recent logs

Note: Some tests require confirmation as they will disrupt service temporarily.
EOF
}

# Main script
main() {
    local test_name="${1:-help}"
    
    case "$test_name" in
        all)
            check_prerequisites
            test_basic_connectivity
            echo
            test_failover
            echo
            test_error_rate
            echo
            show_logs
            ;;
        status)
            check_prerequisites
            show_status
            ;;
        connectivity)
            check_prerequisites
            test_basic_connectivity
            ;;
        failover)
            check_prerequisites
            test_basic_connectivity
            test_failover
            ;;
        error-rate)
            check_prerequisites
            test_basic_connectivity
            test_error_rate
            ;;
        maintenance)
            test_maintenance_mode
            ;;
        logs)
            show_logs
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $test_name"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"