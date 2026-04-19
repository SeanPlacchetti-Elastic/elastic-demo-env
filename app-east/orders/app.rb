require 'sinatra/base'
require 'elastic-apm'
require 'ecs_logging/logger'
require 'json'
require 'net/http'
require 'uri'
require 'mysql2'

# ── ECS-formatted structured logging to stdout ────────────────────────────────
LOGGER = EcsLogging::Logger.new($stdout)
LOGGER.level = Logger::INFO

SERVICE       = ENV.fetch('ELASTIC_APM_SERVICE_NAME', 'east-orders')
INVENTORY_URL = ENV.fetch('INVENTORY_URL', 'http://east-inventory:8000')
PRICING_URL   = ENV.fetch('PRICING_URL',   'http://east-pricing:8000')

# ── APM ───────────────────────────────────────────────────────────────────────
begin
  ElasticAPM.start(
    service_name:  SERVICE,
    secret_token:  ENV.fetch('ELASTIC_APM_SECRET_TOKEN', ''),
    server_url:    ENV.fetch('ELASTIC_APM_SERVER_URL', 'http://east-apm-server:8200'),
    environment:   ENV.fetch('ELASTIC_APM_ENVIRONMENT', 'production'),
    log_level:     Logger::WARN
  )
rescue => e
  LOGGER.warn('Failed to start APM client', error: { message: e.message })
end

# ── MySQL connection with retry logic ─────────────────────────────────────────
DB = nil
begin
  3.times do |attempt|
    DB = Mysql2::Client.new(
      host: ENV.fetch('MYSQL_HOST', 'orders-db'),
      database: ENV.fetch('MYSQL_DATABASE', 'orders'),
      username: ENV.fetch('MYSQL_USER', 'orders'),
      password: ENV.fetch('MYSQL_PASSWORD', 'orders123'),
      reconnect: true
    )
    break
  rescue => e
    LOGGER.warn("MySQL connection attempt #{attempt+1} failed", error: { message: e.message })
    sleep 5
  end
end

# ── Create table and seed data ────────────────────────────────────────────────
if DB
  DB.query(<<~SQL)
    CREATE TABLE IF NOT EXISTS missions (
      id VARCHAR(20) PRIMARY KEY,
      product_id INT,
      customer VARCHAR(50),
      callsign VARCHAR(50),
      quantity INT,
      fuel_lbs INT,
      status VARCHAR(20),
      mission_type VARCHAR(20),
      total DECIMAL(12,2),
      created_at DATETIME
    )
  SQL

  count = DB.query("SELECT COUNT(*) AS cnt FROM missions").first['cnt']
  if count == 0
    DB.query(<<~SQL)
      INSERT INTO missions (id, product_id, customer, callsign, quantity, fuel_lbs, status, mission_type, total, created_at) VALUES
      ('MSN-1001', 1, 'GHOST 11',  'GHOST 11',  150000, 150000, 'completed',  'air-to-air', 185000.00, '2026-04-01 02:14:00'),
      ('MSN-1002', 3, 'BLADE 23',  'BLADE 23',  200000, 200000, 'in-flight',  'air-to-air', 280000.00, '2026-04-07 18:30:00'),
      ('MSN-1003', 2, 'RAPTOR 07', 'RAPTOR 07', 207672, 207672, 'completed',  'air-to-air', 242000.00, '2026-04-05 14:05:00'),
      ('MSN-1004', 5, 'EAGLE 02',  'EAGLE 02',   40000,  40000, 'scheduled',  'ground',     125000.00, '2026-04-09 06:00:00'),
      ('MSN-1005', 6, 'BONE 91',   'BONE 91',    60000,  60000, 'in-flight',  'air-to-air', 350000.00, '2026-04-08 09:45:00'),
      ('MSN-1006', 4, 'VIPER 44',  'VIPER 44',   21000,  21000, 'aborted',    'air-to-air',  12000.00, '2026-04-07 11:00:00')
    SQL
    LOGGER.info('Seeded missions table', mission_count: 6)
  end
end

class OrdersApp < Sinatra::Base
  use ElasticAPM::Middleware

  set :bind,   '0.0.0.0'
  set :port,   8000
  set :server, :puma
  set :logging, false

  before { content_type :json }

  helpers do
    def degraded?
      return false unless ENV['ANOMALY_ENABLED'] == 'true'
      cycle = Time.now.to_i % 240
      cycle >= 188 && cycle <= 204
    end
  end

  get '/health' do
    { status: 'ok', service: SERVICE }.to_json
  end

  get '/orders' do
    # ── Query missions from MySQL ───────────────────────────────────────────
    if DB
      rows = DB.query("SELECT * FROM missions ORDER BY created_at DESC")
      missions = rows.map { |r| r.transform_keys(&:to_sym) }
    else
      missions = []
    end

    if degraded?
      # ── Degraded mode: high latency + mission database deadlocks ─────────
      delay = rand < 0.50 ? rand(0.5..1.4) : rand(0.01..0.07)
      sleep(delay)

      if rand < 0.12
        LOGGER.error('Mission database deadlock detected',
                     event: { action: 'db-deadlock' },
                     scenario: 'degraded')
        halt 503, { error: 'mission database deadlock detected — transaction rolled back' }.to_json
      end

      LOGGER.info('Mission listing served',
                  mission_count: missions.length,
                  query_time_ms: (delay * 1000).round,
                  scenario: 'degraded')
    else
      # ── Normal mode ───────────────────────────────────────────────────
      delay = rand(0.01..0.07)
      sleep(delay)

      if rand < 0.12
        LOGGER.warn('Slow mission listing query',
                    event: { action: 'slow-query' },
                    query_time_ms: (delay * 1000 + 200).round)
      else
        LOGGER.info('Mission listing served',
                    mission_count: missions.length,
                    query_time_ms: (delay * 1000).round)
      end
    end

    # ── Enrich missions from Fuel Depot and Pricing services ─────────────
    enriched_orders = missions.map(&:dup)

    stock_lookup = {}
    begin
      inv_uri = URI("#{INVENTORY_URL}/stock")
      LOGGER.info('Calling fuel depot service', url: inv_uri.to_s)
      inv_resp = Net::HTTP.get_response(inv_uri)
      if inv_resp.is_a?(Net::HTTPSuccess)
        inv_data = JSON.parse(inv_resp.body)
        inv_data['stock']&.each { |item| stock_lookup[item['product_id']] = item['available'] }
      else
        LOGGER.warn('Fuel depot service returned non-200', status: inv_resp.code)
      end
    rescue => e
      LOGGER.warn('Fuel depot service call failed', error: { message: e.message })
    end

    price_lookup = {}
    begin
      price_uri = URI("#{PRICING_URL}/prices")
      LOGGER.info('Calling mission cost service', url: price_uri.to_s)
      price_resp = Net::HTTP.get_response(price_uri)
      if price_resp.is_a?(Net::HTTPSuccess)
        price_data = JSON.parse(price_resp.body)
        price_data['prices']&.each { |item| price_lookup[item['product_id']] = item['final_price'] }
      else
        LOGGER.warn('Mission cost service returned non-200', status: price_resp.code)
      end
    rescue => e
      LOGGER.warn('Mission cost service call failed', error: { message: e.message })
    end

    enriched_orders.each do |order|
      pid = order[:product_id]
      order[:fuel_available_lbs] = stock_lookup[pid] if stock_lookup.key?(pid)
      order[:stock_available]    = stock_lookup[pid] if stock_lookup.key?(pid)
      order[:cost_per_hr]        = price_lookup[pid] if price_lookup.key?(pid)
      order[:current_price]      = price_lookup[pid] if price_lookup.key?(pid)
    end

    { orders: enriched_orders, count: enriched_orders.length }.to_json
  end
end

LOGGER.info('Refueling Missions service started', mission_count: DB ? DB.query("SELECT COUNT(*) AS cnt FROM missions").first['cnt'] : 0)
