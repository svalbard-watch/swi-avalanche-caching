# Stage 1: Dependency resolution
FROM astral/uv:python3.14-bookworm-slim AS uv
WORKDIR /swi
COPY pyproject.toml uv.lock ./
# Export the locked, hashed set: the image installs exactly what uv.lock pins.
RUN uv export --frozen --no-dev --no-emit-project -o requirements.txt

# Stage 2: Build
FROM python:3.14-slim AS builder
WORKDIR /swi
COPY --from=uv /swi/requirements.txt .
# Install system dependencies required by rasterio
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgdal-dev \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --require-hashes -r requirements.txt

# Stage 3: Runtime, on the shared cron base image (swi-cron-base). It provides the unprivileged
# swi user (uid/gid 9001, shared with the other SWI images that use the same volumes), /swi, the
# run lock, the entrypoint and the healthcheck; see https://github.com/svalbard-watch/swi-cron-base
# Its tag must match the Python version of the builder stage above.
FROM ghcr.io/svalbard-watch/swi-cron-base:1.0.0-py3.14

# System packages need root; the base image ends with USER swi.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgdal-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy only necessary files from the builder stage
COPY --from=builder /usr/local/lib/python3.14/site-packages /usr/local/lib/python3.14/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
# The job never installs packages at runtime: remove the pip, setuptools and wheel that came with
# the builder's site-packages (and pip's vendored copies of urllib3, msgpack, certifi, ...), so
# they are neither exposed nor flagged by image scanners. The base image has none of them.
RUN python -m pip uninstall -y pip setuptools wheel 2>/dev/null || true

# The job writes next to its code (app.log, ./maps) and into three volumes. Create the
# mount points owned by the job user: an empty named volume inherits the ownership of the
# directory it is mounted on, so a fresh volume is writable without any runtime chown.
RUN mkdir -p /swi/data /swi/metadata /swi/static \
    && chown swi:swi /swi/data /swi/metadata /swi/static

# Copy application code (stays owned by root: the job can create files here, not edit code)
COPY . .

# run-cron (from the base image) runs this once per start, one run at a time.
ENV SWI_CRON_COMMAND="python /swi/main.py"

USER swi
