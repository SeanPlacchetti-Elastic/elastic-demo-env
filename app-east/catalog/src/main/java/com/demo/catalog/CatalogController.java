package com.demo.catalog;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;

import java.util.*;
import java.util.concurrent.ThreadLocalRandom;

@RestController
public class CatalogController {

    private static final Logger log = LoggerFactory.getLogger(CatalogController.class);

    private final JdbcTemplate jdbc;

    /** Scenario clock cycle length in seconds. */
    private static final long CYCLE_SECONDS = 240;

    /** Degraded window: seconds 168 (minute 2.8) through 204 (minute 3.4). */
    private static final long DEGRADED_START = 168;
    private static final long DEGRADED_END   = 204;

    public CatalogController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    // ── Database bootstrap ──────────────────────────────────────────────

    @PostConstruct
    void initDatabase() {
        jdbc.execute("""
            CREATE TABLE IF NOT EXISTS aircraft (
                id   SERIAL PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                designation VARCHAR(50) NOT NULL,
                category    VARCHAR(20) NOT NULL,
                fleet_count INT NOT NULL,
                fuel_capacity_lbs DOUBLE PRECISION NOT NULL
            )
        """);

        Integer count = jdbc.queryForObject("SELECT COUNT(*) FROM aircraft", Integer.class);
        if (count != null && count == 0) {
            log.info("Seeding aircraft table in PostgreSQL");
            String sql = "INSERT INTO aircraft (name, designation, category, fleet_count, fuel_capacity_lbs) VALUES (?, ?, ?, ?, ?)";
            jdbc.update(sql, "KC-135 Stratotanker",  "TANKER-135",    "tanker",  48, 200000.0);
            jdbc.update(sql, "KC-46A Pegasus",       "TANKER-46A",    "tanker",  15, 212000.0);
            jdbc.update(sql, "KC-10 Extender",       "TANKER-10",     "tanker",   6, 356000.0);
            jdbc.update(sql, "F-16C Fighting Falcon","RECEIVER-F16C", "fighter", 72,   7000.0);
            jdbc.update(sql, "F-15E Strike Eagle",   "RECEIVER-F15E", "fighter", 36,  13455.0);
            jdbc.update(sql, "B-52H Stratofortress", "RECEIVER-B52H", "bomber",  20, 312197.0);
            log.info("Seeded 6 aircraft records into PostgreSQL");
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private List<Map<String, Object>> loadProducts() {
        return jdbc.query("SELECT * FROM aircraft ORDER BY id", (rs, rowNum) -> {
            Map<String, Object> m = new LinkedHashMap<>();
            int id = rs.getInt("id");
            String name = rs.getString("name");
            String designation = rs.getString("designation");
            String category = rs.getString("category");
            int fleetCount = rs.getInt("fleet_count");
            double fuelCapacity = rs.getDouble("fuel_capacity_lbs");
            m.put("id", id);
            m.put("name", name);
            m.put("sku", designation);
            m.put("designation", designation);
            m.put("category", category);
            m.put("role", category);
            m.put("stock", fleetCount);
            m.put("fleet_count", fleetCount);
            m.put("price", fuelCapacity);
            m.put("fuel_capacity_lbs", fuelCapacity);
            return m;
        });
    }

    // ── Scenario clock ──────────────────────────────────────────────────

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
            double roll = rng.nextDouble();

            if (roll < 0.15) {
                int delayMs = rng.nextInt(50, 200);
                Thread.sleep(delayMs);
                log.warn("Aircraft registry database connection pool exhausted; event.action=db-pool-exhaustion "
                         + "scenario=degraded query_time_ms={} http.status_code=503", delayMs);
                return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                    .body(Map.of(
                        "error", "aircraft registry database connection pool exhausted",
                        "event.action", "db-pool-exhaustion",
                        "scenario", "degraded"
                    ));
            }

            if (roll < 0.75) {
                int delayMs = rng.nextInt(400, 1200);
                Thread.sleep(delayMs);
                List<Map<String, Object>> products = loadProducts();
                log.warn("Degraded aircraft listing – elevated latency; scenario=degraded "
                         + "query_time_ms={} aircraft_count={}", delayMs, products.size());
                return ResponseEntity.ok(Map.of("products", products, "count", products.size()));
            }

            int delayMs = rng.nextInt(10, 80);
            Thread.sleep(delayMs);
            List<Map<String, Object>> products = loadProducts();
            log.info("Aircraft listing served; scenario=degraded aircraft_count={} query_time_ms={}",
                     products.size(), delayMs);
            return ResponseEntity.ok(Map.of("products", products, "count", products.size()));

        } else {
            int delayMs = rng.nextInt(10, 80);

            if (rng.nextDouble() < 0.15) {
                delayMs = rng.nextInt(250, 650);
                log.warn("Slow aircraft registry query detected; scenario=normal query_time_ms={}",
                         delayMs);
            }

            Thread.sleep(delayMs);
            List<Map<String, Object>> products = loadProducts();
            log.info("Aircraft listing served; scenario=normal aircraft_count={} query_time_ms={}",
                     products.size(), delayMs);
            return ResponseEntity.ok(Map.of("products", products, "count", products.size()));
        }
    }

    @GetMapping("/products/{id}")
    public ResponseEntity<Object> getProduct(@PathVariable int id) throws InterruptedException {
        Thread.sleep(ThreadLocalRandom.current().nextInt(5, 40));
        List<Map<String, Object>> results = jdbc.query(
            "SELECT * FROM aircraft WHERE id = ?",
            (rs, rowNum) -> {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("id", rs.getInt("id"));
                m.put("name", rs.getString("name"));
                m.put("sku", rs.getString("designation"));
                m.put("designation", rs.getString("designation"));
                m.put("category", rs.getString("category"));
                m.put("role", rs.getString("category"));
                m.put("stock", rs.getInt("fleet_count"));
                m.put("fleet_count", rs.getInt("fleet_count"));
                m.put("price", rs.getDouble("fuel_capacity_lbs"));
                m.put("fuel_capacity_lbs", rs.getDouble("fuel_capacity_lbs"));
                return m;
            },
            id
        );
        if (results.isEmpty()) {
            log.warn("Aircraft not found; aircraft_id={}", id);
            return ResponseEntity.status(404)
                .body(Map.of("error", "Aircraft " + id + " not found"));
        }
        return ResponseEntity.ok(results.get(0));
    }
}
