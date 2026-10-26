CREATE TABLE IF NOT EXISTS accounts (
  id text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS balances (
  account_id text NOT NULL REFERENCES accounts(id),
  asset text NOT NULL CHECK (asset IN ('BTC', 'USDT')),
  available numeric(38,16) NOT NULL DEFAULT 0 CHECK (available >= 0),
  reserved numeric(38,16) NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  PRIMARY KEY (account_id, asset)
);
CREATE SEQUENCE IF NOT EXISTS book_sequence;
CREATE TABLE IF NOT EXISTS orders (
  id uuid PRIMARY KEY,
  account_id text NOT NULL REFERENCES accounts(id),
  market text NOT NULL CHECK (market = 'BTC-USDT'),
  side text NOT NULL CHECK (side IN ('BUY', 'SELL')),
  price numeric(24,8) NOT NULL CHECK (price > 0),
  quantity numeric(24,8) NOT NULL CHECK (quantity > 0),
  remaining numeric(24,8) NOT NULL CHECK (remaining >= 0 AND remaining <= quantity),
  reserved_amount numeric(38,16) NOT NULL CHECK (reserved_amount >= 0),
  status text NOT NULL CHECK (status IN ('PENDING','OPEN','PARTIALLY_FILLED','FILLED','CANCELLED')),
  reason text,
  admission_seq bigint,
  idempotency_key text NOT NULL,
  request_hash text NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (account_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS orders_book ON orders (market, side, price, admission_seq)
  WHERE status IN ('OPEN','PARTIALLY_FILLED');
CREATE INDEX IF NOT EXISTS orders_account ON orders (account_id, accepted_at DESC, id DESC);
CREATE TABLE IF NOT EXISTS commands (
  id bigserial PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES orders(id),
  kind text NOT NULL CHECK (kind IN ('PLACE','CANCEL')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  processed_at timestamptz,
  UNIQUE (order_id, kind)
);
CREATE INDEX IF NOT EXISTS commands_pending ON commands (id) WHERE processed_at IS NULL;
CREATE TABLE IF NOT EXISTS trades (
  id bigserial PRIMARY KEY,
  event_id uuid NOT NULL UNIQUE,
  market text NOT NULL,
  maker_order uuid NOT NULL REFERENCES orders(id),
  taker_order uuid NOT NULL REFERENCES orders(id),
  buyer_id text NOT NULL REFERENCES accounts(id),
  seller_id text NOT NULL REFERENCES accounts(id),
  price numeric(24,8) NOT NULL CHECK (price > 0),
  quantity numeric(24,8) NOT NULL CHECK (quantity > 0),
  executed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (buyer_id <> seller_id)
);
CREATE INDEX IF NOT EXISTS trades_market ON trades (market, id DESC);
CREATE INDEX IF NOT EXISTS trades_maker ON trades (maker_order, id DESC);
CREATE INDEX IF NOT EXISTS trades_taker ON trades (taker_order, id DESC);
CREATE TABLE IF NOT EXISTS ledger (
  id bigserial PRIMARY KEY,
  event_id uuid NOT NULL,
  account_id text NOT NULL,
  asset text NOT NULL,
  available_delta numeric(38,16) NOT NULL,
  reserved_delta numeric(38,16) NOT NULL,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS ledger_account ON ledger (account_id, asset);
CREATE INDEX IF NOT EXISTS ledger_event ON ledger (event_id);
