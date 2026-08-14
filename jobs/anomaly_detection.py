#!/usr/bin/env python3
"""Find anomalous network flows in the raw telemetry and write them to curated.

Run on a transient EMR cluster as a Spark step:

    spark-submit anomaly_detection.py \
        --raw-uri     s3://.../telemetry/ \
        --curated-uri s3://.../anomalies/

The detection is deliberately simple statistics rather than a model. Two
signals, combined:

  1. Byte volume that is extreme *for the source host* -- a modified z-score
     over each srcaddr's own flows. Comparing a host against itself matters:
     a backup server moving 200 MB is normal, a print server doing the same
     is not, and a single global threshold cannot tell them apart.

  2. Destination ports that no ordinary client should be dialling.

Why the *modified* z-score (median and MAD) rather than mean and standard
deviation: the mean and stddev are themselves dragged upward by the outliers
you are hunting. One 500 MB exfiltration inflates the standard deviation
enough to hide itself inside one sigma. The median and median absolute
deviation barely move, so the outlier stays outlier-shaped. This is the whole
reason the job is not three lines of `where bytes > avg(bytes) * 3`.

Output is Parquet partitioned by date -- columnar, compressed, and typed, so
the Athena queries in Phase 5 scan a fraction of what the raw JSON costs.
"""

from __future__ import annotations

import argparse
import sys

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# Ports a normal internal client has no business connecting to outbound.
SUSPICIOUS_PORTS = [4444, 6667, 31337, 8888, 9001, 1337]

# 0.6745 is the 0.75 quantile of the standard normal. Dividing by it scales
# the MAD so that, for normally distributed data, the modified z-score is
# comparable to an ordinary one. 3.5 is Iglewicz and Hoaglin's conventional
# cutoff.
MAD_SCALE = 0.6745


def build_session(app_name: str) -> SparkSession:
    return (
        SparkSession.builder.appName(app_name)
        # Let Spark discover the dt=... directories as a partition column.
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic")
        .getOrCreate()
    )


def score_by_source(flows: DataFrame) -> DataFrame:
    """Attach a modified z-score of `bytes`, computed within each srcaddr."""
    by_src = Window.partitionBy("srcaddr")

    with_median = flows.withColumn(
        "src_median_bytes",
        F.expr("percentile_approx(bytes, 0.5)").over(by_src),
    )

    # MAD = median(|x - median|), computed in a second pass over the same
    # window because it depends on the median from the first.
    with_mad = with_median.withColumn(
        "src_mad_bytes",
        F.expr("percentile_approx(abs(bytes - src_median_bytes), 0.5)").over(by_src),
    )

    # Guard the divide: a host whose flows are all identical has MAD 0, and
    # every one of its flows would otherwise score as infinitely anomalous.
    return with_mad.withColumn(
        "bytes_mod_zscore",
        F.when(
            F.col("src_mad_bytes") > 0,
            (F.col("bytes") - F.col("src_median_bytes")) / (F.col("src_mad_bytes") / F.lit(MAD_SCALE)),
        ).otherwise(F.lit(0.0)),
    )


def flag(flows: DataFrame, zscore_threshold: float) -> DataFrame:
    volume_anomaly = F.col("bytes_mod_zscore") > zscore_threshold
    port_anomaly = F.col("dstport").isin(SUSPICIOUS_PORTS)

    return (
        flows.withColumn("volume_anomaly", volume_anomaly)
        .withColumn("port_anomaly", port_anomaly)
        .withColumn(
            "anomaly_reason",
            F.concat_ws(
                "+",
                F.when(volume_anomaly, F.lit("volume")),
                F.when(port_anomaly, F.lit("port")),
            ),
        )
        .withColumn("detected", volume_anomaly | port_anomaly)
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-uri", required=True, help="s3:// prefix holding the dt=... partitions.")
    parser.add_argument("--curated-uri", required=True, help="s3:// prefix to write Parquet results to.")
    parser.add_argument(
        "--zscore-threshold",
        type=float,
        default=3.5,
        help="Modified z-score above which a flow counts as a volume anomaly (default 3.5).",
    )
    args = parser.parse_args(argv)

    spark = build_session("yefter-iia-anomaly-detection")
    spark.sparkContext.setLogLevel("WARN")

    raw = spark.read.json(args.raw_uri)
    total = raw.count()
    if total == 0:
        print(f"No records found under {args.raw_uri}", file=sys.stderr)
        spark.stop()
        return 1

    print(f"read {total:,} flows from {args.raw_uri}")

    scored = flag(score_by_source(raw), args.zscore_threshold)
    anomalies = scored.filter(F.col("detected"))

    found = anomalies.count()
    print(f"flagged {found:,} anomalous flows ({found / total:.2%})")

    # The generator labels the records it made anomalous, so the job can be
    # scored against ground truth. Real telemetry has no such column; this is
    # a property of synthetic data and is why the check is conditional.
    if "is_anomaly" in raw.columns:
        truth = raw.filter(F.col("is_anomaly")).count()
        caught = anomalies.filter(F.col("is_anomaly")).count()
        precision = caught / found if found else 0.0
        recall = caught / truth if truth else 0.0
        print(f"ground truth: {truth:,} planted | caught {caught:,} | precision {precision:.1%} | recall {recall:.1%}")

    (
        anomalies.select(
            "dt",
            "srcaddr",
            "dstaddr",
            "srcport",
            "dstport",
            "protocol_name",
            "packets",
            "bytes",
            "action",
            "bytes_mod_zscore",
            "volume_anomaly",
            "port_anomaly",
            "anomaly_reason",
        )
        .repartition("dt")
        .write.mode("overwrite")
        .partitionBy("dt")
        .parquet(args.curated_uri)
    )

    print(f"wrote {found:,} rows to {args.curated_uri}")
    spark.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
