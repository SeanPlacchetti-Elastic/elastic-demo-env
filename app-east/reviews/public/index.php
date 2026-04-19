<?php
declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use Monolog\Handler\StreamHandler;
use Monolog\Level;
use Monolog\Logger;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;
use MongoDB\Client as MongoClient;

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

// ── MongoDB connection ───────────────────────────────────────────────────────
$mongoUrl = getenv('MONGO_URL') ?: 'mongodb://reviews-db:27017';
$mongoDbName = getenv('MONGO_DB') ?: 'reviews';
try {
    $mongo = new MongoClient($mongoUrl);
    $reviewsCollection = $mongo->selectDatabase($mongoDbName)->selectCollection('reviews');
} catch (\Throwable $e) {
    $logger->warning('MongoDB connection failed', ['error.message' => $e->getMessage()]);
    $reviewsCollection = null;
}

// ── After Action Reports (AARs) ───────────────────────────────────────────────
$reviews = [
    ['id' => 1, 'product_id' => 1, 'author' => 'GHOST 11',  'rating' => 5,
     'title' => 'Flawless boom transfer at FL350',
     'body'  => 'KC-135 maintained contact for 45 min while we topped off at 0300Z. Zero oscillation, perfect pressure.',
     'date'  => '2026-03-01'],
    ['id' => 2, 'product_id' => 1, 'author' => 'BLADE 23',  'rating' => 4,
     'title' => 'Solid performance in high turbulence',
     'body'  => 'Had to abort first approach due to wake vortex, but second contact was clean. Offloaded 60,000 lbs.',
     'date'  => '2026-02-18'],
    ['id' => 3, 'product_id' => 2, 'author' => 'RAPTOR 07', 'rating' => 5,
     'title' => 'KC-46A boom system outperforms legacy',
     'body'  => 'Remote vision system enabled contact in IMC. Offloaded to 4 receivers in a single sortie.',
     'date'  => '2026-03-10'],
    ['id' => 4, 'product_id' => 3, 'author' => 'VIPER 44',  'rating' => 3,
     'title' => 'Probe-and-drogue workable, prefer boom',
     'body'  => 'KC-10 drogue basket required 3 attempts. F-16 probe alignment tricky at 450 KTAS.',
     'date'  => '2026-01-22'],
    ['id' => 5, 'product_id' => 5, 'author' => 'EAGLE 02',  'rating' => 5,
     'title' => 'Night AAR over CENTCOM AOR — textbook',
     'body'  => 'F-15E wet-wing transfer completed at 24,000 ft. Cleared full fuel state for extended strike package.',
     'date'  => '2026-03-15'],
    ['id' => 6, 'product_id' => 6, 'author' => 'BONE 91',   'rating' => 4,
     'title' => 'B-52 fuel state critical, tanker response excellent',
     'body'  => 'Diverted tanker to support unplanned AAR. KC-10 extended mission by 4 hours.',
     'date'  => '2026-02-28'],
];

// ── Seed MongoDB if empty (unique index prevents duplicate seeding) ──────────
if ($reviewsCollection !== null) {
    try {
        $reviewsCollection->createIndex(['id' => 1], ['unique' => true]);
    } catch (\Throwable $e) {
        // Index may already exist — ignore
    }
    if ($reviewsCollection->countDocuments() === 0) {
        $logger->info('Seeding reviews collection in MongoDB');
        try {
            $reviewsCollection->insertMany($reviews, ['ordered' => false]);
        } catch (\Throwable $e) {
            // Duplicate key errors from race condition — safe to ignore
        }
        $logger->info('Seeded review documents into MongoDB');
    }
}

// ── Anomaly helper (4-minute / 240-second cycle) ─────────────────────────────
function isDegraded(): bool
{
    if (getenv('ANOMALY_ENABLED') !== 'true') return false;
    $phase = time() % 240;
    return $phase >= 184 && $phase <= 204;
}

// ── Catalog service URL for aircraft-name enrichment ─────────────────────────
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

$app->get('/reviews', function (Request $req, Response $res) use ($logger, $reviews, $catalogUrl, $reviewsCollection): Response {
    $params      = $req->getQueryParams();
    $productId   = isset($params['product_id']) ? (int) $params['product_id'] : null;

    // Load reviews from MongoDB (fall back to static array)
    if ($reviewsCollection !== null) {
        try {
            $cursor = $reviewsCollection->find(
                $productId !== null ? ['product_id' => $productId] : [],
                ['sort' => ['id' => 1]]
            );
            $filtered = [];
            foreach ($cursor as $doc) {
                $filtered[] = [
                    'id' => $doc['id'],
                    'product_id' => $doc['product_id'],
                    'author' => $doc['author'],
                    'rating' => $doc['rating'],
                    'title' => $doc['title'],
                    'body' => $doc['body'],
                    'date' => $doc['date'],
                ];
            }
        } catch (\Throwable $e) {
            $logger->warning('MongoDB query failed, falling back to static data', ['error.message' => $e->getMessage()]);
            $filtered = $reviews;
            if ($productId !== null) {
                $filtered = array_values(array_filter($reviews, fn($r) => $r['product_id'] === $productId));
            }
        }
    } else {
        $filtered = $reviews;
        if ($productId !== null) {
            $filtered = array_values(array_filter($reviews, fn($r) => $r['product_id'] === $productId));
        }
    }

    // ── Degraded-mode anomaly (seconds 184-204 of each 240s cycle) ───────
    if (isDegraded()) {
        $roll = rand(1, 100);
        if ($roll <= 12) {
            // 12% hard failure — database pool exhausted
            $logger->error('AAR database connection pool exhausted', [
                'event.action' => 'db-pool-exhausted',
                'scenario'     => 'degraded',
            ]);
            $res->getBody()->write(json_encode([
                'error' => 'AAR database connection pool exhausted — max connections reached',
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

    // ── Enrich AARs with aircraft names from Catalog service ─────────────
    $productLookup = [];
    try {
        $logger->info('Calling aircraft registry service', [
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
            $logger->info('Aircraft registry enrichment succeeded', [
                'event.action'   => 'catalog-lookup-success',
                'aircraft_count' => count($productLookup),
            ]);
        } else {
            $logger->warning('Aircraft registry service returned empty response', [
                'event.action' => 'catalog-lookup-failed',
            ]);
        }
    } catch (\Throwable $e) {
        $logger->warning('Aircraft registry enrichment failed, returning AARs without aircraft names', [
            'event.action' => 'catalog-lookup-error',
            'error.message' => $e->getMessage(),
        ]);
    }

    // Add aircraft_name to each AAR if lookup is available
    $filtered = array_map(function ($review) use ($productLookup) {
        $review['product_name'] = $productLookup[$review['product_id']] ?? null;
        return $review;
    }, $filtered);

    $logger->info('AARs returned', [
        'aar_count'  => count($filtered),
        'product_id' => $productId,
        'delay_ms'   => intdiv($delay, 1000),
    ]);
    $res->getBody()->write(json_encode([
        'reviews' => $filtered,
        'count'   => count($filtered),
    ]));
    return $res->withHeader('Content-Type', 'application/json');
});

$app->get('/reviews/{id}', function (Request $req, Response $res, array $args) use ($logger, $reviews, $reviewsCollection): Response {
    $id    = (int) $args['id'];
    $match = null;

    // Try MongoDB first
    if ($reviewsCollection !== null) {
        try {
            $doc = $reviewsCollection->findOne(['id' => $id]);
            if ($doc !== null) {
                $match = [
                    'id' => $doc['id'],
                    'product_id' => $doc['product_id'],
                    'author' => $doc['author'],
                    'rating' => $doc['rating'],
                    'title' => $doc['title'],
                    'body' => $doc['body'],
                    'date' => $doc['date'],
                ];
            }
        } catch (\Throwable $e) {
            $logger->warning('MongoDB query failed, falling back to static data', ['error.message' => $e->getMessage()]);
        }
    }

    // Fall back to static array
    if ($match === null) {
        $staticMatch = array_values(array_filter($reviews, fn($r) => $r['id'] === $id));
        if (!empty($staticMatch)) {
            $match = $staticMatch[0];
        }
    }

    if ($match === null) {
        $logger->warning('AAR not found', ['aar_id' => $id]);
        $res->getBody()->write(json_encode(['error' => "AAR $id not found"]));
        return $res->withStatus(404)->withHeader('Content-Type', 'application/json');
    }
    $logger->info('AAR retrieved', ['aar_id' => $id]);
    $res->getBody()->write(json_encode($match));
    return $res->withHeader('Content-Type', 'application/json');
});

$logger->info('After Action Reports service started');
$app->run();
