# Problem 3 — Investigation Report

**TL;DR:** The API was down because nginx pointed at the wrong port. It was unstable because it crashed or hung on any Postgres or Redis hiccup. I fixed 5 issues, each verified by re-running the failure, and added a health endpoint for monitoring.

| # | Problem | Before → After |
|---|---|---|
| 1 | `/` downloads as a file | `octet-stream` → `text/plain` |
| 2 | nginx → wrong API port | 502 → 200 |
| 3 | API crashes on Postgres restart | `Exited (1)` → stays up |
| 4 | No DB timeouts | 504 @ 60s → 500 @ 2s |
| 5 | Request blocked by Redis | 500 @ 57s → 200 @ 0.03s |
| 6 | No way to see dependency health | → `/api/health`: ok / degraded / down |

---

## 1. Homepage downloads as a file
When I tried to go to http://localhost:8080, it would download the app..
Content-type thingy here
```text
> curl.exe -i http://localhost:8080/
HTTP/1.1 200 OK
Server: nginx/1.25.5
Content-Type: application/octet-stream

Welcome to the platform
```

→ `return` has no file extension, so nginx falls back to `default_type` (octet-stream).
Fix by adding Content-Type
```diff
 location = / {
+    default_type text/plain;
     return 200 "Welcome to the platform\n";
 }
```

## 2. API returns 502

```text
> curl.exe -i http://localhost:8080/api/users
HTTP/1.1 502 Bad Gateway
Server: nginx/1.25.5

> docker compose ps
problem3-api-1        Up About an hour
problem3-nginx-1      Up About an hour
problem3-postgres-1   Up About an hour
problem3-redis-1      Up About an hour
```

→ The 502 comes from nginx

```text
> docker compose logs --tail=50 nginx
[error] connect() failed (111: Connection refused) while connecting to upstream,
upstream: "http://172.23.0.4:3001/api/users"

> cat .\nginx\conf.d\default.conf
    proxy_pass http://api:3001;
> cat .\api\src\index.js
app.listen(3000, () => console.log("API running on 3000"));
```

→ nginx targets 3001; the app is on 3000.

fix: adjust api port from 3001 to 3000 because the app is listening to port 3000

```diff
 location /api/ {
-    proxy_pass http://api:3001;
+    proxy_pass http://api:3000;
 }
```

```text
> docker compose exec nginx nginx -t
nginx: configuration file /etc/nginx/nginx.conf test is successful
> docker compose exec nginx nginx -s reload
> curl.exe -i http://localhost:8080/api/users
HTTP/1.1 200 OK
{"ok":true,"time":{"now":"2026-10-21T07:30:02.420Z"}}
```

→ Fixed.
I not sure whether this bug is intended, because the exercise itself says "Users are reporting that the API is unreliable and sometimes inaccessible"
I assume that users are able to use the api. And it acts up sometimes only.
## 3. API dies when Postgres restarts

```text
browser ──► nginx :8080 ──► api :3000 ──┬──► postgres :5432   every request (SELECT NOW())
                                        └──► redis :6379      side write (last_call)
```

→ "Sometimes" is still unexplained. I'll dig into each component

Start with api → postgres:

```js
const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
});
// no pool.on("error")  <- errors on idle connections have nowhere to go

app.get("/api/users", async (req, res) => {
  try {
    const db = await pool.connect();
    const result = await db.query("SELECT NOW()");
    db.release();                       // back to the pool, stays open ~10s (idle)

    await redis.set("last_call", Date.now());
    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {                       // only catches errors *during* a request
    console.error(err);
    res.status(500).json({ ok: false, error: err.message });
  }
});
```

→ Request errors are caught by `try/catch`, but errors on idle connections *between* requests aren't. Nothing listens on the pool.
→ Guess: DB drops an idle connection (restart, failover, maintenance) → pool emits `error` → no listener → Node exits.
→ Test: one request (leaves an idle connection for ~10s), then restart the DB.

```text
> curl.exe -s http://localhost:8080/api/users; docker compose restart postgres
{"ok":true,...}
 Container problem3-postgres-1 Restarting

> docker compose ps
problem3-nginx-1      Up 2 hours
problem3-postgres-1   Up 20 seconds
problem3-redis-1      Up 2 hours          <- api missing

> curl.exe -i http://localhost:8080/api/users
HTTP/1.1 502 Bad Gateway

> docker compose ps -a api; docker compose logs api | Select-String -Pattern "terminating|Emitted 'error'" -Context 0,1
problem3-api-1   Exited (1) 3 minutes ago
> error: terminating connection due to administrator command
> Emitted 'error' event on BoundPool instance at:
    at Client.idleListener (/app/node_modules/pg-pool/index.js:62:10)
```

→ Confirmed. DB came back, API stayed dead (no restart policy). Needs traffic in the last ~10s, hence *sometimes*.

```diff
+pool.on("error", (err) => {
+  console.error("Postgres idle client error:", err.message);
+});
```

```diff
   api:
+    restart: unless-stopped
```

```text
> docker compose up -d --build api
> curl.exe -s http://localhost:8080/api/users; docker compose restart postgres
> docker compose ps api; docker compose logs --tail 5 api; curl.exe -i http://localhost:8080/api/users
problem3-api-1   Up 2 minutes
api-1  | Postgres idle client error: terminating connection due to administrator command
HTTP/1.1 200 OK
```

→ Error is now logged, not fatal. The restart policy is only a safety net, and restarts are alerted on.

## 4. 504 Timeout when DB hangs.

```js
const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
  // no connectionTimeoutMillis  <- waits forever for a connection
  // no query_timeout            <- waits forever for a result
});

app.get("/api/users", async (req, res) => {
  try {
    const db = await pool.connect();                // hang #1: DB never finishes the handshake
    const result = await db.query("SELECT NOW()");  // hang #2: DB never answers the query
    db.release();                                   // skipped if the query throws -> connection leaked
    ...
  } catch (err) {
    ...
  }
});
```

→ No timeout rules. Test by curl to localhost:8080 when postgres is paused

```text
> docker compose pause postgres; curl.exe -s -o NUL -w "%{http_code} after %{time_total}s\n" http://localhost:8080/api/users; docker compose unpause postgres
504 after 60.002646s
```

→ Confirmed. 60s is nginx's default `proxy_read_timeout`; the API never gave up by itself.
→ Fix: add connection timeout, query timeout, use pool.query() instead of db.query because pool.query() handles the release itself.

```diff
 const pool = new Pool({
   ...
+  connectionTimeoutMillis: 2000,
+  query_timeout: 5000,
 });

-    const db = await pool.connect();
-    const result = await db.query("SELECT NOW()");
-    db.release();
+    const result = await pool.query("SELECT NOW()");
```

```text
#  no open connection
> docker compose pause postgres; curl.exe ... ; docker compose unpause postgres
{"ok":false,"error":"Connection terminated due to connection timeout"}  500 after 2.03s

#  request first, so a connection is reused
> curl.exe ... ; docker compose pause postgres; curl.exe ... ; docker compose unpause postgres; curl.exe ...
{"ok":false,"error":"Query read timeout"}  500 after 5.02s
{"ok":true,...}  200
```

→ recovers by itself.

## 5. What if Redis is down?


```text
> docker compose stop redis; curl.exe -s -w " %{http_code} after %{time_total}s\n" http://localhost:8080/api/users; docker compose start redis
{"ok":false,"error":"Reached the max retries per request limit (which is 20)..."} 500 after 56.58s
```

→ got 500 response after 57s

```text
> cat .\api\src\index.js | sls "redis"

const Redis = require("ioredis");
const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379 });
    await redis.set("last_call", Date.now());
```

→ No handling for Redis failing: the response waits on `redis.set`, so one Redis error fails the whole request (after 20 default retries). Add it:

```diff
-const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379 });
+const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379, maxRetriesPerRequest: 1 });
+redis.on("error", (err) => console.error("Redis error:", err.message));

-    await redis.set("last_call", Date.now());
+    redis.set("last_call", Date.now()).catch((err) => {
+      console.error("Redis write failed:", err.message);
+    });
```

```text
> docker compose stop redis; curl.exe ... ; docker compose start redis
{"ok":true,...}  200 after 0.03s
api-1  | Redis write failed: Reached the max retries per request limit (which is 1)...
```

## 6. Monitoring

→ expose Postgres down, Redis down, long-running queries as api

```js
app.get("/api/health", async (req, res) => {
  const [postgres, redisCheck, slow] = await Promise.all([
    check(() => pool.query("SELECT 1")),       // Postgres up?
    check(() => redis.ping()),                 // Redis up?
    check(() =>                                // queries running > 5s?
      pool.query(
        "SELECT count(*)::int AS n FROM pg_stat_activity " +
          "WHERE state = 'active' AND now() - query_start > interval '5 seconds'"
      )
    ),
  ]);

  const slowQueries = slow.ok ? slow.result.rows[0].n : null;
  const status = !postgres.ok ? "down" : !redisCheck.ok || slowQueries > 0 ? "degraded" : "ok";
  res.status(status === "down" ? 503 : 200).json({ status, postgres, redis: redisCheck, slowQueries }); // simplified
});
// check() = run with a 1s timeout, so the health check itself can't hang
```

| Status | When | HTTP |
|---|---|---|
| `ok` | All fine | 200 |
| `degraded` | Redis down or slow queries (users still served) | 200 |
| `down` | Postgres down | 503 |

All up:

```text
> curl.exe http://localhost:8080/api/health
{"status":"ok","postgres":{"ok":true,"ms":1},"redis":{"ok":true,"ms":1},"slowQueries":0}
```

Slow query (terminal 2 runs a 12s query):

```text
> docker compose exec postgres psql -U postgres -c "SELECT pg_sleep(12)"
```

```text
> curl.exe http://localhost:8080/api/health
{"status":"degraded","postgres":{"ok":true,"ms":28},"redis":{"ok":true,"ms":1},"slowQueries":1}
```

Redis down:

```text
> docker compose stop redis
> curl.exe http://localhost:8080/api/health
{"status":"degraded","postgres":{"ok":true,"ms":1},"redis":{"ok":false,"error":"timeout"},"slowQueries":0}
> docker compose start redis
```

Postgres down:

```text
> docker compose pause postgres
> curl.exe http://localhost:8080/api/health
{"status":"down","postgres":{"ok":false,"error":"timeout"},"redis":{"ok":true,"ms":5},"slowQueries":null}
> docker compose unpause postgres
```
