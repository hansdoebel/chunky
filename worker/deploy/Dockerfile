FROM oven/bun:1.4.4-debian@sha256:93d5032fe06d163427822dc1598f420363759bb18155c9cc90eb1be05a64a19e AS bun-runtime

FROM node:26.13.1-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1 AS web-builder
COPY --from=bun-runtime /usr/local/bin/bun /usr/local/bin/bun
WORKDIR /opt/chunky/worker/web
COPY worker/web/package.json worker/web/bun.lock ./
RUN bun install --frozen-lockfile
COPY worker/web/ ./
RUN bun run build

FROM rocm/pytorch:rocm10.1.0_ubuntu24.04_py3.12_pytorch_release_2.14.0

WORKDIR /opt/chunky
COPY worker/requirements.txt worker/requirements-rocm.txt /opt/chunky/worker/
RUN python3 -c "from importlib.metadata import version; print('torch==' + version('torch'))" > /tmp/rocm-constraints.txt \
    && python3 -m pip install --no-cache-dir -c /tmp/rocm-constraints.txt -r worker/requirements-rocm.txt \
    && python3 -c "import torch; assert torch.version.hip, 'ROCm PyTorch is required'"
COPY worker/chunky_worker /opt/chunky/worker/chunky_worker
COPY --from=web-builder /opt/chunky/worker/chunky_worker/web_dist /opt/chunky/worker/chunky_worker/web_dist
COPY worker/pyproject.toml worker/README.md /opt/chunky/worker/
COPY Chunky/Resources/Scripts /opt/chunky/Chunky/Resources/Scripts
RUN python3 -m pip install --no-cache-dir --no-deps ./worker \
    && useradd --create-home --uid 10001 chunky \
    && mkdir -p /var/lib/chunky /home/chunky/.cache \
    && chown -R chunky:chunky /var/lib/chunky /home/chunky/.cache
ENV HOME=/home/chunky \
    XDG_STATE_HOME=/var/lib/chunky \
    HF_HOME=/home/chunky/.cache/huggingface \
    CHUNKY_SCRIPTS_DIR=/opt/chunky/Chunky/Resources/Scripts
USER 10001:10001
ENTRYPOINT ["python3", "-m", "chunky_worker"]
