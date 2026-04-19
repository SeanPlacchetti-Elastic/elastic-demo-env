import logging
import os
import time

import ecs_logging
import httpx
from elasticsearch import Elasticsearch
from elasticapm.contrib.starlette import ElasticAPM, make_apm_client
from fastapi import FastAPI, Query, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

# ── ECS-formatted structured logging to stdout ────────────────────────────────
_handler = logging.StreamHandler()
_handler.setFormatter(ecs_logging.StdlibFormatter())
logging.getLogger().handlers = []
logging.getLogger().addHandler(_handler)
logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger("east.gateway")

# ── Downstream service URLs ───────────────────────────────────────────────────
CATALOG_URL         = os.environ.get("CATALOG_URL",         "http://east-catalog:8000")
INVENTORY_URL       = os.environ.get("INVENTORY_URL",       "http://east-inventory:8000")
PRICING_URL         = os.environ.get("PRICING_URL",         "http://east-pricing:8000")
REVIEWS_URL         = os.environ.get("REVIEWS_URL",         "http://east-reviews:8000")
ORDERS_URL          = os.environ.get("ORDERS_URL",          "http://east-orders:8000")
RECOMMENDATIONS_URL = os.environ.get("RECOMMENDATIONS_URL", "http://east-recommendations:8000")

# ── Search cluster client ─────────────────────────────────────────────────────
SEARCH_ES_URL = os.environ.get("SEARCH_ES_URL", "https://search-es01:9200")
SEARCH_ES_PASSWORD = os.environ.get("SEARCH_ES_PASSWORD", "changeme")
SEARCH_ES_CA = os.environ.get("SEARCH_ES_CA", "/app/certs/ca/ca.crt")
try:
    es = Elasticsearch(
        SEARCH_ES_URL,
        basic_auth=("elastic", SEARCH_ES_PASSWORD),
        ca_certs=SEARCH_ES_CA,
        request_timeout=5,
    )
except Exception as e:
    es = None
    logging.getLogger("east.gateway").error("Failed to create search client: %s", e)

# ── APM ───────────────────────────────────────────────────────────────────────
try:
    apm = make_apm_client({
        "SERVICE_NAME": "east-gateway",
        "SECRET_TOKEN": os.environ.get("ELASTIC_APM_SECRET_TOKEN", ""),
        "SERVER_URL":   os.environ.get("ELASTIC_APM_SERVER_URL", "http://east-apm-server:8200"),
        "ENVIRONMENT":  os.environ.get("ELASTIC_APM_ENVIRONMENT", "production"),
    })
except Exception as e:
    logger.error("Failed to create APM client", extra={"error.message": str(e)})
    apm = None

app = FastAPI(title="East Gateway")
if apm:
    app.add_middleware(ElasticAPM, client=apm)

templates = Jinja2Templates(directory="templates")

logger.info("Gateway started", extra={
    "catalog_url":         CATALOG_URL,
    "inventory_url":       INVENTORY_URL,
    "pricing_url":         PRICING_URL,
    "reviews_url":         REVIEWS_URL,
    "orders_url":          ORDERS_URL,
    "recommendations_url": RECOMMENDATIONS_URL,
})

# ── UI ────────────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {
        "request":              request,
        "service_name":         "east-gateway",
        "environment":          os.environ.get("ELASTIC_APM_ENVIRONMENT", "production"),
        "rum_server_url":       os.environ.get("RUM_SERVER_URL", "http://localhost:8201"),
        "catalog_url":          CATALOG_URL,
        "inventory_url":        INVENTORY_URL,
        "pricing_url":          PRICING_URL,
        "reviews_url":          REVIEWS_URL,
        "orders_url":           ORDERS_URL,
        "recommendations_url":  RECOMMENDATIONS_URL,
        "search_es_url":        SEARCH_ES_URL,
    })

# ── Proxy endpoints (called by the browser) ───────────────────────────────────

async def _proxy(url: str, svc: str) -> dict:
    """Call a downstream service; APM agent propagates traceparent automatically."""
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=6.0) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            data = resp.json()
    except httpx.TimeoutException:
        logger.error("Downstream timeout", extra={"upstream": svc})
        return {"error": f"{svc} timed out"}
    except Exception as e:
        logger.error("Downstream error", extra={"upstream": svc, "error.message": str(e)})
        return {"error": str(e)}
    elapsed = round((time.perf_counter() - t0) * 1000)
    logger.info("Proxied request", extra={"upstream": svc, "duration_ms": elapsed})
    return data


@app.get("/catalog")
async def browse_catalog():
    return await _proxy(f"{CATALOG_URL}/products", "east-catalog")


@app.get("/inventory")
async def get_inventory():
    return await _proxy(f"{INVENTORY_URL}/stock", "east-inventory")


@app.get("/pricing")
async def get_pricing():
    return await _proxy(f"{PRICING_URL}/prices", "east-pricing")


@app.get("/reviews")
async def get_reviews():
    return await _proxy(f"{REVIEWS_URL}/reviews", "east-reviews")


@app.get("/orders")
async def get_orders():
    return await _proxy(f"{ORDERS_URL}/orders", "east-orders")


@app.get("/recommendations")
async def get_recommendations():
    return await _proxy(f"{RECOMMENDATIONS_URL}/recommendations", "east-recommendations")


# ── Search endpoints (backed by search-es01) ─────────────────────────────────

@app.get("/search")
async def search(q: str = Query("", min_length=0)):
    """Standard lexical search using match query across name + description."""
    if not es or not q:
        return {"results": [], "count": 0, "query": q, "type": "lexical"}
    t0 = time.perf_counter()
    resp = es.search(index="aircraft", query={
        "multi_match": {
            "query": q,
            "fields": ["name^3", "description", "tags^2", "category"],
            "fuzziness": "AUTO",
        }
    }, size=10)
    hits = [{"_id": h["_id"], **h["_source"], "_score": h["_score"]}
            for h in resp["hits"]["hits"]]
    elapsed = round((time.perf_counter() - t0) * 1000)
    logger.info("Lexical search", extra={"query": q, "hits": len(hits), "duration_ms": elapsed})
    return {"results": hits, "count": len(hits), "query": q, "type": "lexical", "took_ms": elapsed}


@app.get("/search/typeahead")
async def typeahead(q: str = Query("", min_length=0)):
    """Completion suggester for typeahead / autocomplete dropdown."""
    if not es or not q:
        return {"suggestions": [], "query": q, "type": "completion"}
    t0 = time.perf_counter()
    resp = es.search(index="aircraft", suggest={
        "aircraft-suggest": {
            "prefix": q,
            "completion": {
                "field": "suggest",
                "size": 5,
                "skip_duplicates": True,
                "fuzzy": {"fuzziness": "AUTO"},
            }
        }
    })
    options = resp.get("suggest", {}).get("aircraft-suggest", [{}])[0].get("options", [])
    suggestions = [{"text": o["text"], "_id": o["_id"], "name": o["_source"]["name"],
                     "category": o["_source"].get("category", ""), "_score": o["_score"]}
                    for o in options]
    elapsed = round((time.perf_counter() - t0) * 1000)
    logger.info("Typeahead suggest", extra={"query": q, "suggestions": len(suggestions), "duration_ms": elapsed})
    return {"suggestions": suggestions, "query": q, "type": "completion", "took_ms": elapsed}


@app.get("/search/asyoutype")
async def search_as_you_type(q: str = Query("", min_length=0)):
    """Search-as-you-type using the search_as_you_type field mapping."""
    if not es or not q:
        return {"results": [], "count": 0, "query": q, "type": "search_as_you_type"}
    t0 = time.perf_counter()
    resp = es.search(index="aircraft", query={
        "multi_match": {
            "query": q,
            "type": "bool_prefix",
            "fields": [
                "name.search_as_you_type",
                "name.search_as_you_type._2gram",
                "name.search_as_you_type._3gram",
            ]
        }
    }, size=10)
    hits = [{"_id": h["_id"], **h["_source"], "_score": h["_score"]}
            for h in resp["hits"]["hits"]]
    elapsed = round((time.perf_counter() - t0) * 1000)
    logger.info("Search-as-you-type", extra={"query": q, "hits": len(hits), "duration_ms": elapsed})
    return {"results": hits, "count": len(hits), "query": q, "type": "search_as_you_type", "took_ms": elapsed}


@app.get("/search/template")
async def smart_search(q: str = Query("", min_length=0)):
    """Stored search template spanning aircraft, missions, airbases, and crews."""
    if not es or not q:
        return {"results": [], "count": 0, "query": q, "type": "template"}
    t0 = time.perf_counter()
    resp = es.search_template(
        index="aircraft,missions,airbases,crews",
        body={"id": "usaf-smart-search", "params": {"query": q, "size": 12}},
    )
    hits = []
    for h in resp["hits"]["hits"]:
        result = {"_id": h["_id"], "_index": h["_index"], "_score": h["_score"], **h["_source"]}
        if "highlight" in h:
            result["_highlight"] = h["highlight"]
        hits.append(result)
    elapsed = round((time.perf_counter() - t0) * 1000)
    logger.info("Smart template search", extra={"query": q, "hits": len(hits), "duration_ms": elapsed})
    return {"results": hits, "count": len(hits), "query": q, "type": "template", "took_ms": elapsed}


@app.get("/error")
async def throw_error():
    try:
        1 / 0
    except Exception:
        if apm:
            apm.capture_exception()
    logger.warning("Error endpoint triggered", extra={"event.action": "synthetic-error"})
    return {"message": "Failed Successfully :)"}


@app.get("/custom_message/{message}")
async def custom_message(message: str):
    if apm:
        apm.capture_message(f"Custom Message: {message}")
    logger.info("Custom message captured", extra={"custom_message": message})
    return {"message": f"Custom Message: {message}"}
