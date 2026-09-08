-- ============================================================
-- Admin-panel upgrade: audit trail for order changes (admin-only,
-- never visible to customers) + a couple of missing safety rails.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.order_events (
  id bigserial PRIMARY KEY,
  order_id text NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  detail text,
  actor uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.order_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_events_admin_all ON public.order_events;
CREATE POLICY order_events_admin_all ON public.order_events
  FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
-- no anon policy at all -> customers cannot read or write audit rows

CREATE OR REPLACE FUNCTION public.orders_log_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.order_events(order_id, event_type, detail, actor)
    VALUES (NEW.id, 'created', 'total=' || NEW.total || ' status=' || NEW.status, auth.uid());
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.order_events(order_id, event_type, detail, actor)
    VALUES (NEW.id, 'status_changed', OLD.status || ' -> ' || NEW.status, auth.uid());
  END IF;
  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status THEN
    INSERT INTO public.order_events(order_id, event_type, detail, actor)
    VALUES (NEW.id, 'payment_status_changed', OLD.payment_status || ' -> ' || NEW.payment_status, auth.uid());
  END IF;
  IF NEW.deposit_status IS DISTINCT FROM OLD.deposit_status THEN
    INSERT INTO public.order_events(order_id, event_type, detail, actor)
    VALUES (NEW.id, 'deposit_status_changed', OLD.deposit_status || ' -> ' || NEW.deposit_status, auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_log_insert ON public.orders;
CREATE TRIGGER trg_orders_log_insert
  AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_log_changes();

DROP TRIGGER IF EXISTS trg_orders_log_update ON public.orders;
CREATE TRIGGER trg_orders_log_update
  AFTER UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_log_changes();

-- Deposit verification must be an explicit admin/service action, never
-- settable by the public-facing anon update guard (already blocked there,
-- this just makes intent explicit at the column-default level).
ALTER TABLE public.orders
  ALTER COLUMN deposit_status SET DEFAULT 'not_required';

-- Product reference must be unique & permanent once set.
CREATE UNIQUE INDEX IF NOT EXISTS products_ref_uidx ON public.products(ref) WHERE ref IS NOT NULL;
