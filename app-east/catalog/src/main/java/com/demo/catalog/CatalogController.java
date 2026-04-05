package com.demo.catalog;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.*;
import java.util.concurrent.ThreadLocalRandom;

@RestController
public class CatalogController {

    private static final Logger log = LoggerFactory.getLogger(CatalogController.class);

    /** Scenario clock cycle length in seconds. */
    private static final long CYCLE_SECONDS = 600;

    /** Degraded window: seconds 420 (minute 7) through 510 (minute 8.5). */
    private static final long DEGRADED_START = 420;
    private static final long DEGRADED_END   = 510;

    private static final List<Map<String, Object>> PRODUCTS = List.of(
        product(1, "Elasticsearch Node",     "ES-NODE-01",    "infrastructure", 999,  499.00),
        product(2, "Kibana Dashboard Pro",   "KB-DASH-PRO",   "visualization",   50,  299.00),
        product(3, "Logstash Enterprise",    "LS-ENT-01",     "ingest",          12,  199.00),
        product(4, "APM Server Token",       "APM-TOKEN-01",  "observability",    0,   99.00),
        product(5, "Fleet Server License",   "FLEET-LIC-01",  "management",       3,  149.00),
        product(6, "Synthetic Monitor Pack", "SYNTH-PACK-01", "observability",   25,   79.00)
    );

    // ── Scenario clock ──────────────────────────────────────────────────

    /**
     * Returns {@code true} when the 10-minute scenario clock is inside the
     * degraded window (seconds 420-510).
     */
    private boolean isDegraded() {
        if (!"true".equalsIgnoreCase(System.getenv("ANOMALY_ENABLED"))) return false;
        long cyclePosition = (System.currentTimeMillis() / 1000) % CYCLE_SECONDS;
        return cyclePosition >= DEGRADED_START && cyclePosition <= DEGRADED_END;
    }

    // ── Endpoints ───────────────────────────────────────────────────────

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok", "service", "east-catalog", "language", "java");
    }

    @GetMapping("/products")
    public ResponseEntity<Object> listProducts() throws InterruptedException {
        ThreadLocalRandom rng = ThreadLocalRandom.current();

        if (isDegraded()) {
            // ── Degraded mode ───────────────────────────────────────
            double roll = rng.nextDouble();

            if (roll < 0.15) {
                // 15 % of requests: simulated DB connection pool exhaustion
                int delayMs = rng.nextInt(50, 200);
                Thread.sleep(delayMs);
                log.warn("Database connection pool exhausted; event.action=db-pool-exhaustion "
                         + "scenario=degraded query_time_ms={} http.status_code=503", delayMs);
                return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                    .body(Map.of(
                        "error", "database connection pool exhausted",
                        "event.action", "db-pool-exhaustion",
                        "scenario", "degraded"
                    ));
            }

            if (roll < 0.75) {
                // 60 % of requests: slow latency (400-1200 ms)
                int delayMs = rng.nextInt(400, 1200);
                Thread.sleep(delayMs);
                log.warn("Degraded product listing – elevated latency; scenario=degraded "
                         + "query_time_ms={} product_count={}", delayMs, PRODUCTS.size());
                return ResponseEntity.ok(Map.of("products", PRODUCTS, "count", PRODUCTS.size()));
            }

            // Remaining 25 % in degraded mode: normal-ish baseline
            int delayMs = rng.nextInt(10, 80);
            Thread.sleep(delayMs);
            log.info("Product listing served; scenario=degraded product_count={} query_time_ms={}",
                     PRODUCTS.size(), delayMs);
            return ResponseEntity.ok(Map.of("products", PRODUCTS, "count", PRODUCTS.size()));

        } else {
            // ── Normal mode ─────────────────────────────────────────
            int delayMs = rng.nextInt(10, 80);

            if (rng.nextDouble() < 0.15) {
                delayMs = rng.nextInt(250, 650);
                log.warn("Slow product listing query detected; scenario=normal query_time_ms={}",
                         delayMs);
            }

            Thread.sleep(delayMs);
            log.info("Product listing served; scenario=normal product_count={} query_time_ms={}",
                     PRODUCTS.size(), delayMs);
            return ResponseEntity.ok(Map.of("products", PRODUCTS, "count", PRODUCTS.size()));
        }
    }

    @GetMapping("/products/{id}")
    public ResponseEntity<Object> getProduct(@PathVariable int id) throws InterruptedException {
        Thread.sleep(ThreadLocalRandom.current().nextInt(5, 40));
        return PRODUCTS.stream()
            .filter(p -> ((Number) p.get("id")).intValue() == id)
            .findFirst()
            .<ResponseEntity<Object>>map(ResponseEntity::ok)
            .orElseGet(() -> {
                log.warn("Product not found; product_id={}", id);
                return ResponseEntity.status(404)
                    .body(Map.of("error", "Product " + id + " not found"));
            });
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private static Map<String, Object> product(int id, String name, String sku,
                                                String category, int stock, double price) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", id);
        m.put("name", name);
        m.put("sku", sku);
        m.put("category", category);
        m.put("stock", stock);
        m.put("price", price);
        return Collections.unmodifiableMap(m);
    }
}
