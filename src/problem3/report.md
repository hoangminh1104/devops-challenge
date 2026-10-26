# Problem 3 — Investigation Report

The first problem was that nginx was forwarding requests to the wrong API port, so users couldn't reach the API at all. After fixing that, I found that Postgres and Redis failures could also crash the API or leave requests waiting. I fixed five issues, repeated the failure tests to check the changes, and added a health endpoint to make these problems easier to spot.

| # | Problem | Before | After |
|---|---|---|---|
| 1 | Homepage downloads as a file | `application/octet-stream` | `text/plain` |
| 2 | nginx uses the wrong API port | 502 response | 200 response |
| 3 | API crashes when Postgres restarts | API exits with code 1 | API stays running |
| 4 | Database requests have no timeout | 504 after 60 seconds | 500 after 2 seconds for a connection timeout, or 5 seconds for a query timeout |
| 5 | Redis failure blocks the request | 500 after about 57 seconds | 200 after 0.03 seconds |
| 6 | No dependency health endpoint | No single place to check | `/api/health` reports `ok`, `degraded`, or `down` |

---

## 1. Homepage downloads as a file

When I opened http://localhost:8080, the browser downloaded the response instead of displaying the welcome message. I checked the response headers and found that it was being served as `application/octet-stream`.

```text
> curl.exe -i http://localhost:8080/
HTTP/1.1 200 OK
Server: nginx/1.25.5
Content-Type: application/octet-stream

Welcome to the platform
```

The response comes directly from nginx's `return` directive rather than a file with an extension. nginx was using its default content type, `application/octet-stream`, so I set the type to `text/plain` for this location.

```diff
 location = / {
+    default_type text/plain;
     return 200 "Welcome to the platform\n";
 }
```

## 2. API returns 502

The API endpoint returned 502 even though all four containers were running. I checked nginx's logs to see why it couldn't reach the API.

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

The response came from nginx. Its logs showed a refused connection to the upstream API on port 3001:

```text
> docker compose logs --tail=50 nginx
[error] connect() failed (111: Connection refused) while connecting to upstream,
upstream: "http://172.23.0.4:3001/api/users"

> cat .\nginx\conf.d\default.conf
    proxy_pass http://api:3001;
> cat .\api\src\index.js
app.listen(3000, () => console.log("API running on 3000"));
```

The nginx configuration used port 3001, but the application was listening on port 3000. I updated `proxy_pass` to match the application.

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

After checking and reloading the nginx configuration, the same request returned 200.

I'm not sure whether the port mismatch was intentional. The exercise says, "Users are reporting that the API is unreliable and sometimes inaccessible," which suggests it works at least some of the time. The port mismatch would prevent all requests from reaching the API, so I kept investigating the intermittent failures.

## 3. API dies when Postgres restarts

Requests reach nginx on port 8080, which forwards them to the API on port 3000. Each `/api/users` request runs `SELECT NOW()` against Postgres on port 5432 and writes a `last_call` timestamp to Redis on port 6379.

I started with the Postgres connection handling:

```js
const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
});
// No pool.on("error") handler for errors on idle connections.

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

The `try/catch` handles errors during a request, but an idle connection can fail between requests too. There was no error listener on the pool to handle that.

I suspected that a Postgres restart would close an idle connection, causing the pool to emit an unhandled `error` event and stop the Node process. To test this, I made a request to leave a connection idle in the pool, then restarted Postgres before the connection's roughly 10-second idle timeout.

```text
> curl.exe -s http://localhost:8080/api/users; docker compose restart postgres
{"ok":true,...}
 Container problem3-postgres-1 Restarting

> docker compose ps
problem3-nginx-1      Up 2 hours
problem3-postgres-1   Up 20 seconds
problem3-redis-1      Up 2 hours

> curl.exe -i http://localhost:8080/api/users
HTTP/1.1 502 Bad Gateway

> docker compose ps -a api; docker compose logs api | Select-String -Pattern "terminating|Emitted 'error'" -Context 0,1
problem3-api-1   Exited (1) 3 minutes ago
> error: terminating connection due to administrator command
> Emitted 'error' event on BoundPool instance at:
    at Client.idleListener (/app/node_modules/pg-pool/index.js:62:10)
```

Postgres came back, but the API was missing from the running containers. It had exited with code 1, and the logs showed the unhandled pool error. There was also no restart policy to bring it back. This explains one intermittent failure: a database restart could stop the API if a recent request had left an idle connection in the pool.

I added a pool error handler and a restart policy for the API container:

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

When I repeated the test, the API logged the idle connection error and stayed running. Once Postgres was available again, requests returned 200. The restart policy provides a fallback if the process exits for another reason. I would alert on unexpected container restarts; alert delivery is not configured in this local stack.

## 4. Requests time out when Postgres stops responding

Next, I checked what happened if Postgres stayed connected but stopped responding. The API had no connection or query timeouts, and a failed query could skip `db.release()`.

```js
const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
  // No connectionTimeoutMillis to limit the connection wait.
  // No query_timeout to limit the query wait.
});

app.get("/api/users", async (req, res) => {
  try {
    const db = await pool.connect();                // hang #1: DB never finishes the handshake
    const result = await db.query("SELECT NOW()");  // hang #2: DB never answers the query
    db.release();                                   // skipped if the query throws, leaving the connection checked out
    ...
  } catch (err) {
    ...
  }
});
```

I paused Postgres and sent a request through nginx to see how long it would wait.

```text
> docker compose pause postgres; curl.exe -s -o NUL -w "%{http_code} after %{time_total}s\n" http://localhost:8080/api/users; docker compose unpause postgres
504 after 60.002646s
```

The request returned 504 after 60 seconds, matching nginx's default `proxy_read_timeout`. The API hadn't timed out the database operation itself.

I added a 2-second connection timeout and a 5-second query timeout. I also switched to `pool.query()`, which handles releasing the connection without a separate `db.release()` call.

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

With the changes in place, a new connection attempt failed after about 2 seconds, and a query on a reused connection failed after about 5 seconds. After I unpaused Postgres, the next request succeeded without restarting the API.

## 5. What if Redis is down?

I then stopped Redis and sent another request to see whether the API could still respond.

```text
> docker compose stop redis; curl.exe -s -w " %{http_code} after %{time_total}s\n" http://localhost:8080/api/users; docker compose start redis
{"ok":false,"error":"Reached the max retries per request limit (which is 20)..."} 500 after 56.58s
```

The request eventually returned 500, but only after waiting almost 57 seconds. I checked where Redis was used in the request handler:

```text
> cat .\api\src\index.js | sls "redis"

const Redis = require("ioredis");
const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379 });
    await redis.set("last_call", Date.now());
```

The handler waited for `redis.set()` before sending the response. With Redis unavailable, the write went through the default 20 retries and then failed the entire request.

Since this write only records the last-call timestamp, I made it a background operation and logged any failure. I also reduced `maxRetriesPerRequest` to 1 and added a Redis error listener.

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

Repeating the test with Redis stopped returned 200 in 0.03 seconds. The failed timestamp write was logged, but it no longer blocked the response.

## 6. Monitoring

I added `/api/health` so monitoring can check Postgres, Redis, and queries running for more than 5 seconds. The checks run in parallel, each with a 1-second timeout so an unresponsive dependency doesn't leave the health request waiting.

This is a simplified version of the handler:

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
| `ok` | Both dependencies respond and no slow queries are found | 200 |
| `degraded` | Redis is unavailable or slow queries are found; the API can still serve requests | 200 |
| `down` | Postgres is unavailable | 503 |

With both dependencies available, the endpoint reported `ok`:

```text
> curl.exe http://localhost:8080/api/health
{"status":"ok","postgres":{"ok":true,"ms":1},"redis":{"ok":true,"ms":1},"slowQueries":0}
```

To check slow-query detection, I ran a 12-second query in a second terminal:

```text
> docker compose exec postgres psql -U postgres -c "SELECT pg_sleep(12)"
```

While that query had been running for more than 5 seconds, the health endpoint reported `degraded` and counted one slow query:

```text
> curl.exe http://localhost:8080/api/health
{"status":"degraded","postgres":{"ok":true,"ms":28},"redis":{"ok":true,"ms":1},"slowQueries":1}
```

With Redis stopped, the endpoint reported `degraded` and showed that the Redis check had timed out:

```text
> docker compose stop redis
> curl.exe http://localhost:8080/api/health
{"status":"degraded","postgres":{"ok":true,"ms":1},"redis":{"ok":false,"error":"timeout"},"slowQueries":0}
> docker compose start redis
```

With Postgres paused, the endpoint reported `down`. As shown in the handler above, that status returns HTTP 503:

```text
> docker compose pause postgres
> curl.exe http://localhost:8080/api/health
{"status":"down","postgres":{"ok":false,"error":"timeout"},"redis":{"ok":true,"ms":5},"slowQueries":null}
> docker compose unpause postgres
```

## Monitoring and prevention in production

I would alert on failed external API checks, increased 5xx/latency, unexpected restarts, database connection pressure and sustained dependency failures. The health endpoint provides a signal; a monitoring service and notification destination still need configuration.

Before release, I would repeat the dependency restart/outage checks in an isolated environment, keep connection/query timeouts bounded, and verify startup readiness. Production also needs managed credentials, database backup/restore checks and reviewed network exposure. These are recommendations, not controls demonstrated by this local investigation.
