# Problem 2 — NGINX VM at 99% Disk Usage

I’d first check whether customers are affected, then find what’s filling the disk, recover space and fix the growth. The exercise mentions two issues but supplies only this scenario, so that’s the scope here.

## 1. Check traffic and identify the full filesystem

```bash
df -hT
df -i
lsblk -f
systemctl is-active nginx
sudo journalctl -u nginx -n 50 --no-pager
```

These show capacity, inodes, storage layout and service errors. The provisioned 64 GB disk may contain smaller filesystems. NGINX being active doesn’t prove routing works: I’d also check a known-good request through this VM and compare 5xx rates and latency. If traffic is failing, I’d consider controlled failover to a healthy peer with sufficient capacity.

## 2. Find what’s using the disk

```bash
# Replace / with the affected mount; follow its largest directory branch
MOUNT=/
sudo du -xhd1 "$MOUNT" | sort -h
sudo du -xhd1 /var | sort -h   # If /var is on that filesystem

# If inodes are exhausted, look for many-small-file growth
sudo du --inodes -x -d1 "$MOUNT"

# If df usage is much larger than du can explain
sudo lsof +L1

# Discover configured log, cache and temporary paths
sudo nginx -T 2>&1 | grep -E 'access_log|error_log|proxy_cache|temp_path|buffering'
sudo cat /etc/logrotate.d/nginx
sudo journalctl -u logrotate.service -n 30 --no-pager
sudo journalctl --disk-usage
```

`du -x` stays on one filesystem. I’d inspect errors and configured paths, avoiding repeated heavy scans when I/O is saturated. These commands assume host-managed NGINX; a container deployment also needs runtime logs and mount inspection.

If NGINX logs take most of the space, I’d check whether rotation failed or traffic increased. If the error log is growing quickly, I’d read the errors: an upstream might be failing, and clearing the log won’t fix that. I’d preserve useful logs, reclaim eligible old files and fix the cause of growth.

If it’s cache or temporary files, I’d check the configured paths and what NGINX is using them for. Some may belong to requests still running. Running out of space can break requests that need disk, so I’d address cache limits, workload or capacity rather than blindly clear those directories.

If it’s system logs, agent output or dumps, I’d identify the owner and use its cleanup and retention settings. NGINX being the only application doesn’t mean it’s the only process writing to disk.

If inodes are exhausted, I’d find the directory creating too many files and remove only eligible files. If large deleted files are still open, I’d identify the owner and make it close them safely. NGINX log reopening can release log handles, but won’t close temporary files belonging to active requests.

## 3. Free up disk space

If an old, closed log is the main consumer, I’d confirm it is no longer being written and keep rotation from changing it during archival. Assuming S3 access is configured, I’d stream it directly to S3 without making another local copy:

```bash
# Set FILE to the selected closed log, S3_URI to a unique approved destination,
# and SIZE to the file size in bytes before running this command.
sudo cat -- "$FILE" | aws s3 cp - "$S3_URI" --expected-size "$SIZE" --only-show-errors
```

Uploading alone doesn’t free local space. I’d verify the uploaded contents against the unchanged local file using checksums, record the backup location, then remove only that file if retention permits. If upload or verification fails, I’d keep the local file. After removal, I’d recheck the affected filesystem.

For a large active log, I’d use proper rotation, ensure room for replacement logs, then run `sudo nginx -s reopen` if appropriate for this installation. I’d verify replacement writes and closed old handles before archival. Deleting a live log doesn’t guarantee freed space.

If remaining headroom divided by growth rate leaves too little time for upload and verification, I’d choose another safe cleanup, failover or storage expansion. Expansion must cover the correct volume/partition/filesystem layers; it buys time but doesn’t fix uncontrolled growth.

## 4. Verify the recovery lasts

```bash
df -hT "$MOUNT"
df -i "$MOUNT"
sudo nginx -t
systemctl is-active nginx
```

I’d verify real routing again, check errors/latency and measure disk growth. Closure means sufficient bytes and inodes, healthy traffic and a corrected or explicitly tracked cause. I’d verify the next relevant rotation/traffic cycle and add space, inode and growth-rate alerts.
