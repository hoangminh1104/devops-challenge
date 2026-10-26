\set ON_ERROR_STOP on
CREATE ROLE p5_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE ROLE p5_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'migrator_password';
CREATE ROLE p5_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'api_password';
CREATE ROLE p5_worker LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'worker_password';
GRANT p5_owner TO p5_migrator;
REVOKE ALL ON DATABASE p5_security FROM PUBLIC;
GRANT CONNECT ON DATABASE p5_security TO p5_migrator,p5_api,p5_worker;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA p5 AUTHORIZATION p5_owner;
SET ROLE p5_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA p5 REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE p5.accounts(id text PRIMARY KEY);
CREATE TABLE p5.balances(
  account_id text PRIMARY KEY REFERENCES p5.accounts(id),
  available numeric(18,2) NOT NULL CHECK(available>=0),
  reserved numeric(18,2) NOT NULL CHECK(reserved>=0)
);
CREATE TABLE p5.orders(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id text NOT NULL REFERENCES p5.accounts(id),
  idempotency_key text NOT NULL,
  amount numeric(18,2) NOT NULL CHECK(amount>0),
  status text NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','CANCEL_REQUESTED','CANCELLED')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(account_id,idempotency_key)
);
CREATE INDEX p5_pending ON p5.orders(created_at) WHERE status<>'CANCELLED';
CREATE TABLE p5.ledger(
  id bigserial PRIMARY KEY,
  event_id uuid NOT NULL DEFAULT gen_random_uuid(),
  account_id text NOT NULL,
  available_delta numeric(18,2) NOT NULL,
  reserved_delta numeric(18,2) NOT NULL,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE p5.limits(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  account_limit integer NOT NULL CHECK(account_limit>0),
  window_seconds integer NOT NULL CHECK(window_seconds>0),
  capacity integer NOT NULL CHECK(capacity>0)
);
INSERT INTO p5.limits VALUES(true,4,60,20);
CREATE TABLE p5.rate_buckets(
  account_id text PRIMARY KEY REFERENCES p5.accounts(id),
  started_at timestamptz NOT NULL,
  accepted integer NOT NULL CHECK(accepted>=0)
);

CREATE FUNCTION p5.api_balance(subject text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,p5,pg_temp AS $$
DECLARE result jsonb;
BEGIN
  SELECT jsonb_build_object('asset','USDT','available',available::text,'reserved',reserved::text)
    INTO result FROM p5.balances WHERE account_id=subject;
  IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='P4030',MESSAGE='Account not provisioned'; END IF;
  RETURN result;
END $$;

CREATE FUNCTION p5.api_order(subject text,order_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,p5,pg_temp AS $$
DECLARE result jsonb;
BEGIN
  SELECT jsonb_build_object('id',id,'amount',amount::text,'status',status) INTO result
    FROM p5.orders WHERE id=order_id AND account_id=subject;
  IF result IS NULL THEN RAISE EXCEPTION USING ERRCODE='P4040',MESSAGE='Order not found'; END IF;
  RETURN result;
END $$;

CREATE FUNCTION p5.api_submit(subject text,request_key text,requested_amount numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,p5,pg_temp AS $$
DECLARE cfg p5.limits%ROWTYPE; prior p5.orders%ROWTYPE; bucket p5.rate_buckets%ROWTYPE;
        new_id uuid; current_time_value timestamptz:=clock_timestamp();
BEGIN
  IF subject IS NULL OR request_key IS NULL OR request_key !~ '^[A-Za-z0-9._:-]{8,100}$'
     OR requested_amount IS NULL OR requested_amount<=0 OR requested_amount>1000
     OR requested_amount<>round(requested_amount,2) THEN
    RAISE EXCEPTION USING ERRCODE='P4000',MESSAGE='Invalid order';
  END IF;
  -- A small global gate deliberately makes capacity and quota checks atomic.
  -- Every mutating routine takes this gate first, avoiding inverted lock order.
  PERFORM pg_advisory_xact_lock(584005,1);
  current_time_value:=clock_timestamp();
  IF NOT EXISTS(SELECT 1 FROM p5.accounts WHERE id=subject) THEN
    RAISE EXCEPTION USING ERRCODE='P4030',MESSAGE='Account not provisioned';
  END IF;
  SELECT * INTO prior FROM p5.orders WHERE account_id=subject AND idempotency_key=request_key;
  IF FOUND THEN
    IF prior.amount<>requested_amount THEN
      RAISE EXCEPTION USING ERRCODE='P4090',MESSAGE='Idempotency key conflicts with original input';
    END IF;
    RETURN p5.api_order(subject,prior.id)||jsonb_build_object('replayed',true);
  END IF;
  SELECT * INTO cfg FROM p5.limits WHERE singleton;
  SELECT * INTO bucket FROM p5.rate_buckets WHERE account_id=subject;
  IF FOUND AND current_time_value-bucket.started_at<make_interval(secs=>cfg.window_seconds)
     AND bucket.accepted>=cfg.account_limit THEN
    RAISE EXCEPTION USING ERRCODE='P4290',MESSAGE='Account submission limit reached';
  END IF;
  IF (SELECT count(*) FROM p5.orders WHERE status<>'CANCELLED')>=cfg.capacity THEN
    RAISE EXCEPTION USING ERRCODE='P5030',MESSAGE='Admission closed; retry later with the same key';
  END IF;
  UPDATE p5.balances SET available=available-requested_amount,reserved=reserved+requested_amount
    WHERE account_id=subject AND available>=requested_amount;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P4220',MESSAGE='Insufficient available funds'; END IF;
  INSERT INTO p5.rate_buckets(account_id,started_at,accepted) VALUES(subject,current_time_value,1)
    ON CONFLICT(account_id) DO UPDATE SET
      started_at=CASE WHEN current_time_value-p5.rate_buckets.started_at>=make_interval(secs=>cfg.window_seconds)
                      THEN current_time_value ELSE p5.rate_buckets.started_at END,
      accepted=CASE WHEN current_time_value-p5.rate_buckets.started_at>=make_interval(secs=>cfg.window_seconds)
                   THEN 1 ELSE p5.rate_buckets.accepted+1 END;
  INSERT INTO p5.orders(account_id,idempotency_key,amount) VALUES(subject,request_key,requested_amount) RETURNING id INTO new_id;
  INSERT INTO p5.ledger(account_id,available_delta,reserved_delta,reason)
    VALUES(subject,-requested_amount,requested_amount,'RESERVE');
  RETURN p5.api_order(subject,new_id)||jsonb_build_object('replayed',false);
END $$;

CREATE FUNCTION p5.api_cancel(subject text,order_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,p5,pg_temp AS $$
DECLARE target p5.orders%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(584005,1);
  SELECT * INTO target FROM p5.orders WHERE id=order_id AND account_id=subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P4040',MESSAGE='Order not found'; END IF;
  UPDATE p5.orders SET status='CANCEL_REQUESTED' WHERE id=order_id AND status='PENDING';
  RETURN p5.api_order(subject,order_id)||jsonb_build_object('cancellation_requested',target.status<>'CANCELLED');
END $$;

CREATE FUNCTION p5.worker_process_one() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,p5,pg_temp AS $$
DECLARE target p5.orders%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(584005,1);
  SELECT * INTO target FROM p5.orders WHERE status='CANCEL_REQUESTED' ORDER BY created_at,id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('processed',false); END IF;
  UPDATE p5.balances SET available=available+target.amount,reserved=reserved-target.amount WHERE account_id=target.account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Missing balance'; END IF;
  INSERT INTO p5.ledger(account_id,available_delta,reserved_delta,reason)
    VALUES(target.account_id,target.amount,-target.amount,'RELEASE');
  UPDATE p5.orders SET status='CANCELLED' WHERE id=target.id;
  RETURN jsonb_build_object('processed',true,'id',target.id);
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA p5 FROM PUBLIC,p5_api,p5_worker;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA p5 FROM PUBLIC,p5_api,p5_worker;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA p5 FROM PUBLIC,p5_api,p5_worker;
GRANT USAGE ON SCHEMA p5 TO p5_api,p5_worker;
GRANT EXECUTE ON FUNCTION p5.api_balance(text),p5.api_order(text,uuid),p5.api_submit(text,text,numeric),p5.api_cancel(text,uuid) TO p5_api;
GRANT EXECUTE ON FUNCTION p5.worker_process_one() TO p5_worker;
RESET ROLE;
