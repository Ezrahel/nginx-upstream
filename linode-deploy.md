# Linode Deployment Guide

## Prerequisites

1. A Linode Ubuntu server (Ubuntu 20.04 LTS or newer)
2. Domain name pointed to your Linode server (optional)
3. SSH access to your server

## Server Setup

1. SSH into your Linode server:
```bash
ssh root@<your-server-ip>
```

2. Update system packages:
```bash
apt update && apt upgrade -y
```

3. Install required packages:
```bash
apt install -y docker.io docker-compose git
```

4. Start and enable Docker:
```bash
systemctl start docker
systemctl enable docker
```

5. Add your user to the docker group (if not using root):
```bash
usermod -aG docker $USER
```

## Project Deployment

1. Clone the repository:
```bash
git clone https://github.com/Ezrahel/nginx-upstream.git
cd nginx-upstream
```

2. Create the environment file:
```bash
cp .env.example .env
```

3. Update the environment variables in `.env`:
```bash
# Edit the .env file with your specific configuration
nano .env
```

Required variables:
- `SLACK_WEBHOOK_URL`: Your Slack webhook URL for alerts
- `BLUE_IMAGE`: Your application image for blue deployment
- `GREEN_IMAGE`: Your application image for green deployment
- `ACTIVE_POOL`: Initial active pool (blue or green)

4. Create required directories:
```bash
mkdir -p logs
chmod 755 logs  # Ensure proper permissions
```

5. Start the services:
```bash
docker compose up -d
```

## SSL Configuration (Optional)

If you want to use SSL with your domain:

1. Install Certbot:
```bash
apt install -y certbot python3-certbot-nginx
```

2. Obtain SSL certificate:
```bash
certbot --nginx -d yourdomain.com
```

3. Update Nginx configuration to use SSL:
- Edit `nginx/nginx.tmpl.conf` to include SSL configuration
- Restart Nginx container:
```bash
docker compose restart nginx
```

## Monitoring

1. Check service status:
```bash
docker compose ps
```

2. View logs:
```bash
# Nginx logs
docker compose logs nginx

# Alert watcher logs
docker compose logs alert_watcher

# Application logs
docker compose logs app_blue
docker compose logs app_green
```

## Performing Blue/Green Deployment

1. To switch between blue and green:
```bash
# Switch to green pool
export ACTIVE_POOL=green
docker compose up -d

# Switch to blue pool
export ACTIVE_POOL=blue
docker compose up -d
```

2. Verify the switch:
```bash
curl -I http://localhost:8080
```

## Troubleshooting

1. If alerts are not working:
- Check Slack webhook URL in `.env`
- Verify logs directory permissions:
```bash
chmod 755 logs
chown -R 1000:1000 logs  # Adjust UID/GID as needed
```
- Check alert watcher logs:
```bash
docker compose logs alert_watcher
```

2. If services fail to start:
- Check Docker logs:
```bash
docker compose logs
```
- Verify all containers are running:
```bash
docker compose ps
```
- Check system resources:
```bash
df -h  # Check disk space
free -m  # Check memory usage
```

## Security Setup

1. Configure firewall (UFW):
```bash
ufw allow ssh
ufw allow http
ufw allow https
ufw enable
```

2. Set up regular security updates:
```bash
apt install unattended-upgrades
dpkg-reconfigure --priority=low unattended-upgrades
```

3. Secure Docker daemon:
```bash
# Edit Docker daemon configuration
nano /etc/docker/daemon.json

# Add:
{
  "log-level": "warn",
  "iptables": true,
  "live-restore": true,
  "userland-proxy": false
}
```

4. Restart Docker after configuration changes:
```bash
systemctl restart docker
```

## Maintenance

1. Regular updates:
```bash
# Pull latest changes
git pull

# Rebuild and restart containers
docker compose down
docker compose pull
docker compose up -d
```

2. Cleanup:
```bash
# Remove unused images
docker image prune -a

# Remove unused volumes
docker volume prune

# Remove unused networks
docker network prune
```

## Backup Strategy

1. Back up configuration:
```bash
# Create backup directory
mkdir -p /root/backups

# Backup environment and configuration files
cp .env /root/backups/
cp nginx/nginx.tmpl.conf /root/backups/
```

2. Set up log rotation:
```bash
# Install logrotate if not present
apt install -y logrotate

# Create logrotate configuration
cat << EOF > /etc/logrotate.d/nginx-upstream
/var/log/nginx-upstream/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        docker compose restart nginx
    endscript
}
EOF
```

## Performance Tuning

1. Nginx tuning (edit `nginx/nginx.tmpl.conf`):
```nginx
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    keepalive_timeout 65;
    keepalive_requests 100;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
}
```

2. System limits (add to `/etc/security/limits.conf`):
```
* soft nofile 65535
* hard nofile 65535
```

## Monitoring Setup (Optional)

1. Install Node Exporter for Prometheus metrics:
```bash
docker run -d \
  --name node-exporter \
  --restart unless-stopped \
  --net="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  quay.io/prometheus/node-exporter:latest \
  --path.rootfs=/host
```

2. Set up basic monitoring with Docker:
```bash
# View container stats
docker stats

# Monitor system resources
htop  # Install with: apt install htop
```