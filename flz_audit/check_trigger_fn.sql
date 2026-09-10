select pg_get_functiondef(oid) from pg_proc where proname='orders_secure_insert';
