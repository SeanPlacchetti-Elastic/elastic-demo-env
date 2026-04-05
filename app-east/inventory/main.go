package main

import (
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"go.elastic.co/apm/module/apmgin/v2"
	"go.elastic.co/ecszap"
	"go.uber.org/zap"
)

type StockItem struct {
	ProductID  int    `json:"product_id"`
	SKU        string `json:"sku"`
	Name       string `json:"name"`
	Warehouse  string `json:"warehouse"`
	Available  int    `json:"available"`
	Reserved   int    `json:"reserved"`
	UpdatedAt  string `json:"updated_at"`
}

var warehouses = []string{"us-east-1", "eu-west-1", "ap-southeast-1"}

var stock = []StockItem{
	{1, "ES-NODE-01",    "Elasticsearch Node",     "us-east-1",     999, 12, ""},
	{2, "KB-DASH-PRO",   "Kibana Dashboard Pro",   "us-east-1",      50,  3, ""},
	{3, "LS-ENT-01",     "Logstash Enterprise",    "eu-west-1",       12,  1, ""},
	{4, "APM-TOKEN-01",  "APM Server Token",       "eu-west-1",        0,  0, ""},
	{5, "FLEET-LIC-01",  "Fleet Server License",   "ap-southeast-1",   3,  0, ""},
	{6, "SYNTH-PACK-01", "Synthetic Monitor Pack", "us-east-1",       25,  2, ""},
}

// isDegraded returns true during seconds 440-510 of a 600-second cycle.
func isDegraded() bool {
	if os.Getenv("ANOMALY_ENABLED") != "true" { return false }
	pos := time.Now().Unix() % 600
	return pos >= 440 && pos <= 510
}

func main() {
	// ── ECS structured logging ─────────────────────────────────────────────
	encoderCfg := ecszap.NewDefaultEncoderConfig()
	core := ecszap.NewCore(encoderCfg, os.Stdout, zap.InfoLevel)
	logger := zap.New(core, zap.AddCaller())
	defer logger.Sync() //nolint:errcheck

	// Stamp each item with a realistic updated_at
	now := time.Now().UTC().Format(time.RFC3339)
	for i := range stock {
		stock[i].UpdatedAt = now
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()

	// ── Elastic APM middleware ─────────────────────────────────────────────
	// Reads ELASTIC_APM_SERVER_URL / ELASTIC_APM_SERVICE_NAME / etc. from env
	r.Use(apmgin.Middleware(r))

	r.GET("/health", func(c *gin.Context) {
		logger.Info("health check")
		c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "east-inventory", "language": "go"})
	})

	r.GET("/stock", func(c *gin.Context) {
		if isDegraded() {
			// ── Degraded mode (seconds 440-510 of cycle) ──────────────────
			wh := warehouses[rand.Intn(len(warehouses))]

			// 10% hard failure — 503
			if rand.Float64() < 0.10 {
				logger.Error("warehouse sync timeout",
					zap.String("warehouse", wh),
					zap.String("event.action", "warehouse-timeout"),
					zap.String("scenario", "degraded"),
				)
				c.JSON(http.StatusServiceUnavailable, gin.H{
					"error": "warehouse sync timeout — cannot verify stock levels",
				})
				return
			}

			// 50% high-latency response
			var delay time.Duration
			if rand.Float64() < 0.50 {
				delay = time.Duration(rand.Intn(1000)+500) * time.Millisecond
				logger.Warn("warehouse sync latency spike",
					zap.String("warehouse", wh),
					zap.Duration("delay_ms", delay),
					zap.String("scenario", "degraded"),
				)
			} else {
				delay = time.Duration(rand.Intn(70)+10) * time.Millisecond
			}

			time.Sleep(delay)
			logger.Info("stock levels returned",
				zap.Int("item_count", len(stock)),
				zap.Duration("query_ms", delay),
			)
			c.JSON(http.StatusOK, gin.H{"stock": stock, "count": len(stock)})
		} else {
			// ── Normal mode ───────────────────────────────────────────────
			delay := time.Duration(rand.Intn(70)+10) * time.Millisecond
			if rand.Float64() < 0.12 {
				delay = time.Duration(rand.Intn(400)+200) * time.Millisecond
				logger.Warn("warehouse sync latency spike",
					zap.String("warehouse", warehouses[rand.Intn(len(warehouses))]),
					zap.Duration("delay_ms", delay),
				)
			}
			time.Sleep(delay)
			logger.Info("stock levels returned",
				zap.Int("item_count", len(stock)),
				zap.Duration("query_ms", delay),
			)
			c.JSON(http.StatusOK, gin.H{"stock": stock, "count": len(stock)})
		}
	})

	r.GET("/stock/:sku", func(c *gin.Context) {
		sku := c.Param("sku")
		for _, item := range stock {
			if item.SKU == sku {
				logger.Info("stock item retrieved", zap.String("sku", sku))
				c.JSON(http.StatusOK, item)
				return
			}
		}
		logger.Warn("stock item not found", zap.String("sku", sku))
		c.JSON(http.StatusNotFound, gin.H{"error": "SKU not found: " + sku})
	})

	logger.Info("Inventory service started", zap.String("addr", ":8000"))
	if err := r.Run(":8000"); err != nil {
		logger.Fatal("server failed", zap.Error(err))
	}
}
