select policyname, cmd, qual from pg_policies where schemaname='storage' and tablename='objects' order by policyname;
