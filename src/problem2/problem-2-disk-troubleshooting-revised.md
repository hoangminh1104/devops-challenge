# Problem 2 — VM Disk at 99% (NGINX Load Balancer)

**Scenario:** Ubuntu 24.04 VM, 64 GB disk, running NGINX as a reverse proxy/load balancer. Monitoring reports 99% disk usage.

## My approach

I would prioritize keeping production traffic available, reclaim disk space safely, and then investigate why usage reached 99%. I would not restart NGINX or delete files just because the disk is nearly full.

**Quick estimate:** If the *monitored filesystem* is 64 GB, 99% used means roughly **63.4 GB used and 0.6 GB remaining**. The actual capacity could differ due to partitions and filesystem overhead. I would measure it rather than guess how much Ubuntu or NGINX consumes.

## 1. Verify impact and locate disk consumption

First, I would confirm the affected filesystem, check if NGINX is still running, and look for customer impact (5xx rate, latency, timeouts). I would also confirm whether another load balancer can handle traffic if this VM fails.

```bash
# Filesystem, inode and partition status
df -hT
df -i
lsblk -f

# Service health (not proof that routing works)
systemctl is-active nginx

# Largest directories on the root filesystem
sudo du -xhd1 / 2>/dev/null | sort -h
sudo du -xhd1 /var 2>/dev/null | sort -h

# Large individual files on that filesystem
sudo find / -xdev -type f -size +500M \
  -printf '%s %p\n' 2>/dev/null | sort -nr | head -20
```

I would focus the scan on the filesystem reported as full, and avoid heavy scans at peak traffic if disk I/O is already saturated. If `/var/log/nginx` is the main consumer, old rotated logs are a good candidate for archival; if it is somewhere else, I would follow the evidence rather than assume NGINX is responsible.

## 2. Recover space safely — assume S3 access is available

Assume I find a large **old, rotated** log at `/var/log/nginx/access.log.1`. The S3 bucket and VM permissions are already configured. I would verify the file is no longer being written, stream it to S3 without creating another local copy, and verify the transfer **before** deleting anything.

```bash
FILE=/var/log/nginx/access.log.1
S3_URI=s3://approved-incident-backups/problem-2/access.log.1

# Confirm size and whether a process still holds it open
sudo ls -lh "$FILE"
sudo lsof -- "$FILE"   # No open handles is expected

# Stream directly to S3, retaining the VM user's AWS credentials
# Stop immediately on failure (do not proceed to cleanup)
set -euo pipefail
LOCAL_SHA=$(sudo sha256sum "$FILE" | awk '{print $1}')
sudo cat "$FILE" | aws s3 cp - "$S3_URI" --only-show-errors

# Read back as a stream; compare hashes (no local download)
REMOTE_SHA=$(aws s3 cp "$S3_URI" - --only-show-errors | sha256sum | awk '{print $1}')
test "$LOCAL_SHA" = "$REMOTE_SHA"
echo "Backup verified"
```

Only after the script prints `Backup verified`, confirmation that the file is not open, and approval under the log-retention policy would I remove the local copy and check disk usage. Cleanup is a **separate, manual step**, never an automatic continuation of the upload:

```bash
sudo rm -- "$FILE"          # ONLY after the checks above pass
df -hT /
```

**Important:** I would **not** rename or delete a live `access.log` and assume space is freed. If the active log is the problem, I would rotate/rename it using the approved procedure and issue `sudo nginx -s reopen` so NGINX switches log files; then I would archive and clean up the old file once it is no longer open. This avoids an unnecessary NGINX restart. If there is no safe cleanup candidate, I would consider extending the volume as an emergency mitigation.

## 3. Investigate likely root causes

Once the immediate risk is contained, I would inspect NGINX configuration and logs:

```bash
sudo nginx -T 2>&1 | grep -nE \
  'access_log|error_log|proxy_buffering|proxy_cache|proxy_temp_path|client_body_temp_path'
sudo du -sh /var/log/nginx /var/cache/nginx 2>/dev/null
sudo tail -n 100 /var/log/nginx/error.log
sudo cat /etc/logrotate.d/nginx
sudo journalctl --disk-usage
sudo lsof +L1
```

| Suspected cause | Impact / evidence I would expect | Recovery and prevention |
|---|---|---|
| **Access logs growing too fast** | High request volume or broken log rotation; disk usage rises continuously. | Fix rotation/retention, archive old logs, check traffic spikes or abuse. |
| **Error-log storm** | Repeated upstream errors/timeouts; diagnostics fill the disk. | Fix the underlying upstream or network issue, then correct logging volume. |
| **Proxy buffering/temp files** | Large request/response bodies may write temporary files; disk-full errors can break affected requests. | Check actual temp paths and buffering settings; tune for workload, without clearing in-use files. |
| **Proxy cache, if enabled** | Disk used by cached responses. | Set cache size/retention limits; perform controlled cache cleanup if necessary. |
| **OS journal or deleted-but-open files** | `journalctl --disk-usage` is high, or `df` and `du` do not agree. | Apply journal retention, or make the owning process close the deleted file safely. |

These are **hypotheses**, not confirmed root causes. I would correlate disk growth with traffic, deployments, configuration changes and timestamps before concluding.

## 4. Verify production and close the incident

```bash
df -hT /
df -i /
sudo nginx -t
systemctl is-active nginx
# Also run a real request to a known-good hostname/path via NGINX.
```

I would confirm the disk has a safe margin, successful requests still flow through the load balancer, and 5xx rate/latency are back to normal. Finally, I would enforce log rotation and retention, configure limits for any enabled cache, alert on both disk usage **and disk growth rate**, and document the confirmed cause.

**Conclusion:** The objective is not just to delete enough files to clear the alert. It is to protect production traffic, preserve evidence, reclaim space safely, identify what caused the growth and prevent recurrence.

---
**References:** [NGINX log reopening](https://nginx.org/en/docs/control.html) · [NGINX proxy buffering](https://nginx.org/en/docs/http/ngx_http_proxy_module.html) · [AWS CLI S3 streaming](https://docs.aws.amazon.com/cli/latest/userguide/cli-services-s3-commands.html)
