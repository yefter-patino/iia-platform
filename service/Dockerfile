# Multi-stage: build wheels with the toolchain, then copy only the results
# into a runtime image that has no compiler in it. Smaller image, and fewer
# things in the final layer that an attacker could use.

FROM public.ecr.aws/docker/library/python:3.12-slim AS builder

WORKDIR /build

# Dependencies first, in their own layer. This layer is only invalidated when
# the requirements change, so editing app.py does not trigger a reinstall.
COPY service/requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt


FROM public.ecr.aws/docker/library/python:3.12-slim

# Never run as root. If the process is compromised, uid 1000 with no write
# access to the code limits what happens next.
RUN useradd --create-home --uid 1000 app

WORKDIR /app

COPY --from=builder /wheels /wheels
COPY service/requirements.txt .
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

# platformctl is imported by the service: the same lake/catalog/secrets code
# the CLI uses, so behaviour cannot drift between the two.
COPY platformctl/ ./platformctl/
COPY service/ ./service/

USER app

EXPOSE 8000

# Python's default SIGTERM handling in a container is why stopping one often
# takes ten seconds: PID 1 ignores it. uvicorn handles SIGTERM properly, so
# ECS can drain and stop the task promptly.
CMD ["uvicorn", "service.app:app", "--host", "0.0.0.0", "--port", "8000"]
