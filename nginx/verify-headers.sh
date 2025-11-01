#!/bin/bash
# Script to verify that applications are sending required headers

echo "=========================================="
echo "Verifying Application Headers"
echo "=========================================="
echo

# Test Blue Pool directly
echo "Testing Blue Pool (port 8081)..."
echo "---"
response=$(curl -sI http://localhost:8081/ 2>/dev/null)
pool_header=$(echo "$response" | grep -i "X-App-Pool:" | cut -d' ' -f2- | tr -d '\r')
release_header=$(echo "$response" | grep -i "X-Release-Id:" | cut -d' ' -f2- | tr -d '\r')

if [ -n "$pool_header" ]; then
    echo "✓ X-App-Pool: $pool_header"
else
    echo "✗ X-App-Pool: NOT FOUND"
fi

if [ -n "$release_header" ]; then
    echo "✓ X-Release-Id: $release_header"
else
    echo "✗ X-Release-Id: NOT FOUND"
fi
echo

# Test Green Pool directly
echo "Testing Green Pool (port 8082)..."
echo "---"
response=$(curl -sI http://localhost:8082/ 2>/dev/null)
pool_header=$(echo "$response" | grep -i "X-App-Pool:" | cut -d' ' -f2- | tr -d '\r')
release_header=$(echo "$response" | grep -i "X-Release-Id:" | cut -d' ' -f2- | tr -d '\r')

if [ -n "$pool_header" ]; then
    echo "✓ X-App-Pool: $pool_header"
else
    echo "✗ X-App-Pool: NOT FOUND"
fi

if [ -n "$release_header" ]; then
    echo "✓ X-Release-Id: $release_header"
else
    echo "✗ X-Release-Id: NOT FOUND"
fi
echo

# Test via Nginx
echo "Testing via Nginx (port 8080)..."
echo "---"
curl -s http://localhost:8080/ > /dev/null
sleep 1

# Check nginx logs for pool field
echo "Checking nginx logs for pool field..."
last_log=$(docker exec nginx-bg tail -1 /var/log/nginx/access.log 2>/dev/null)

if echo "$last_log" | grep -q '"pool":"-"'; then
    echo "✗ Pool field is '-' (headers not received by nginx)"
    echo
    echo "Your application needs to send these headers:"
    echo "  X-App-Pool: blue (or green)"
    echo "  X-Release-Id: your-release-id"
    echo
elif echo "$last_log" | grep -q '"pool":"[^-]'; then
    pool_value=$(echo "$last_log" | grep -o '"pool":"[^"]*"' | cut -d'"' -f4)
    release_value=$(echo "$last_log" | grep -o '"release":"[^"]*"' | cut -d'"' -f4)
    echo "✓ Pool detected: $pool_value"
    echo "✓ Release detected: $release_value"
    echo
    echo "✓ Headers are working correctly!"
else
    echo "⚠ Could not parse nginx log"
fi
echo

echo "Last nginx log line:"
echo "$last_log" | python3 -m json.tool 2>/dev/null || echo "$last_log"
echo

echo "=========================================="
echo "Summary"
echo "=========================================="
echo "If you see X-App-Pool: NOT FOUND above, you need to:"
echo "1. Add header middleware to your application"
echo "2. Rebuild your Docker images"
echo "3. Restart: docker compose up -d --force-recreate"
echo
echo "Example code for adding headers is in the artifacts above"