---
title: "Problem 2 — Diagnose Me, Doctor"
subtitle: "Production Troubleshooting Report | Scenario 1: Ubuntu / NGINX Disk Utilization"
author: "DevOps Challenge Submission"
date: "22 October 2026"
geometry: margin=0.82in
fontsize: 10pt
colorlinks: true
linkcolor: NavyBlue
urlcolor: NavyBlue
header-includes:
  - \usepackage{fvextra}
  - \DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines,commandchars=\\\{\}}
---

# 1. Incident context and working assumptions

**Given scenario:** A cloud VM running Ubuntu 24.04 has 64 GB of provisioned storage. Monitoring consistently reports **99% disk utilization**. The VM's application role is to run **NGINX as a load balancer / reverse proxy** for upstream services.

**Objective:** Identify why storage is nearly exhausted, understand the effect on request routing, restore a safe amount of available space without creating an unnecessary outage, and prevent recurrence.

**What is not known yet:** Which filesystem is 99% full; whether the alert represents filesystem capacity or disk I/O utilization; storage and mount layout; whether NGINX runs directly or inside a container; log volume, cache settings, traffic trend, and the actual impact on users. There is **no host access, command output, or confirmed root cause** in the supplied brief. All scenarios below are hypotheses to verify, not reported findings.

**My operating principle:** *I will not delete files or restart the load balancer simply because the dashboard shows 99%. First I need to identify the affected filesystem and the data consuming space, while checking whether production traffic is still healthy.*

# 2. Triage: establish urgency before making changes

I would first correlate the alert with application impact. A load balancer can sometimes continue forwarding requests even when its disk is nearly full, but operations that write logs, temporary request bodies, buffered upstream responses, or cache data may fail. If the load balancer is a single instance, even a brief restart could be a customer-visible outage.

**Questions I would answer immediately:**

1. Is the alert **filesystem space used**, **inode exhaustion**, or **disk I/O busy**? These require different investigations.
2. Which mount point is affected? A 64 GB virtual disk does not guarantee that the root filesystem is 64 GB.
3. Are there increased 5xx responses, request timeouts, latency, or failed health checks?
4. Is this VM the **only** ingress path, or is there a healthy redundant load balancer?
5. Has usage climbed gradually or jumped suddenly? Did a deployment, logging change, traffic spike, or scheduled task occur around the increase?

**Initial read-only checks:**

```bash
# Capacity, filesystem types, and inode usage
sudo df -hT
sudo df -i
lsblk -f
findmnt -D

# Service state (if NGINX is managed by systemd)
systemctl is-active nginx
systemctl status nginx --no-pager
sudo journalctl -u nginx -n 50 --no-pager

# Check that NGINX is listening; this is NOT an end-to-end health check
sudo ss -ltnp
```

I would compare this information with external synthetic checks and load-balancer metrics (request count, upstream failures, 5xx rate, response latency). I would use an existing known-good hostname/path for an end-to-end request instead of assuming `/health` exists.

**Decision:** If traffic is currently impaired, treat this as an active incident: communicate status, prioritize a low-risk recovery, and preserve enough diagnostic evidence. If requests remain healthy, investigate promptly without taking a working load balancer offline.

# 3. Investigation: find the consumer, then explain its growth

## 3.1 Find the affected filesystem and largest directories

After identifying the full mount, I would inspect **that filesystem**, not blindly scan every mounted volume. The following examples assume root (`/`) is affected; replace the path if the alert refers to a different mount.

```bash
# First pass: largest directories on the same filesystem
sudo du -xhd1 / 2>/dev/null | sort -h

# Follow the largest branch (example: /var)
sudo du -xhd1 /var 2>/dev/null | sort -h
sudo du -xhd1 /var/log 2>/dev/null | sort -h

# Targeted examples: inspect paths only if they exist
sudo du -sh /var/log/nginx /var/cache/nginx 2>/dev/null
sudo journalctl --disk-usage
```

The reason for this order is simple: `df` shows filesystem consumption, while `du` helps attribute it to visible directories. I would start with a broad breakdown, then narrow the search based on evidence. A full recursive `find` or `du` can add significant metadata I/O during an incident; I would avoid unnecessarily expensive scans when a targeted check is enough.

If a directory is still unexplained, I would inspect large files on the relevant mount:

```bash
# Example for a full root filesystem only
sudo find / -xdev -type f -size +500M \
  -printf '%s bytes  %p\n' 2>/dev/null | sort -nr | head -30
```

The size threshold is a practical starting point, **not** a guarantee: millions of small files can also fill a disk.

## 3.2 If `df` and `du` do not agree

A large gap is a clue, not an excuse to delete more files. Possible explanations include deleted files still held open, reserved filesystem blocks, mount boundaries, or data hidden underneath mount points. My next check would be:

```bash
# Show open files with link count below 1 (unlinked/deleted)
sudo lsof +L1
```

For example, if a process is still writing to a log that someone has deleted, the blocks can remain allocated until the process closes the descriptor. I would identify the **process and file**, then use that service's supported reopen/reload procedure. I would only consider a restart if it is necessary and the impact has been assessed.

## 3.3 Inspect NGINX configuration, not just default paths

Since NGINX is the only application role, its log and temporary-data configuration deserves early attention. But I would not assume caching is enabled or that all installations write to `/var/log/nginx`.

```bash
# Validate syntax before any future config change
sudo nginx -t

# Inspect effective directives; handle output carefully if it contains secrets
sudo nginx -T 2>&1 | grep -nE \
  -e 'access_log|error_log' \
  -e 'proxy_cache_path|proxy_temp_path' \
  -e 'client_body_temp_path|proxy_buffering' \
  -e 'proxy_max_temp_file_size'

# Discover actual log sizes if the default directory is configured
sudo ls -lhS /var/log/nginx/ 2>/dev/null

# Check logrotate rules and recent rotation results
sudo cat /etc/logrotate.d/nginx 2>/dev/null
sudo tail -n 100 /var/log/nginx/error.log 2>/dev/null
```

My next question would be **why the largest consumer grew**. A 20 GB access log, for instance, does not by itself prove that logrotate is broken; it could be legitimate high volume, automated traffic, an overly verbose log format, or multiple log destinations. I would correlate modification times and growth patterns with request metrics, deployment history, and the first disk alert.

# 4. Hypotheses: evidence, impact, and recovery

The order below is a **working investigation priority**, not a claim that these causes are present.

## H1 — NGINX access logs are growing faster than they are rotated

**Evidence I would seek:** An unusually large `access.log` or rotated archives; sustained growth aligned with request volume; missing or ineffective logrotate rules; custom log paths omitted from rotation; repeated requests from a small set of clients. I would check traffic patterns before assuming abuse.

**Potential impact:** Space exhaustion, failed log writes, loss of observability, and failures in other writes on the same filesystem. Normal proxying might still work initially; degraded responses depend on whether the request path needs disk-backed operations.

**Recovery:** Preserve logs needed for the investigation or security requirements. Confirm retention policy and a safe archive destination. If log rotation is appropriate, rename the active logs using the configured rotation mechanism and tell NGINX to reopen its log descriptors (`sudo nginx -s reopen`, after confirming this control method applies). Remove or archive **old rotated** files according to policy. Merely reopening the logs does not recover space still occupied by archives. Avoid deleting an active log file: a process may keep writing to the deleted inode.

**Prevention:** Enforce size/time rotation, compression and retention; include all custom logging paths; send critical logs to centralized storage; alert on abnormal log growth and request surges.

## H2 — NGINX error logs are exploding because of an upstream problem

**Evidence I would seek:** Very large `error.log`; bursts of repeated messages such as upstream timeout, connection refusal, or resolution failures; correlated increases in upstream latency and 502/504 responses. The log explosion could be an **effect of another incident**, not the original root cause.

**Potential impact:** High disk churn; incomplete diagnostics as space runs out; possible customer-visible upstream errors.

**Recovery:** Preserve a representative log window, classify the repeated error, and address the upstream or configuration fault. Reclaim older logs safely and adjust logging volume only if doing so will not hide the active problem. Validate routing after the change.

**Prevention:** Alert on upstream error rates independently of disk usage; use sensible log severity and retention; investigate repeated errors rather than suppressing them without resolution.

## H3 — Proxy cache or NGINX temporary files are consuming storage

**Evidence I would seek:** Large cache or temp directories that match configured `proxy_cache_path`, `proxy_temp_path`, or `client_body_temp_path`; cache enabled in the effective config; request-body uploads, large upstream responses, or heavy buffering near the alert start.

**Potential impact:** Failure to buffer requests/responses that require disk space, potentially resulting in errors or latency. Impact depends on NGINX settings and traffic patterns.

**Recovery:** Identify the *configured* paths and live usage. For a confirmed cache problem, follow the documented cache-invalidation/cleanup approach or carry out controlled maintenance rather than wiping an active directory. For temp-file pressure, investigate the associated workload and tune buffering/size settings as appropriate. If more capacity is genuinely required, place cache/temp data on a correctly sized separate filesystem.

**Prevention:** Set cache bounds (for example `max_size` where applicable), monitor cache/temp growth, and load-test large request/response cases.

## H4 — OS logging or other system-managed files are growing

**Evidence I would seek:** High `/var/log/journal` usage or large unattended logs; `journalctl --disk-usage`; high-volume logs from system services or monitoring agents. NGINX may be the only application, but Ubuntu still runs system services.

**Potential impact:** The OS may be unable to persist diagnostics or state updates; incident investigations become more difficult.

**Recovery:** Export evidence if necessary. If the journal is confirmed to be the consumer and policy permits, a controlled reclamation option is:

```bash
sudo journalctl --rotate --vacuum-size=500M
```

This affects **archived journal files**; the configured `500M` is an example retention target, not a universally appropriate setting. It may discard historical diagnostics, so I would obtain approval or preserve relevant logs first.

**Prevention:** Set journald limits such as `SystemMaxUse`, monitor OS logs, and correct recurring error-generating processes.

## H5 — Large files were deleted but are still open

**Evidence I would seek:** `df` reports significantly more usage than visible files account for; `sudo lsof +L1` shows large deleted files held by NGINX or another process.

**Potential impact:** Free space does not return despite earlier cleanup. The team may falsely believe that the situation has been fixed.

**Recovery:** Map each deleted descriptor to its owning process. For NGINX log descriptors, use NGINX log reopening where appropriate; for another service, use its safe reopen or controlled restart procedure. Re-check `df` after the descriptor closes.

**Prevention:** Rotate logs with service-aware procedures instead of deleting actively written files.

## H6 — Other files, inodes, or a capacity/layout mismatch

**Evidence I would seek:** Large package caches, Snap revisions, unexpected backups, crash dumps, or agent output; `df -i` shows inode exhaustion even if byte usage is not the whole problem; `lsblk` shows a disk larger than the mounted partition or a filesystem smaller than expected.

**Potential impact:** New file creation fails, writes by NGINX or OS components fail, or the monitoring team is measuring a different partition than assumed.

**Recovery:** Identify ownership before removing old packages, dumps, or backups. For inode pressure, locate directories containing huge file counts and remediate the responsible workload. For a legitimate capacity shortage, verify cloud-volume size, partitions and filesystem type; take the required backup/snapshot and resize the correct layer using the appropriate tools. Storage expansion provides breathing room, but does **not** fix uncontrolled growth.

**Prevention:** Document mount layout and ownership, enforce lifecycle policies, and forecast growth with capacity/headroom alerts.

## H7 — Unexpected process or security-related activity

**Evidence I would seek:** Files and processes unrelated to the VM's role, anomalous traffic, unknown scheduled tasks, or sudden writes outside expected NGINX/OS paths.

**Potential impact:** Disk exhaustion may be a symptom of unauthorized activity; deleting evidence immediately could undermine investigation.

**Recovery:** Follow security incident procedures, preserve evidence and isolate the host when instructed by the incident/security lead. Rebuild from a known-good image if compromise is confirmed; avoid treating disk cleanup as the complete fix.

**Prevention:** Least privilege, patching, access auditing, host monitoring, and change control.

# 5. Recovery decision: choose the least disruptive valid action

I would use this order of operations, adjusting it to what the evidence actually shows:

1. **Stabilize and communicate.** If requests are failing, declare/track an incident, identify a traffic failover option, and avoid unnecessary changes to the only ingress VM.
2. **Preserve the minimum useful evidence.** Capture key metrics, configuration details, directory sizes and representative logs. Avoid copying large files **onto the full filesystem**.
3. **Make a targeted, reversible recovery.** For example, safely archive/prune old rotated logs **if logs are the confirmed consumer**. I would not run blanket `rm -rf /var/log/*`, empty arbitrary temp directories, or force a reboot.
4. **Fix the source of growth.** Repair broken rotation, upstream errors, cache limits, or the actual writing process rather than only removing its output.
5. **Expand capacity when justified.** If legitimate workload growth makes 64 GB inadequate, resize with the correct cloud/filesystem procedure after confirming backups and mount layout.
6. **Record exactly what changed.** Include commands executed, approvals, observed before/after usage, service impact, and any residual risks.

**If there is no safe cleanup path:** I would prefer an approved filesystem/volume expansion or traffic failover over destructive changes on an active single-instance load balancer.

# 6. Verify recovery (do not stop at “NGINX is active”)

**Infrastructure verification:**

```bash
# Compare with initial output: correct mount must have adequate headroom
sudo df -hT
sudo df -i

# Validate syntax and service status
sudo nginx -t
systemctl is-active nginx

# Check NGINX service errors after remediation
sudo journalctl -u nginx -n 100 --no-pager
```

**Application verification:** From a client-side monitoring point, send requests to a **known working production test endpoint** through the actual load balancer; confirm expected HTTP status/content, TLS behavior where applicable, acceptable latency, and successful upstream routing. Watch request rate, 5xx rate, upstream errors and the **rate of disk consumption** after recovery.

**Success criteria:**

- The **specific alerted filesystem** has recovered adequate headroom, not merely a temporary percentage improvement.
- Legitimate traffic remains available and error/latency indicators have returned to their expected baseline.
- The source of growth is identified or explicitly documented as an unresolved hypothesis with the next evidence-gathering action.
- The remediation survives subsequent rotation/traffic cycles; utilization is not immediately trending back toward exhaustion.

If a configuration change increases errors, use the previously validated configuration and the approved rollback/failover process. Do not assume that `nginx -t` alone proves request routing is healthy.

# 7. Long-term controls and lessons

| Control | Rationale |
|:--|:--|
| Filesystem **space and inode** alerts with trend-based forecasting | Catch both large-file growth and many-small-file exhaustion before reaching critical headroom. |
| Logging rotation, compression, retention, and centralized collection | Prevent uncontrolled local storage growth while preserving useful evidence. |
| NGINX request, upstream error, 5xx and latency monitoring | Connect resource alerts to real customer impact. |
| Cache/temp directory monitoring and explicit limits | Keep disk-backed proxy behavior bounded and observable. |
| Regular review of mount layout and storage headroom | Distinguish misconfiguration from legitimate demand for more storage. |
| Documented runbook, owner, escalation path and rollback | Allow safe response even if the primary engineer is unavailable. |

# 8. Final assessment

**My first suspects** on a VM whose application role is only NGINX would be access logs, error logs, and disk-backed buffering/cache. But I would not call any of them the root cause without measurements. The investigation starts with verifying what **99%** measures, checking production impact, and locating the filesystem consumer. Only then would I select a targeted recovery.

A successful incident response is not just **“disk usage went down.”** It is **“we know what consumed the space, we restored safe headroom without unnecessary disruption, traffic is verified healthy, and there is a control to detect or prevent recurrence.”**

---

## Reference documentation

- NGINX: [Controlling NGINX and reopening log files](https://nginx.org/en/docs/control.html)
- NGINX: [HTTP proxy module / proxy buffering and temporary files](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- systemd: [journalctl rotation and vacuum behavior](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html)
- Linux: [lsof +L1 for unlinked open files](https://man7.org/linux/man-pages/man8/lsof.8.html)

*Scope note: This report addresses the storage-exhaustion scenario provided in Problem 2. The brief mentions two production issues, but a second scenario was not included in the supplied task text.*
