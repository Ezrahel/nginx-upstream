# Runbook: Nginx Blue/Green Observability

This runbook provides instructions for operators on how to respond to alerts from the Nginx log watcher.

## Alert Types

### 1. Failover Detected

- **Alert Message:** `Failover detected: <old_pool> -> <new_pool>`
- **Meaning:** The active application pool has been switched from the `<old_pool>` to the `<new_pool>`. This is usually triggered by a health check failure in the primary pool.
- **Operator Action:**
    1. **Verify the health of the old pool:** Check the logs of the container for the `<old_pool>` (e.g., `docker logs app_blue`) to understand why it became unhealthy.
    2. **Check the application status:** Ensure the application is still accessible and functioning correctly on the `<new_pool>`.
    3. **Plan for recovery:** Once the issue with the `<old_pool>` is resolved, you can manually switch back by updating the `ACTIVE_POOL` in the `.env` file and restarting the Nginx container.

### 2. High Upstream Error Rate

- **Alert Message:** `High upstream error rate: <rate>% over last <window_size> requests`
- **Meaning:** The percentage of 5xx errors from the upstream application servers has exceeded the configured threshold.
- **Operator Action:**
    1. **Inspect upstream logs:** Check the logs of both the `app_blue` and `app_green` containers to identify the source of the errors.
    2. **Consider a manual failover:** If the errors are isolated to the current active pool, you can trigger a manual failover by updating the `ACTIVE_POOL` in the `.env` file and restarting the Nginx container.
    3. **Investigate application issues:** The errors might be caused by a bug or a performance issue in the application itself.

## Maintenance Mode

To suppress alerts during planned maintenance or testing, you can enable maintenance mode by setting the following environment variable in your `.env` file:

```
MAINTENANCE_MODE=true
```

Remember to set it back to `false` after the maintenance is complete.
