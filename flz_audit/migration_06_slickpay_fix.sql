CREATE OR REPLACE FUNCTION public.orders_guard_anon_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF auth.role() = 'service_role' THEN RETURN NEW; END IF;
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN NEW;
  END IF;

  NEW.name := OLD.name;
  NEW.phone := OLD.phone;
  NEW.wilaya := OLD.wilaya;
  NEW.wilaya_id := OLD.wilaya_id;
  NEW.commune := OLD.commune;
  NEW.address := OLD.address;
  NEW.delivery_cost := OLD.delivery_cost;
  NEW.product_id := OLD.product_id;
  NEW.product_name := OLD.product_name;
  NEW.product_price := OLD.product_price;
  NEW.qty := OLD.qty;
  NEW.total := OLD.total;
  NEW.payment_method := OLD.payment_method;
  NEW.fulfillment_type := OLD.fulfillment_type;
  NEW.deposit_amount := OLD.deposit_amount;
  NEW.deposit_status := OLD.deposit_status;
  NEW.status := OLD.status;
  NEW.ref := OLD.ref;
  NEW.receipt_token := OLD.receipt_token;

  IF OLD.payment_status = 'paid' THEN
    RAISE EXCEPTION 'order already finalized';
  END IF;

  -- anon may only move payment_status into one of these "not yet confirmed" states
  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status
     AND NEW.payment_status NOT IN ('waiting_review','waiting_slickpay') THEN
    NEW.payment_status := OLD.payment_status;
  END IF;

  RETURN NEW;
END;
$$;
