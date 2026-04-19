using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EastPricing.Controllers;

[ApiController]
public class PricingController : ControllerBase
{
    private readonly ILogger<PricingController> _logger;

    private static readonly HttpClient _catalogClient = new();
    private static readonly string CatalogUrl =
        Environment.GetEnvironmentVariable("CATALOG_URL") ?? "http://east-catalog:8000";

    private static readonly string ConnectionString =
        Environment.GetEnvironmentVariable("DB_CONNECTION")
        ?? "Server=pricing-db;Database=pricing;User Id=sa;Password=Pricing123!;TrustServerCertificate=True;";

    static PricingController()
    {
        InitDatabase();
    }

    private static void InitDatabase()
    {
        // Derive a master connection string to create the database if needed
        var masterConnStr = new SqlConnectionStringBuilder(ConnectionString)
        {
            InitialCatalog = "master"
        }.ConnectionString;

        // Retry loop — SQL Server container may still be starting
        for (int attempt = 1; attempt <= 30; attempt++)
        {
            try
            {
                using (var conn = new SqlConnection(masterConnStr))
                {
                    conn.Open();
                    using var cmd = conn.CreateCommand();
                    cmd.CommandText = "IF DB_ID('pricing') IS NULL CREATE DATABASE pricing;";
                    cmd.ExecuteNonQuery();
                }

                using (var conn = new SqlConnection(ConnectionString))
                {
                    conn.Open();

                    using var createTable = conn.CreateCommand();
                    createTable.CommandText = @"
                        IF OBJECT_ID('dbo.prices', 'U') IS NULL
                        CREATE TABLE dbo.prices (
                            id                    INT            PRIMARY KEY,
                            designation           VARCHAR(50)    NOT NULL,
                            base_cost_per_hr      DECIMAL(12,2)  NOT NULL,
                            priority_surcharge_pct DECIMAL(5,2)  NOT NULL,
                            total_cost_per_hr     DECIMAL(12,2)  NOT NULL,
                            currency              VARCHAR(10)    NOT NULL
                        );";
                    createTable.ExecuteNonQuery();

                    // Seed rows if the table is empty
                    using var countCmd = conn.CreateCommand();
                    countCmd.CommandText = "SELECT COUNT(*) FROM dbo.prices;";
                    var count = (int)countCmd.ExecuteScalar()!;

                    if (count == 0)
                    {
                        var seeds = new (int id, string designation, decimal baseCost, decimal surcharge)[]
                        {
                            (1, "TANKER-135",    18500.00m, 0.00m),
                            (2, "TANKER-46A",    22000.00m, 0.10m),
                            (3, "TANKER-10",     28000.00m, 0.00m),
                            (4, "RECEIVER-F16C",  8500.00m, 0.20m),
                            (5, "RECEIVER-F15E", 12000.00m, 0.05m),
                            (6, "RECEIVER-B52H", 35000.00m, 0.15m),
                        };

                        foreach (var s in seeds)
                        {
                            var total = Math.Round(s.baseCost * (1 + s.surcharge), 2);
                            using var insert = conn.CreateCommand();
                            insert.CommandText = @"
                                INSERT INTO dbo.prices (id, designation, base_cost_per_hr, priority_surcharge_pct, total_cost_per_hr, currency)
                                VALUES (@id, @designation, @base, @surcharge, @total, 'USD');";
                            insert.Parameters.Add(new SqlParameter("@id", s.id));
                            insert.Parameters.Add(new SqlParameter("@designation", s.designation));
                            insert.Parameters.Add(new SqlParameter("@base", s.baseCost));
                            insert.Parameters.Add(new SqlParameter("@surcharge", s.surcharge));
                            insert.Parameters.Add(new SqlParameter("@total", total));
                            insert.ExecuteNonQuery();
                        }
                    }
                }

                Console.WriteLine("Pricing database initialized successfully.");
                return;
            }
            catch (SqlException)
            {
                Console.WriteLine($"Database not ready, retrying ({attempt}/30)...");
                Thread.Sleep(2000);
            }
        }

        throw new Exception("Failed to initialize pricing database after 30 attempts.");
    }

    public PricingController(ILogger<PricingController> logger) => _logger = logger;

    [HttpGet("/health")]
    public IActionResult Health() =>
        Ok(new { status = "ok", service = "east-pricing", language = "dotnet" });

    [HttpGet("/prices")]
    public async Task<IActionResult> GetPrices()
    {
        var delayMs = Random.Shared.Next(10, 60);

        if (IsDegraded())
        {
            // 10% of requests return 503 during degraded window
            if (Random.Shared.NextDouble() < 0.10)
            {
                _logger.LogError("Mission cost engine cache miss; scenario=degraded event.action=cache-miss");
                return StatusCode(503, new { error = "mission cost engine cache miss — upstream rate limit exceeded" });
            }

            // 45% of requests have high latency during degraded window
            if (Random.Shared.NextDouble() < 0.45)
            {
                delayMs = Random.Shared.Next(300, 900);
                _logger.LogWarning("Mission cost engine degraded; delay_ms={DelayMs} scenario=degraded", delayMs);
            }
        }
        else
        {
            // Normal mode: 10% chance of moderate slowness
            if (Random.Shared.NextDouble() < 0.10)
            {
                delayMs = Random.Shared.Next(150, 400);
                _logger.LogWarning("Mission cost engine slow; delay_ms={DelayMs}", delayMs);
            }
        }

        await Task.Delay(delayMs);

        // Call Catalog service to enrich prices with aircraft names
        var nameLookup = new Dictionary<string, string>();
        try
        {
            _logger.LogInformation("Calling catalog service at {CatalogUrl}/products", CatalogUrl);
            var catalogJson = await _catalogClient.GetStringAsync($"{CatalogUrl}/products");
            using var doc = JsonDocument.Parse(catalogJson);
            if (doc.RootElement.TryGetProperty("products", out var productsArr))
            {
                foreach (var product in productsArr.EnumerateArray())
                {
                    var sku = product.GetProperty("sku").GetString();
                    var name = product.GetProperty("name").GetString();
                    if (sku is not null && name is not null)
                        nameLookup[sku] = name;
                }
            }
            _logger.LogInformation("Aircraft registry enrichment succeeded; aircraft_count={CatalogCount}", nameLookup.Count);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Aircraft registry enrichment failed; returning rates without names");
        }

        // Load prices from DB and merge with catalog names
        var enrichedPrices = new List<object>();
        using (var conn = new SqlConnection(ConnectionString))
        {
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT id, designation, base_cost_per_hr, priority_surcharge_pct, total_cost_per_hr, currency FROM dbo.prices ORDER BY id;";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var designation = reader.GetString(1);
                var baseCost = reader.GetDecimal(2);
                var surcharge = reader.GetDecimal(3);
                var totalCost = reader.GetDecimal(4);
                var currency = reader.GetString(5);
                var name = nameLookup.TryGetValue(designation, out var n) ? n : (string?)null;

                enrichedPrices.Add(new
                {
                    aircraft_id            = reader.GetInt32(0),
                    product_id             = reader.GetInt32(0),
                    designation,
                    sku                    = designation,
                    name,
                    base_cost_per_hr       = baseCost,
                    base_price             = baseCost,
                    priority_surcharge_pct = surcharge,
                    discount_pct           = surcharge,
                    total_cost_per_hr      = totalCost,
                    final_price            = totalCost,
                    currency,
                });
            }
        }

        _logger.LogInformation("Mission cost rates returned; item_count={Count} delay_ms={DelayMs}",
            enrichedPrices.Count, delayMs);
        return Ok(new { prices = enrichedPrices, count = enrichedPrices.Count });
    }

    [HttpGet("/prices/{sku}")]
    public IActionResult GetPrice(string sku)
    {
        using var conn = new SqlConnection(ConnectionString);
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT id, designation, base_cost_per_hr, priority_surcharge_pct, total_cost_per_hr, currency FROM dbo.prices WHERE designation = @sku;";
        cmd.Parameters.Add(new SqlParameter("@sku", sku));
        using var reader = cmd.ExecuteReader();

        if (!reader.Read())
        {
            _logger.LogWarning("Cost rate not found; designation={Sku}", sku);
            return NotFound(new { error = $"Designation not found: {sku}" });
        }

        var result = new
        {
            product_id             = reader.GetInt32(0),
            sku                    = reader.GetString(1),
            base_price             = reader.GetDecimal(2),
            discount_pct           = reader.GetDecimal(3),
            final_price            = reader.GetDecimal(4),
            currency               = reader.GetString(5),
        };

        _logger.LogInformation("Cost rate retrieved; designation={Sku}", sku);
        return Ok(result);
    }

    private static bool IsDegraded()
    {
        if (Environment.GetEnvironmentVariable("ANOMALY_ENABLED") != "true") return false;
        var second = DateTimeOffset.UtcNow.ToUnixTimeSeconds() % 240;
        return second >= 180 && second <= 204;
    }
}
