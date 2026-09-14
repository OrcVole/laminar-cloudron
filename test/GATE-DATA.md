# Gate data: how to put real records in, and count them

Gate 3 means the update is proven over real data: records the application stores, counted before the
update, after it, and after a restore. A health check, a sign-in page or a directory existing is not
data. Use at least three records of each kind you count; a count may grow across the update (the app
or a suite can add records), but a count that falls is data loss.

Every command names the Cloudron you are gating. `CLOUDRON_SERVER` is that Cloudron's API host (for
example `my.example.com`); `APP` is the install's location. Never rely on the CLI's default profile.

## laminar

A project API key can only be created in the UI, so seed and count inside the container, in both stores.

ClickHouse (the bundled client, as POSTINSTALL.md documents):

```bash
cloudron --server "$CLOUDRON_SERVER" exec --app "$APP" -- clickhouse-client --query "DESCRIBE TABLE default.spans"
cloudron --server "$CLOUDRON_SERVER" exec --app "$APP" -- clickhouse-client --query "SELECT count() FROM default.spans"
```

Insert at least three synthetic spans with the columns that have no default, then count.

Postgres, with the URL expanding inside the container:

```bash
cloudron --server "$CLOUDRON_SERVER" exec --app "$APP" -- bash -c 'psql "$CLOUDRON_POSTGRESQL_URL" -Atc "select count(*) from users"'
```

Choose a table the migrations do not drop, insert at least three rows that satisfy its constraints,
then count. With a project key from the UI, `test/ingest.sh` drives real OTLP spans at the ingest domain.
