select relname, relrowsecurity, relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relkind='r' order by relname;
