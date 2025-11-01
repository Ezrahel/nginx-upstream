# Deploying on a Linode Ubuntu Server

This guide provides step-by-step instructions for deploying the Nginx blue/green setup with observability on a Linode Ubuntu server.

## Prerequisites

Before you begin, you will need:
- A Linode account.
- A running Linode instance with Ubuntu 22.04 LTS.
- A domain name pointed to your Linode's IP address (optional, but recommended for production).
- A Slack workspace and a webhook URL for alerts.

## Step 1: Connect to Your Linode Instance

Connect to your Linode instance via SSH:
```bash
ssh root@<your_linode_ip>
```

## Step 2: Install Dependencies

You need to install Git, Docker, and Docker Compose on your server.

### 1. Update Your System
```bash
sudo apt-get update
sudo apt-get upgrade -y
```

### 2. Install Git
```bash
sudo apt-get install git -y
```

### 3. Install Docker
```bash
sudo apt-get install docker.io -y
sudo systemctl start docker
sudo systemctl enable docker
```
Add your user to the `docker` group to run Docker commands without `sudo`:
```bash
sudo usermod -aG docker ${USER}
```
You will need to log out and log back in for this change to take effect.

### 4. Install Docker Compose
```bash
sudo apt-get install docker-compose -y
```

## Step 3: Clone the Repository

Clone the project repository from GitHub:
```bash
git clone https://github.com/Ezrahel/nginx-upstream.git
cd nginx-upstream
```

## Step 4: Configure Environment Variables

Create a `.env` file from the example template:
```bash
cp .env.example .env
```

Now, edit the `.env` file with your favorite editor (e.g., `nano`):
```bash
nano .env
```

You will need to set the following variables:
- `SLACK_WEBHOOK_URL`: Your Slack incoming webhook URL.
- `ACTIVE_POOL`: Set the initial active pool (e.g., `blue`).
- `BLUE_IMAGE` and `GREEN_IMAGE`: The Docker images for your blue and green environments. You can use the default values if you haven't changed them.
- `RELEASE_ID_BLUE` and `RELEASE_ID_GREEN`: Release identifiers for your blue and green environments.

Save and close the file when you are done.

## Step 5: Build and Run the Services

Use Docker Compose to build and run all the services in detached mode:
```bash
docker-compose up --build -d
```

## Step 6: Verify the Deployment

Check the status of your running containers:
```bash
docker-compose ps
```
You should see `nginx-bg`, `app_blue`, `app_green`, and `alert_watcher` running.

You can now access your application by navigating to `http://<your_linode_ip>:8080` in your web browser.

To view the logs for any service, use the following command:
```bash
docker-compose logs -f <service_name>
```
For example, to view the logs for the `alert_watcher` service:
```bash
docker-compose logs -f alert_watcher
```

You can test the failover and alerting by following the instructions in the `README.md` file.
