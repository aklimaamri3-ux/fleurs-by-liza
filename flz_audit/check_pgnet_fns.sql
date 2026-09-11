select proname, pg_get_function_arguments(oid) from pg_proc where pronamespace=(select oid from pg_namespace where nspname='net');
