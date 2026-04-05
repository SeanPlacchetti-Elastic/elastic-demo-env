import asyncio
import logging
import os
import random
from datetime import datetime, timezone

import ecs_logging
from elasticapm.contrib.starlette import ElasticAPM, make_apm_client
from fastapi import FastAPI

# ── ECS-formatted structured logging to stdout ────────────────────────────────
_handler = logging.StreamHandler()
_handler.setFormatter(ecs_logging.StdlibFormatter())
logging.getLogger().handlers = []
logging.getLogger().addHandler(_handler)
logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger("east.analytics")

# ── APM ───────────────────────────────────────────────────────────────────────
try:
    apm = make_apm_client({
        "SERVICE_NAME": "east-analytics",
        "SECRET_TOKEN": os.environ.get("ELASTIC_APM_SECRET_TOKEN", ""),
        "SERVER_URL": os.environ.get("ELASTIC_APM_SERVER_URL", "http://east-apm-server:8200"),
        "ENVIRONMENT": os.environ.get("ELASTIC_APM_ENVIRONMENT", "production"),
    })
except Exception as e:
    logger.error("Failed to create APM client", extra={"error.message": str(e)})
    apm = None

app = FastAPI(title="East Analytics Service")
if apm:
    app.add_middleware(ElasticAPM, client=apm)

logger.info("Analytics service started")


@app.get("/health")
async def health():
    return {"status": "ok", "service": "east-analytics"}


@app.get("/metrics")
async def get_metrics():
    delay = random.uniform(0.01, 0.06)
    await asyncio.sleep(delay)
    metrics = {
        "active_users":       random.randint(120, 4800),
        "requests_per_second": round(random.uniform(45, 480), 1),
        "error_rate":          round(random.uniform(0.001, 0.04), 4),
        "p50_latency_ms":      random.randint(8, 60),
        "p99_latency_ms":      random.randint(80, 450),
        "cache_hit_rate":      round(random.uniform(0.72, 0.98), 3),
        "timestamp":           datetime.now(timezone.utc).isoformat(),
    }
    logger.info(
        "Metrics snapshot generated",
        extra={
            "active_users":        metrics["active_users"],
            "requests_per_second": metrics["requests_per_second"],
            "error_rate":          metrics["error_rate"],
        },
    )
    return metrics


@app.get("/report")
async def get_report():
    # Report generation is heavier — shows up as a slower span in APM
    delay = random.uniform(0.12, 0.40)
    if random.random() < 0.1:
        delay = random.uniform(0.5, 1.2)
        logger.warning(
            "Report generation slow",
            extra={"generation_time_ms": round(delay * 1000), "event.action": "slow-report"},
        )
    await asyncio.sleep(delay)
    report = {
        "period": "last_24h",
        "total_requests": random.randint(15000, 480000),
        "unique_users":   random.randint(800, 45000),
        "top_endpoints": [
            {"path": "/products",  "hits": random.randint(1000, 12000), "avg_ms": random.randint(20, 120)},
            {"path": "/checkout",  "hits": random.randint(400,  5000),  "avg_ms": random.randint(80, 300)},
            {"path": "/search",    "hits": random.randint(2000, 18000), "avg_ms": random.randint(15,  90)},
        ],
        "generated_at":   datetime.now(timezone.utc).isoformat(),
        "generation_ms":  round(delay * 1000),
    }
    logger.info(
        "Report generated",
        extra={
            "period":           report["period"],
            "total_requests":   report["total_requests"],
            "generation_ms":    report["generation_ms"],
        },
    )
    return report
