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
	ProductID    int    `json:"product_id"`
	SKU          string `json:"sku"`
	Designation  string `json:"designation"`
	Name         string `json:"name"`
	Warehouse    string `json:"warehouse"`
	Base         string `json:"base"`
	Available    int    `json:"available"`
	AvailableLbs int    `json:"available_lbs"`
	Reserved     int    `json:"reserved"`
	AllocatedLbs int    `json:"allocated_lbs"`
	UpdatedAt    string `json:"updated_at"`
}

var bases = []string{"ramstein-ab", "kadena-ab", "al-udeid-ab"}

var stock = []StockItem{
	{1, "TANKER-135",    "TANKER-135",    "KC-135 Stratotanker",  "ramstein-ab",  "ramstein-ab",  450000, 450000, 150000, 150000, ""},
	{2, "TANKER-46A",    "TANKER-46A",    "KC-46A Pegasus",       "kadena-ab",    "kadena-ab",    380000, 380000, 207672, 207672, ""},
	{3, "TANKER-10",     "TANKER-10",     "KC-10 Extender",       "al-udeid-ab",  "al-udeid-ab",  520000, 520000, 200000, 200000, ""},
	{4, "RECEIVER-F16C", "RECEIVER-F16C", "F-16C Fighting Falcon","ramstein-ab",  "ramstein-ab",   85000,  85000,  21000,  21000, ""},
	{5, "RECEIVER-F15E", "RECEIVER-F15E", "F-15E Strike Eagle",   "kadena-ab",    "kadena-ab",    120000, 120000,  40365,  40365, ""},
	{6, "RECEIVER-B52H", "RECEIVER-B52H", "B-52H Stratofortress", "al-udeid-ab",  "al-udeid-ab",  185000, 185000,  62400,  62400, ""},
}

// isDegraded returns true during seconds 176-204 of a 240-second cycle.
func isDegraded() bool {
	if os.Getenv("ANOMALY_ENABLED") != "true" { return false }
	pos := time.Now().Unix() % 240
	return pos >= 176 && pos <= 204
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
			// ── Degraded mode (seconds 176-204 of cycle) ──────────────────
			base := bases[rand.Intn(len(bases))]

			// 10% hard failure — 503
			if rand.Float64() < 0.10 {
				logger.Error("fuel depot sync timeout",
					zap.String("base", base),
					zap.String("event.action", "depot-timeout"),
					zap.String("scenario", "degraded"),
				)
				c.JSON(http.StatusServiceUnavailable, gin.H{
					"error": "fuel depot sync timeout — cannot verify fuel levels at " + base,
				})
				return
			}

			// 50% high-latency response
			var delay time.Duration
			if rand.Float64() < 0.50 {
				delay = time.Duration(rand.Intn(1000)+500) * time.Millisecond
				logger.Warn("fuel depot sync latency spike",
					zap.String("base", base),
					zap.Duration("delay_ms", delay),
					zap.String("scenario", "degraded"),
				)
			} else {
				delay = time.Duration(rand.Intn(70)+10) * time.Millisecond
			}

			time.Sleep(delay)
			logger.Info("fuel depot levels returned",
				zap.Int("item_count", len(stock)),
				zap.Duration("query_ms", delay),
			)
			c.JSON(http.StatusOK, gin.H{"stock": stock, "count": len(stock)})
		} else {
			// ── Normal mode ───────────────────────────────────────────────
			delay := time.Duration(rand.Intn(70)+10) * time.Millisecond
			if rand.Float64() < 0.12 {
				delay = time.Duration(rand.Intn(400)+200) * time.Millisecond
				logger.Warn("fuel depot sync latency spike",
					zap.String("base", bases[rand.Intn(len(bases))]),
					zap.Duration("delay_ms", delay),
				)
			}
			time.Sleep(delay)
			logger.Info("fuel depot levels returned",
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
				logger.Info("fuel depot item retrieved", zap.String("designation", sku))
				c.JSON(http.StatusOK, item)
				return
			}
		}
		logger.Warn("fuel depot item not found", zap.String("designation", sku))
		c.JSON(http.StatusNotFound, gin.H{"error": "Designation not found: " + sku})
	})

	logger.Info("Fuel Depot service started", zap.String("addr", ":8000"))
	if err := r.Run(":8000"); err != nil {
		logger.Fatal("server failed", zap.Error(err))
	}
}
