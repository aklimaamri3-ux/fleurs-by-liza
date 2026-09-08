-- WhatsApp and Facebook are public contact channels (customers are meant to
-- click them), not secrets — add them to the already-curated public RPC
-- alongside the existing safe payment fields.
CREATE OR REPLACE FUNCTION public.get_payment_info()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v json;
BEGIN
  SELECT value INTO v FROM public.settings WHERE key = 'payment';
  RETURN json_build_object(
    'holder',        v->>'holder',
    'ccp',           v->>'ccp',
    'baridimob',     v->>'baridimob',
    'eur_rate',      v->>'eur_rate',
    'iban',          v->>'iban',
    'swift',         v->>'swift',
    'iban_holder',   v->>'iban_holder',
    'binance_id',    v->>'binance_id',
    'binance_addr',  v->>'binance_addr',
    'binance_network', v->>'binance_network',
    'redotpay_id',   v->>'redotpay_id',
    'instagram',     v->>'instagram',
    'facebook',      v->>'facebook',
    'whatsapp',      v->>'whatsapp'
  );
END;
$function$;
