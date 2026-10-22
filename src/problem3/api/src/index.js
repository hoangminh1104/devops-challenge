const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();

const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
  connectionTimeoutMillis: 2000,
  query_timeout: 5000,
});

pool.on("error", (err) => {
  console.error("Postgres idle client error:", err.message);
});

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: 6379,
  maxRetriesPerRequest: 1,
});

redis.on("error", (err) => {
  console.error("Redis error:", err.message);
});

app.get("/api/users", async (req, res) => {
  try {
    const result = await pool.query("SELECT NOW()");

    redis.set("last_call", Date.now()).catch((err) => {
      console.error("Redis write failed:", err.message);
    });

    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error(err);
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

const withTimeout = (promise, ms) => {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("timeout")), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
};

const check = async (fn) => {
  const start = Date.now();
  try {
    const result = await withTimeout(fn(), 1000);
    return { ok: true, ms: Date.now() - start, result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
};

app.get("/api/health", async (req, res) => {
  const [postgres, redisCheck, slow] = await Promise.all([
    check(() => pool.query("SELECT 1")),
    check(() => redis.ping()),
    check(() =>
      pool.query(
        "SELECT count(*)::int AS n FROM pg_stat_activity " +
          "WHERE state = 'active' AND now() - query_start > interval '5 seconds'"
      )
    ),
  ]);

  const slowQueries = slow.ok ? slow.result.rows[0].n : null;
  const status = !postgres.ok ? "down" : !redisCheck.ok || slowQueries > 0 ? "degraded" : "ok";

  res.status(status === "down" ? 503 : 200).json({
    status,
    postgres: { ok: postgres.ok, ms: postgres.ms, error: postgres.error },
    redis: { ok: redisCheck.ok, ms: redisCheck.ms, error: redisCheck.error },
    slowQueries,
  });
});

app.listen(3000, () => console.log("API running on 3000"));
