<?php
declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use Monolog\Handler\StreamHandler;
use Monolog\Level;
use Monolog\Logger;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;

// ── ECS-formatted JSON logger ─────────────────────────────────────────────────
// Implements the Elastic Common Schema (ECS) log format directly with Monolog.
class EcsFormatter extends \Monolog\Formatter\NormalizerFormatter
{
    public function format(\Monolog\LogRecord $record): string
    {
        $entry = [
            '@timestamp'    => $record->datetime->format('c'),
            'log.level'     => strtolower($record->level->getName()),
            'message'       => $record->message,
            'ecs.version'   => '1.6.0',
            'service.name'  => getenv('ELASTIC_APM_SERVICE_NAME') ?: 'east-reviews',
            'service.environment' => getenv('ELASTIC_APM_ENVIRONMENT') ?: 'production',
            'log.logger'    => $record->channel,
        ];
        if (!empty($record->context)) {
            $entry = array_merge($entry, $record->context);
        }
        return json_encode($entry, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
    }
}

$handler = new StreamHandler('php://stdout', Level::Info);
$handler->setFormatter(new EcsFormatter());
$logger = new Logger('east.reviews');
$logger->pushHandler($handler);

// ── Sample reviews data ───────────────────────────────────────────────────────
$reviews = [
    ['id' => 1, 'product_id' => 1, 'author' => 'Alice M.',  'rating' => 5,
     'title' => 'Scales beautifully',
     'body'  => 'Handles petabyte workloads without breaking a sweat.',
     'date'  => '2025-03-01'],
    ['id' => 2, 'product_id' => 1, 'author' => 'Bob K.',    'rating' => 4,
     'title' => 'Great performance',
     'body'  => 'Excellent search performance, setup took a bit of patience.',
     'date'  => '2025-02-18'],
    ['id' => 3, 'product_id' => 2, 'author' => 'Carol S.',  'rating' => 5,
     'title' => 'Best dashboard tool',
     'body'  => 'Kibana Lens made building dashboards genuinely enjoyable.',
     'date'  => '2025-03-10'],
    ['id' => 4, 'product_id' => 3, 'author' => 'Dan T.',    'rating' => 3,
     'title' => 'Powerful but complex',
     'body'  => 'Pipeline DSL has a steep learning curve; very capable once mastered.',
     'date'  => '2025-01-22'],
    ['id' => 5, 'product_id' => 5, 'author' => 'Eva R.',    'rating' => 5,
     'title' => 'Fleet management FTW',
     'body'  => 'Centralised agent management saved us hours per week.',
     'date'  => '2025-03-15'],
    ['id' => 6, 'product_id' => 6, 'author' => 'Frank L.',  'rating' => 4,
     'title' => 'Solid synthetic monitoring',
     'body'  => 'Browser-based checks caught three outages before our users did.',
     'date'  => '2025-02-28'],
];

// ── Anomaly helper (10-minute / 600-second cycle) ────────────────────────────
function isDegraded(): bool
{
    if (getenv('ANOMALY_ENABLED') !== 'true') return false;
    $phase = time() % 600;
    return $phase >= 460 && $phase <= 510;
}

// ── Catalog service URL for product-name enrichment ─────────────────────────
$catalogUrl = getenv('CATALOG_URL') ?: 'http://east-catalog:8000';

// ── Slim application ──────────────────────────────────────────────────────────
$app = AppFactory::create();

$app->get('/health', function (Request $req, Response $res) use ($logger): Response {
    $logger->info('Health check');
    $res->getBody()->write(json_encode([
        'status'   => 'ok',
        'service'  => 'east-reviews',
        'language' => 'php',
    ]));
    return $res->withHeader('Content-Type', 'application/json');
});

$app->get('/reviews', function (Request $req, Response $res) use ($logger, $reviews, $catalogUrl): Response {
    $params      = $req->getQueryParams();
    $filtered    = $reviews;
    $productId   = isset($params['product_id']) ? (int) $params['product_id'] : null;
    if ($productId !== null) {
        $filtered = array_values(array_filter($reviews, fn($r) => $r['product_id'] === $productId));
    }

    // ── Degraded-mode anomaly (seconds 460-510 of each 600s cycle) ───────
    if (isDegraded()) {
        $roll = rand(1, 100);
        if ($roll <= 12) {
            // 12% hard failure — database pool exhausted
            $logger->error('Database connection pool exhausted', [
                'event.action' => 'db-pool-exhausted',
                'scenario'     => 'degraded',
            ]);
            $res->getBody()->write(json_encode([
                'error' => 'database connection pool exhausted — max connections reached',
            ]));
            return $res->withStatus(500)->withHeader('Content-Type', 'application/json');
        }
        if ($roll <= 52) {
            // 40% high-latency (400-1000 ms)
            $delay = rand(400, 1000) * 1000;
        } else {
            // remaining 48% normal latency
            $delay = rand(10, 70) * 1000;
        }
    } else {
        // ── Normal mode ──────────────────────────────────────────────────
        $delay = rand(10, 70) * 1000;  // microseconds
    }

    usleep($delay);

    // ── Enrich reviews with product names from Catalog service ───────
    $productLookup = [];
    try {
        $logger->info('Calling catalog service', [
            'event.action' => 'catalog-lookup',
            'catalog_url'  => $catalogUrl . '/products',
        ]);
        $catalogJson = @file_get_contents($catalogUrl . '/products');
        if ($catalogJson !== false) {
            $catalogData = json_decode($catalogJson, true);
            if (isset($catalogData['products']) && is_array($catalogData['products'])) {
                foreach ($catalogData['products'] as $product) {
                    $productLookup[$product['id']] = $product['name'];
                }
            }
            $logger->info('Catalog enrichment succeeded', [
                'event.action'  => 'catalog-lookup-success',
                'product_count' => count($productLookup),
            ]);
        } else {
            $logger->warning('Catalog service returned empty response', [
                'event.action' => 'catalog-lookup-failed',
            ]);
        }
    } catch (\Throwable $e) {
        $logger->warning('Catalog enrichment failed, returning reviews without product names', [
            'event.action' => 'catalog-lookup-error',
            'error.message' => $e->getMessage(),
        ]);
    }

    // Add product_name to each review if lookup is available
    $filtered = array_map(function ($review) use ($productLookup) {
        $review['product_name'] = $productLookup[$review['product_id']] ?? null;
        return $review;
    }, $filtered);

    $logger->info('Reviews returned', [
        'review_count' => count($filtered),
        'product_id'   => $productId,
        'delay_ms'     => intdiv($delay, 1000),
    ]);
    $res->getBody()->write(json_encode([
        'reviews' => $filtered,
        'count'   => count($filtered),
    ]));
    return $res->withHeader('Content-Type', 'application/json');
});

$app->get('/reviews/{id}', function (Request $req, Response $res, array $args) use ($logger, $reviews): Response {
    $id    = (int) $args['id'];
    $match = array_values(array_filter($reviews, fn($r) => $r['id'] === $id));
    if (empty($match)) {
        $logger->warning('Review not found', ['review_id' => $id]);
        $res->getBody()->write(json_encode(['error' => "Review $id not found"]));
        return $res->withStatus(404)->withHeader('Content-Type', 'application/json');
    }
    $logger->info('Review retrieved', ['review_id' => $id]);
    $res->getBody()->write(json_encode($match[0]));
    return $res->withHeader('Content-Type', 'application/json');
});

$logger->info('Reviews service started');
$app->run();
