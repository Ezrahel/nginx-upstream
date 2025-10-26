# Blue/Green with Nginx Upstreams (Auto-Failover + Manual Toggle)

This repository provides a Docker Compose setup that places an Nginx reverse proxy in front of two pre-built Node.js app images: `app_blue` and `app_green` (Blue/Green).

Goals implemented
- All traffic goes to the active pool by default (controlled by `ACTIVE_POOL`)
- On failure of the active pool, Nginx retries and fails over to the backup server within the same client request (so clients see 200)
- Primary is marked with `max_fails=1` and `fail_timeout=2s` to detect problems quickly
- Tight timeouts and retry policy are configured so failover happens fast (<10s)
- Response headers from the apps (`X-App-Pool`, `X-Release-Id`) are forwarded unchanged to the client

Files added
- `docker-compose.yml` — Compose stack exposing:
  - Nginx public entrypoint: http://localhost:8080
  - Blue direct port (for grader chaos): http://localhost:8081
  - Green direct port: http://localhost:8082
- `nginx/nginx.tmpl.conf` — Nginx template; entrypoint script replaces placeholders with runtime values.
- `nginx/entrypoint.sh` — Generates `nginx.conf` from template and starts nginx in foreground.
- `nginx/reload.sh` — Regenerate config and gracefully reload nginx (useful for CI toggles).
- `.env.example` — Example environment variables; copy to `.env` and edit values.

Environment variables (in `.env`)
- `BLUE_IMAGE` — image reference for Blue
- `GREEN_IMAGE` — image reference for Green
- `ACTIVE_POOL` — `blue` or `green` (controls which server is primary)
- `RELEASE_ID_BLUE` — passed into Blue container as `RELEASE_ID` env
- `RELEASE_ID_GREEN` — passed into Green container as `RELEASE_ID` env
- `PORT` — port the application listens on inside container (default 3000)

How it works
1. Template placeholders `__PRIMARY_HOST__`, `__BACKUP_HOST__`, and `__APP_PORT__` are replaced by `entrypoint.sh` using the `ACTIVE_POOL` environment variable.
2. Nginx upstream sets the primary server with `max_fails=1` and `fail_timeout=2s` and the other server as `backup`.
3. `proxy_next_upstream` is configured to retry on `error`, `timeout`, and `http_5xx` and `proxy_next_upstream_tries 2`, so a failing primary will be retried on the backup in the same client request.
4. Tight connect/read/send timeouts ensure requests do not exceed 10 seconds.

Quick start
1. Copy `.env.example` to `.env` and set real image names and variables the grader/CI will provide.

2. Start services:

```powershell
cd c:\Users\DiTech\Documents\nginx-upstream
docker-compose up -d
```

3. Verify baseline (Blue active):
- GET http://localhost:8080/version should return 200 and headers `X-App-Pool: blue` and `X-Release-Id: $RELEASE_ID_BLUE`.
- Direct GET http://localhost:8081/version hits blue directly.

4. Induce chaos on the active app (grader will POST to the app directly):
- POST http://localhost:8081/chaos/start?mode=error

Requests to http://localhost:8080/version should be retried to Green and return 200 with `X-App-Pool: green`.

Manual toggling of active pool (CI friendly)
- To change active pool in container environment, update `.env` and then regenerate and reload nginx inside the `nginx-bg` container:

```powershell
# after updating .env and restarting container env (or you can set env via docker-compose up -d)
docker exec nginx-bg /reload.sh
```

Note: CI/grader may simply set `ACTIVE_POOL` and run `docker-compose up -d` to start with the desired active pool.

Testing hints for graders
- Ensure apps are reachable on 8081 and 8082.
- Baseline: repeatedly request `/version` on `http://localhost:8080` to confirm all responses show the active pool and correct `X-Release-Id`.
- Start chaos on the active app using `/chaos/start` and verify the next `GET /version` returns `X-App-Pool: green` within a few seconds.
- Confirm no non-200 responses are seen during the test loop.

If you want, I can also add a small test script or CI job to automatically validate the failover loop. Want me to add that now?

CI and automated verification
---------------------------

This repository includes a simple automated verification harness and a GitHub Actions workflow that runs the failover test in CI.

- `test/verify.ps1` — PowerShell script that:
  - Verifies baseline responses from `http://localhost:8080/version` show the configured `ACTIVE_POOL` and correct `X-Release-Id`.
  - Triggers chaos on the active app via the app's `/chaos/start?mode=error` endpoint (the grader or the CI supplies the images that implement this endpoint).
  - Polls `http://localhost:8080/version` for 10s, ensures there are 0 non-200 responses and that >=95% of responses come from the backup pool.
  - Stops chaos via `/chaos/stop` and exits 0 on success or non-zero on failure.

- `.github/workflows/ci.yml` — example CI workflow that expects the following repository secrets to be configured in the CI environment:
  - `BLUE_IMAGE`, `GREEN_IMAGE` — container image references for the two app variants
  - `ACTIVE_POOL` — `blue` or `green` to set the starting active pool
  - `RELEASE_ID_BLUE`, `RELEASE_ID_GREEN` — release ids passed into the containers
  - `PORT` — port the apps listen on inside the container (default `3000`)

The workflow brings up the Compose stack, waits briefly, runs `test/verify.ps1` (using PowerShell), and tears down the stack. Add the required secrets to your repository before running CI.

If you want me to tune the verification thresholds, make the script more conservative, or convert the script to a cross-platform Node/Python runner, I can do that next.