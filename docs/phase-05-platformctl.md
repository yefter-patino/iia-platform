# Phase 5 — platformctl

A small operator CLI, and the first phase whose real subject is testing.

## Commands

```
platformctl status               what exists in the lake and how big it is
platformctl partitions           partitions present in the raw bucket
platformctl crawl --wait         run a Glue crawler
platformctl tables               tables in the catalog
platformctl query SQL            run Athena SQL, print a table
platformctl anomalies --top N    the worst flows Phase 4 found
platformctl secret show          metadata, never the value
platformctl secret set K=V       store a JSON payload
platformctl secret get --reveal  print the value, deliberately awkward
```

## Every function takes a client

This is the design decision the whole phase rests on:

```python
def summarize_bucket(s3, bucket: str, prefix: str = "") -> BucketSummary:
```

not

```python
def summarize_bucket(bucket: str):
    s3 = boto3.client("s3")     # untestable without patching
```

A module that constructs its own client can only be tested by monkeypatching
`boto3.client`, and then the test is partly asserting that the patch worked.
Passing the client in means the test hands it a moto-backed one and the
production code never knows it is being tested.

It also makes the dependency honest: reading the signature tells you the
function talks to S3.

## What moto is and is not good for

moto intercepts boto3 at the HTTP layer, so `summarize_bucket` runs against a
real `boto3` client that happens to be talking to a fake S3. No credentials, no
network, no cost, ~6 seconds for 38 tests.

`conftest.py` sets **fake credentials** before every test:

```python
monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
monkeypatch.delenv("AWS_PROFILE", raising=False)
```

Without this, a test whose mock does not cover some call can fall through to
whatever real credentials the machine has. A test suite that can reach a real
account is worse than one that fails.

**Athena is tested with a hand-written stub instead.** moto's Athena support
returns canned results and does not model query state transitions, so a test
against it would mostly assert moto's behaviour. The stub makes the actual
requirements explicit and checkable:

- keep polling while `QUEUED` or `RUNNING`
- raise on `FAILED` *and* on `CANCELLED` — the second is what a workgroup scan
  ceiling produces, so it is a real path, not a theoretical one
- strip the header row Athena returns as the first row
- pass the workgroup through, since that is what applies the ceiling

Knowing when a mocking library is the wrong tool is worth as much as knowing
how to use one.

## Sleeping is injected

```python
def wait_for_crawler(glue, name, timeout=900, interval=10, sleep=time.sleep):
```

Tests pass `sleep=lambda _: None`, so the timeout path runs instantly. A suite
that takes real minutes to test its own waiting logic is a suite people stop
running.

## The secret command is deliberately awkward

`platformctl secret get` refuses to print anything without `--reveal`.

Secrets end up in shell history, terminal scrollback and CI logs mostly because
a tool made that the path of least resistance. `describe_secret` returns
metadata and has a test asserting the value never appears in its output.

## Configuration

Resolution order: explicit argument, then environment variable, then
`terraform output`. Terraform is last because shelling out is slow; it is there
at all because typing bucket names containing an account ID is how typos
happen. `config.py` makes no AWS calls, so it stays trivially testable.

## Done when

`pytest` passes with no credentials configured, and the same commands work
against the real account.

```
38 passed in 5.76s
```

## Things that broke / things learned

- Deciding not to use moto for Athena took longer than using it would have, and
  produced better tests.
- `python3.9` is the system Python here and boto3 drops support for it in April
  2026. CI runs 3.12; `requires-python` records the floor.
