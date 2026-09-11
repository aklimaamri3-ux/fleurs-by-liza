select schemaname, tablename, policyname, cmd, qual, with_check from pg_policies where schemaname in ('public','storage') order by schemaname, tablename, policyname;
