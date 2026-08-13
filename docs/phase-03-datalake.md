# Phase 3 — Data Lake

The phase where the project stops being empty infrastructure and starts holding
data. It is also the first phase that can leak money without anyone noticing,
so the cost decisions are written down next to the design ones.

## The shape

```
S3 raw       the bytes            telemetry/dt=2026-08-13/flows-000.json
Glue catalog the schema           database yefter_dev_lake, table telemetry
Athena       the query engine     SQL over the files, owns neither
```

Nothing is loaded into a database. The crawler reads a sample of the files,
writes a table definition into the catalog, and from then on Athena reads those
same S3 objects as if they were a table.

That indirection is the whole idea. The files stay in one place and open
formats; Athena reads them today, the Phase 4 PySpark job reads the same bytes
without moving them. A warehouse would have required loading the data in first,
and then the warehouse would own it.

## Newline-delimited JSON, not a JSON array

The generator writes one record per line rather than a single `[...]` array.

Every engine that reads a lake splits files on newlines so workers can read
different byte ranges of the same file in parallel. A single JSON array is one
indivisible value — a 10 GB array is read by exactly one worker. The difference
is between a format that scales and one that does not, and it costs nothing to
get right at 1 MB.

## Partitioning is the cost control

Files land under a Hive-style prefix:

```
telemetry/dt=2026-08-11/flows-000.json
telemetry/dt=2026-08-12/flows-000.json
telemetry/dt=2026-08-13/flows-000.json
```

The crawler recognises `dt=` and registers `dt` as a **partition key** rather
than as data. Athena then reads only the prefixes a query needs.

Measured on this dataset:

| Query | Bytes scanned |
|---|---|
| `SELECT count(*) FROM telemetry` | 3,322,669 |
| `... WHERE dt='2026-08-13'` | 1,107,434 |

Exactly one third, because there are three equal partitions. Athena bills per
byte scanned, so at lab scale this is a rounding error and at real scale it is
the entire bill. The habit is worth forming while the stakes are zero.

## The crawler has no schedule, deliberately

`schedule = null`, which means on-demand:

```bash
aws glue start-crawler --name yefter-dev-telemetry
```

A crawler on an hourly cron costs a few dollars a month forever, and nobody
notices because the money is spread thin across the bill. The schema only
changes when you change the generator, so a scheduled crawl is almost always
re-deriving a schema that did not move.

`schedule` is a variable, so a cron can be set when there is a reason for one.

## The Athena scan ceiling

The workgroup sets `bytes_scanned_cutoff_per_query` (1 GiB by default) with
`enforce_workgroup_configuration = true`. A query that would scan more is
cancelled *before* it bills.

The `enforce` flag is what makes this real. Without it, a client can override
the workgroup's settings and the ceiling becomes a suggestion.

Honest caveat: **this ceiling has not been triggered.** The whole dataset is
3.3 MB, so no query can approach 1 GiB. It is configured and the configuration
is verified; the behaviour is not.

## Crawler permissions

`AWSGlueServiceRole` is attached for the catalog and logging side. It grants no
access to your data — AWS cannot know which buckets are yours. The S3 half is
an inline policy scoped to the telemetry prefix:

```
s3:GetObject on   arn:aws:s3:::<raw-bucket>/telemetry/*
s3:ListBucket on  arn:aws:s3:::<raw-bucket>   with condition s3:prefix = telemetry/*
```

The split is worth understanding: `s3:GetObject` is an *object* action so it
takes an object ARN, while `s3:ListBucket` is a *bucket* action and cannot be
scoped with an object path. Trying to write `ListBucket` against
`bucket/prefix/*` silently grants nothing. The prefix condition is how it gets
narrowed instead — a mistake worth making once and never again.

## Bucket settings that are not boilerplate

**`force_destroy` differs per bucket, on purpose.** Raw and curated default to
`false`: raw data is the one thing here that cannot be regenerated, so
`terraform destroy` should fail rather than silently delete it. The Athena
results bucket is `force_destroy = true` unconditionally, because query results
are regenerable by re-running the query and otherwise every `destroy` fails on
leftover result files.

**Lifecycle rules on everything.** Athena writes a result file for every query
including the accidental ones, so results expire after 30 days. Versioning is
on for raw and curated, and non-current versions expire after 30 days —
versioning as a safety net, not an archive that quietly becomes the bill.

## What the crawler got right and what it guessed

Inferred schema:

```
version int, start int, end int, srcaddr string, dstaddr string,
srcport int, dstport int, protocol int, protocol_name string,
packets int, bytes int, action string, log_status string,
is_anomaly boolean
```

Correct throughout, including `boolean`. Two things to notice:

- `start` and `end` are epoch seconds typed as `int`, not `timestamp`. The
  crawler cannot know an integer is a time. Real pipelines fix this with an
  explicit schema or a view.
- `Parameters.recordCount` on the table reads **3169**, while the true count is
  12,000. That number is an estimate from the crawler's sample, not a count.
  Trusting catalog row counts as facts is a good way to be wrong in a meeting.

## Cost

| Thing | Cost |
|---|---|
| S3 storage (3.3 MB) | fractions of a cent |
| Glue Data Catalog | free under a million objects |
| Glue crawler run | ~$0.15 per run (2 DPU minimum, 10-minute minimum billing) |
| Athena | $5/TB scanned, 10 MB minimum per query |

Nothing bills while idle. Three crawler runs and a handful of queries during
this phase cost well under a dollar.

## Done when

`terraform apply` builds the lake, the generator uploads telemetry, one crawler
run produces a table, and Athena answers a real question about it.

Verified:

```
SELECT dt, count(*) AS flows, count_if(is_anomaly) AS anomalies FROM telemetry GROUP BY dt

dt           flows  anomalies
2026-08-11    4000         88
2026-08-12    4000         81
2026-08-13    4000         80
```

12,000 records, 249 anomalous (2.1%), matching what the generator reported it
wrote. Those anomalies — huge byte counts to odd ports — are what the Phase 4
PySpark job goes looking for.

## Things that broke / things learned

> Fill this in as you go. This section is the one interviewers actually want.
> A debugging story beats a clean architecture diagram every time.
