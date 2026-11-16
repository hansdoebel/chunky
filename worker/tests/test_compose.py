from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest


DEPLOY = Path(__file__).resolve().parents[1] / "deploy"


@pytest.fixture(scope="module")
def compose_config():
    if not shutil.which("docker"):
        pytest.skip("Docker Compose CLI is needed for configuration validation only")
    env = {
        **os.environ,
        "CHUNKY_BIND_IP": "127.0.0.1",
        "CHUNKY_VLM_ENGINE": "transformers",
        "CHUNKY_QDRANT_URL": "",
        "CHUNKY_TOKEN_FILE": "/tmp/chunky-compose-unit-token",
        "CHUNKY_VIDEO_GID": "44",
        "CHUNKY_RENDER_GID": "109",
    }
    result = subprocess.run(
        ["docker", "compose", "--profile", "vllm", "--profile", "qdrant", "config", "--format", "json"],
        cwd=DEPLOY,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def test_only_worker_port_is_published_and_backends_use_loopback(compose_config):
    services = compose_config["services"]
    assert services["worker"]["ports"] == [
        {"mode": "ingress", "host_ip": "127.0.0.1", "target": 8080, "published": "8080", "protocol": "tcp"}
    ]
    for name in ("ollama", "vllm", "qdrant"):
        assert not services[name].get("ports")
        assert services[name]["network_mode"] == "service:worker"
    assert services["ollama"]["environment"]["OLLAMA_HOST"] == "127.0.0.1:11434"
    assert services["qdrant"]["environment"]["QDRANT__SERVICE__HOST"] == "127.0.0.1"
    command = services["vllm"]["command"]
    assert command[command.index("--host") + 1] == "127.0.0.1"


def test_optional_profiles_and_persistent_data(compose_config):
    services = compose_config["services"]
    assert not services["worker"].get("profiles")
    assert not services["ollama"].get("profiles")
    assert services["vllm"]["profiles"] == ["vllm"]
    assert services["qdrant"]["profiles"] == ["qdrant"]
    for service in services.values():
        assert all(volume["type"] == "volume" for volume in service.get("volumes", []))
    assert len(compose_config["volumes"]) == 5


def test_worker_requires_file_token_and_gpu_access(compose_config):
    worker = compose_config["services"]["worker"]
    env = worker["environment"]
    assert env["CHUNKY_WORKER_TOKEN_FILE"] == "/run/secrets/worker_token"
    assert "CHUNKY_WORKER_TOKEN" not in env
    assert env["CHUNKY_VLM_ENGINE"] == "transformers"
    assert env["CHUNKY_EMBEDDING_MODEL"] == "qwen3-embedding:0.6b"
    assert worker["secrets"][0]["source"] == "worker_token"
    assert compose_config["secrets"]["worker_token"]["file"] == "/tmp/chunky-compose-unit-token"
    for name in ("worker", "ollama", "vllm"):
        assert {device["source"] for device in compose_config["services"][name]["devices"]} == {"/dev/kfd", "/dev/dri"}
    assert set(worker["group_add"]) == {"44", "109"}


@pytest.mark.parametrize("missing", ["CHUNKY_BIND_IP", "CHUNKY_TOKEN_FILE", "CHUNKY_VIDEO_GID", "CHUNKY_RENDER_GID"])
def test_compose_refuses_missing_required_settings(missing):
    if not shutil.which("docker"):
        pytest.skip("Docker Compose CLI is needed for configuration validation only")
    env = {**os.environ, "CHUNKY_BIND_IP": "127.0.0.1", "CHUNKY_VIDEO_GID": "44", "CHUNKY_RENDER_GID": "109", "CHUNKY_TOKEN_FILE": "/tmp/chunky-compose-unit-token"}
    env[missing] = ""
    result = subprocess.run(
        ["docker", "compose", "config", "--quiet"],
        cwd=DEPLOY,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert missing in result.stderr


def test_upstream_images_have_version_tags(compose_config):
    images = [
        service["image"]
        for name, service in compose_config["services"].items()
        if name != "worker"
    ]
    base = (DEPLOY / "Dockerfile").read_text().splitlines()[0].split()[1]
    for image in [base, *images]:
        assert ":" in image
        assert image.rsplit(":", 1)[1] not in {"latest", "rocm", "main", "nightly"}
