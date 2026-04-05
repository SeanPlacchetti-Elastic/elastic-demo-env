use axum::{http::StatusCode, routing::get, Json, Router};
use opentelemetry::{global, KeyValue};
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{
    propagation::TraceContextPropagator,
    trace::{self, RandomIdGenerator, Sampler},
    Resource,
};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::OnceLock;
use tracing::{error, info, warn};
use tracing_subscriber::{layer::SubscriberExt, Registry};

static CATALOG_URL: OnceLock<String> = OnceLock::new();
static REVIEWS_URL: OnceLock<String> = OnceLock::new();

const SERVICE: &str = "east-recommendations";

#[tokio::main]
async fn main() {
    global::set_text_map_propagator(TraceContextPropagator::new());

    let tracer_opt = init_tracer();

    let json_layer = tracing_subscriber::fmt::layer()
        .json()
        .with_current_span(false)
        .with_target(false);

    match tracer_opt {
        Some(tracer) => {
            let subscriber = Registry::default()
                .with(json_layer)
                .with(tracing_opentelemetry::layer().with_tracer(tracer));
            tracing::subscriber::set_global_default(subscriber).ok();
        }
        None => {
            let subscriber = Registry::default().with(json_layer);
            tracing::subscriber::set_global_default(subscriber).ok();
        }
    }

    CATALOG_URL.set(
        std::env::var("CATALOG_URL").unwrap_or_else(|_| "http://east-catalog:8000".to_string()),
    ).ok();
    REVIEWS_URL.set(
        std::env::var("REVIEWS_URL").unwrap_or_else(|_| "http://east-reviews:8000".to_string()),
    ).ok();

    info!(service = SERVICE, "Recommendations service started");
    info!(catalog_url = %CATALOG_URL.get().unwrap(), reviews_url = %REVIEWS_URL.get().unwrap(), "Downstream service URLs configured");

    let app = Router::new()
        .route("/health", get(health))
        .route("/recommendations", get(recommendations));

    let addr = SocketAddr::from(([0, 0, 0, 0], 8000));
    info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();

    global::shutdown_tracer_provider();
}

fn init_tracer() -> Option<opentelemetry_sdk::trace::Tracer> {
    let endpoint = std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT").ok()?;
    if endpoint.is_empty() {
        return None;
    }

    let env = std::env::var("ELASTIC_APM_ENVIRONMENT")
        .unwrap_or_else(|_| "production".to_string());

    let tracer = opentelemetry_otlp::new_pipeline()
        .tracing()
        .with_exporter(
            opentelemetry_otlp::new_exporter()
                .http()
                .with_endpoint(&endpoint),
        )
        .with_trace_config(
            trace::config()
                .with_sampler(Sampler::AlwaysOn)
                .with_id_generator(RandomIdGenerator::default())
                .with_resource(Resource::new(vec![
                    KeyValue::new("service.name", SERVICE),
                    KeyValue::new("deployment.environment", env),
                ])),
        )
        .install_batch(opentelemetry_sdk::runtime::Tokio)
        .ok()?;

    Some(tracer)
}

fn is_degraded() -> bool {
    if std::env::var("ANOMALY_ENABLED").unwrap_or_default() != "true" { return false; }
    let cycle_pos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        % 600;
    (480..=510).contains(&cycle_pos)
}

async fn health() -> Json<Value> {
    Json(json!({"status": "ok", "service": SERVICE}))
}

async fn recommendations() -> (StatusCode, Json<Value>) {
    if is_degraded() {
        let roll = rand::random::<f64>();

        if roll < 0.10 {
            // 10% return error response
            tracing::error!(scenario = "degraded", event.action = "model-timeout", "Recommendation model timeout");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"error": "recommendation model timeout — inference engine overloaded"})),
            );
        }

        if roll < 0.65 {
            // 55% high latency (600-2000ms)
            let high_delay_ms = (rand::random::<u64>() % 1401) + 600;
            tokio::time::sleep(tokio::time::Duration::from_millis(high_delay_ms)).await;
            warn!(query_time_ms = high_delay_ms, scenario = "degraded", "High latency recommendation computation");
        } else {
            // remaining 35% normal latency during degraded window
            let delay_ms = (rand::random::<u64>() % 70) + 10;
            tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
            info!(count = 6u32, query_time_ms = delay_ms, "Recommendations served");
        }
    } else {
        // Normal mode
        let delay_ms = (rand::random::<u64>() % 70) + 10;
        tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;

        if rand::random::<f64>() < 0.12 {
            warn!(query_time_ms = delay_ms + 220, "Slow recommendation computation");
        } else {
            info!(count = 6u32, query_time_ms = delay_ms, "Recommendations served");
        }
    }

    let mut recs = vec![
        json!({"product_id": 2, "name": "Kibana Dashboard Pro",   "score": 0.97, "reason": "frequently bought with Elasticsearch Node"}),
        json!({"product_id": 6, "name": "Synthetic Monitor Pack", "score": 0.91, "reason": "commonly paired with APM Server Token"}),
        json!({"product_id": 5, "name": "Fleet Server License",   "score": 0.88, "reason": "required for managed agent deployments"}),
        json!({"product_id": 3, "name": "Logstash Enterprise",    "score": 0.82, "reason": "popular data pipeline addition"}),
        json!({"product_id": 4, "name": "APM Server Token",       "score": 0.79, "reason": "enables full observability stack"}),
        json!({"product_id": 1, "name": "Elasticsearch Node",     "score": 0.75, "reason": "scale your cluster"}),
    ];

    // Enrich recommendations with catalog and review data
    let catalog_url = CATALOG_URL.get().unwrap();
    let reviews_url = REVIEWS_URL.get().unwrap();
    let client = reqwest::Client::new();

    let catalog_endpoint = format!("{}/products", catalog_url);
    let reviews_endpoint = format!("{}/reviews", reviews_url);
    info!(url = %catalog_endpoint, "Calling catalog service");
    info!(url = %reviews_endpoint, "Calling reviews service");

    let (catalog_res, reviews_res) = tokio::join!(
        client.get(&catalog_endpoint).send(),
        client.get(&reviews_endpoint).send(),
    );

    // Parse catalog products into a map of product_id -> category
    let catalog_map: Option<std::collections::HashMap<u64, String>> = match catalog_res {
        Ok(r) if r.status().is_success() => {
            match r.json::<Value>().await {
                Ok(body) => {
                    body.get("products").and_then(|p| p.as_array()).map(|products| {
                        let map: std::collections::HashMap<u64, String> = products
                            .iter()
                            .filter_map(|p| {
                                let id = p.get("id")?.as_u64()?;
                                let category = p.get("category")?.as_str()?.to_string();
                                Some((id, category))
                            })
                            .collect();
                        info!(count = map.len(), "Catalog products fetched");
                        map
                    })
                }
                Err(e) => {
                    warn!(error = %e, "Failed to parse catalog response");
                    None
                }
            }
        }
        Ok(r) => {
            warn!(status = %r.status(), "Catalog service returned non-success status");
            None
        }
        Err(e) => {
            warn!(error = %e, "Failed to call catalog service");
            None
        }
    };

    // Parse reviews into a map of product_id -> avg_rating
    let reviews_map: Option<std::collections::HashMap<u64, f64>> = match reviews_res {
        Ok(r) if r.status().is_success() => {
            match r.json::<Value>().await {
                Ok(body) => {
                    body.get("reviews").and_then(|r| r.as_array()).map(|reviews| {
                        let mut totals: std::collections::HashMap<u64, (f64, u64)> = std::collections::HashMap::new();
                        for review in reviews {
                            if let (Some(pid), Some(rating)) = (
                                review.get("product_id").and_then(|v| v.as_u64()),
                                review.get("rating").and_then(|v| v.as_f64()),
                            ) {
                                let entry = totals.entry(pid).or_insert((0.0, 0));
                                entry.0 += rating;
                                entry.1 += 1;
                            }
                        }
                        let map: std::collections::HashMap<u64, f64> = totals
                            .into_iter()
                            .map(|(pid, (sum, count))| (pid, sum / count as f64))
                            .collect();
                        info!(count = map.len(), "Review ratings fetched");
                        map
                    })
                }
                Err(e) => {
                    warn!(error = %e, "Failed to parse reviews response");
                    None
                }
            }
        }
        Ok(r) => {
            warn!(status = %r.status(), "Reviews service returned non-success status");
            None
        }
        Err(e) => {
            warn!(error = %e, "Failed to call reviews service");
            None
        }
    };

    // Enrich each recommendation
    for rec in recs.iter_mut() {
        if let Some(pid) = rec.get("product_id").and_then(|v| v.as_u64()) {
            if let Some(ref cmap) = catalog_map {
                if let Some(category) = cmap.get(&pid) {
                    rec.as_object_mut().unwrap().insert("category".to_string(), json!(category));
                }
            }
            if let Some(ref rmap) = reviews_map {
                if let Some(avg_rating) = rmap.get(&pid) {
                    rec.as_object_mut().unwrap().insert("avg_rating".to_string(), json!(avg_rating));
                }
            }
        }
    }

    (StatusCode::OK, Json(json!({
        "recommendations": recs,
        "count": 6
    })))
}
