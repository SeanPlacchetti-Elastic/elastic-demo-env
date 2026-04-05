using System.Text.Json;
using Microsoft.AspNetCore.Mvc;

namespace EastPricing.Controllers;

[ApiController]
public class PricingController : ControllerBase
{
    private readonly ILogger<PricingController> _logger;

    private static readonly HttpClient _catalogClient = new();
    private static readonly string CatalogUrl =
        Environment.GetEnvironmentVariable("CATALOG_URL") ?? "http://east-catalog:8000";

    private static readonly List<object> Prices = new()
    {
        Price(1, "ES-NODE-01",    499.00m, 0.00m),
        Price(2, "KB-DASH-PRO",   299.00m, 0.10m),
        Price(3, "LS-ENT-01",     199.00m, 0.00m),
        Price(4, "APM-TOKEN-01",   99.00m, 0.20m),
        Price(5, "FLEET-LIC-01",  149.00m, 0.05m),
        Price(6, "SYNTH-PACK-01",  79.00m, 0.15m),
    };

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
                _logger.LogError("Pricing engine cache miss; scenario=degraded event.action=cache-miss");
                return StatusCode(503, new { error = "pricing engine cache miss — upstream rate limit exceeded" });
            }

            // 45% of requests have high latency during degraded window
            if (Random.Shared.NextDouble() < 0.45)
            {
                delayMs = Random.Shared.Next(300, 900);
                _logger.LogWarning("Pricing engine degraded; delay_ms={DelayMs} scenario=degraded", delayMs);
            }
        }
        else
        {
            // Normal mode: 10% chance of moderate slowness
            if (Random.Shared.NextDouble() < 0.10)
            {
                delayMs = Random.Shared.Next(150, 400);
                _logger.LogWarning("Pricing engine slow; delay_ms={DelayMs}", delayMs);
            }
        }

        await Task.Delay(delayMs);

        // Call Catalog service to enrich prices with product names
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
            _logger.LogInformation("Catalog enrichment succeeded; catalog_products={CatalogCount}", nameLookup.Count);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Catalog enrichment failed; returning prices without names");
        }

        // Merge names into price items
        var enrichedPrices = Prices.Select(p =>
        {
            var skuProp = p.GetType().GetProperty("sku")?.GetValue(p)?.ToString();
            var name = skuProp is not null && nameLookup.TryGetValue(skuProp, out var n) ? n : (string?)null;
            return new
            {
                product_id   = (int)p.GetType().GetProperty("product_id")!.GetValue(p)!,
                sku          = skuProp,
                name,
                base_price   = (decimal)p.GetType().GetProperty("base_price")!.GetValue(p)!,
                discount_pct = (decimal)p.GetType().GetProperty("discount_pct")!.GetValue(p)!,
                final_price  = (decimal)p.GetType().GetProperty("final_price")!.GetValue(p)!,
                currency     = (string)p.GetType().GetProperty("currency")!.GetValue(p)!,
            };
        }).ToList();

        _logger.LogInformation("Prices returned; item_count={Count} delay_ms={DelayMs}",
            enrichedPrices.Count, delayMs);
        return Ok(new { prices = enrichedPrices, count = enrichedPrices.Count });
    }

    [HttpGet("/prices/{sku}")]
    public IActionResult GetPrice(string sku)
    {
        // prices are anonymous objects — find via reflection-like dynamic cast
        var match = Prices.FirstOrDefault(p =>
            p.GetType().GetProperty("sku")?.GetValue(p)?.ToString() == sku);
        if (match is null)
        {
            _logger.LogWarning("Price not found; sku={Sku}", sku);
            return NotFound(new { error = $"SKU not found: {sku}" });
        }
        _logger.LogInformation("Price retrieved; sku={Sku}", sku);
        return Ok(match);
    }

    private static bool IsDegraded()
    {
        if (Environment.GetEnvironmentVariable("ANOMALY_ENABLED") != "true") return false;
        var second = DateTimeOffset.UtcNow.ToUnixTimeSeconds() % 600;
        return second >= 450 && second <= 510;
    }

    private static object Price(int id, string sku, decimal basePrice, decimal discountPct)
    {
        var final = Math.Round(basePrice * (1 - discountPct), 2);
        return new
        {
            product_id   = id,
            sku,
            base_price   = basePrice,
            discount_pct = discountPct,
            final_price  = final,
            currency     = "USD",
        };
    }
}
