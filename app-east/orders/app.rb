require 'sinatra/base'
require 'elastic-apm'
require 'ecs_logging/logger'
require 'json'
require 'net/http'
require 'uri'

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

ORDERS = [
  { id: 'ORD-1001', product_id: 1, customer: 'alice@example.com',  quantity: 2,  status: 'shipped',    total: 998.00,  created_at: '2026-03-20T09:14:00Z' },
  { id: 'ORD-1002', product_id: 3, customer: 'bob@example.com',    quantity: 1,  status: 'processing', total: 199.00,  created_at: '2026-03-22T11:30:00Z' },
  { id: 'ORD-1003', product_id: 2, customer: 'carol@example.com',  quantity: 3,  status: 'delivered',  total: 897.00,  created_at: '2026-03-23T14:05:00Z' },
  { id: 'ORD-1004', product_id: 5, customer: 'dave@example.com',   quantity: 1,  status: 'pending',    total: 149.00,  created_at: '2026-03-25T08:22:00Z' },
  { id: 'ORD-1005', product_id: 6, customer: 'eve@example.com',    quantity: 5,  status: 'shipped',    total: 395.00,  created_at: '2026-03-27T16:45:00Z' },
  { id: 'ORD-1006', product_id: 4, customer: 'frank@example.com',  quantity: 10, status: 'delivered',  total: 990.00,  created_at: '2026-03-28T07:00:00Z' },
].freeze

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
      cycle = Time.now.to_i % 600
      cycle >= 470 && cycle <= 510
    end
  end

  get '/health' do
    { status: 'ok', service: SERVICE }.to_json
  end

  get '/orders' do
    if degraded?
      # ── Degraded mode: high latency + database deadlocks ──────────────
      delay = rand < 0.50 ? rand(0.5..1.4) : rand(0.01..0.07)
      sleep(delay)

      if rand < 0.12
        LOGGER.error('Order database deadlock detected',
                     event: { action: 'db-deadlock' },
                     scenario: 'degraded')
        halt 503, { error: 'order database deadlock detected — transaction rolled back' }.to_json
      end

      LOGGER.info('Order listing served',
                  order_count: ORDERS.length,
                  query_time_ms: (delay * 1000).round,
                  scenario: 'degraded')
    else
      # ── Normal mode ───────────────────────────────────────────────────
      delay = rand(0.01..0.07)
      sleep(delay)

      if rand < 0.12
        LOGGER.warn('Slow order listing query',
                    event: { action: 'slow-query' },
                    query_time_ms: (delay * 1000 + 200).round)
      else
        LOGGER.info('Order listing served',
                    order_count: ORDERS.length,
                    query_time_ms: (delay * 1000).round)
      end
    end

    # ── Enrich orders from Inventory and Pricing services ────────────────
    enriched_orders = ORDERS.map(&:dup)

    stock_lookup = {}
    begin
      inv_uri = URI("#{INVENTORY_URL}/stock")
      LOGGER.info('Calling inventory service', url: inv_uri.to_s)
      inv_resp = Net::HTTP.get_response(inv_uri)
      if inv_resp.is_a?(Net::HTTPSuccess)
        inv_data = JSON.parse(inv_resp.body)
        inv_data['stock']&.each { |item| stock_lookup[item['product_id']] = item['available'] }
      else
        LOGGER.warn('Inventory service returned non-200', status: inv_resp.code)
      end
    rescue => e
      LOGGER.warn('Inventory service call failed', error: { message: e.message })
    end

    price_lookup = {}
    begin
      price_uri = URI("#{PRICING_URL}/prices")
      LOGGER.info('Calling pricing service', url: price_uri.to_s)
      price_resp = Net::HTTP.get_response(price_uri)
      if price_resp.is_a?(Net::HTTPSuccess)
        price_data = JSON.parse(price_resp.body)
        price_data['prices']&.each { |item| price_lookup[item['product_id']] = item['final_price'] }
      else
        LOGGER.warn('Pricing service returned non-200', status: price_resp.code)
      end
    rescue => e
      LOGGER.warn('Pricing service call failed', error: { message: e.message })
    end

    enriched_orders.each do |order|
      pid = order[:product_id]
      order[:stock_available] = stock_lookup[pid] if stock_lookup.key?(pid)
      order[:current_price]   = price_lookup[pid] if price_lookup.key?(pid)
    end

    { orders: enriched_orders, count: enriched_orders.length }.to_json
  end
end

LOGGER.info('Orders service started', order_count: ORDERS.length)
