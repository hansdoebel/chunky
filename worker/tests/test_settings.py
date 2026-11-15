"""Environment loading for bind address, token, and loopback model servers."""

from __future__ import annotations

import pytest

from chunky_worker.app import create_app
from chunky_worker.settings import (
    BindWithoutTokenError,
    Settings,
    is_loopback_host,
    is_loopback_url,
    load_token,
    require_token_when_exposed,
)

TOKEN_ENV = [
    "CHUNKY_WORKER_TOKEN",
    "CHUNKY_WORKER_TOKEN_FILE",
    "CHUNKY_WORKER_HOST",
    "CHUNKY_WORKER_PORT",
    "CHUNKY_OLLAMA_URL",
    "CHUNKY_VLLM_URL",
    "CHUNKY_CHART_VLLM_URL",
    "CHUNKY_VLM_ENGINE",
    "CHUNKY_QDRANT_URL",
    "CHUNKY_QDRANT_API_KEY",
    "XDG_CONFIG_HOME",
]

@pytest.fixture
def clean_env(monkeypatch):
    for name in TOKEN_ENV:
        monkeypatch.delenv(name, raising=False)

    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")

def test_defaults_are_loopback(clean_env):
    settings = Settings.from_env()
    assert settings.host == "127.0.0.1"
    assert settings.port == 8080
    assert settings.ollama_url == "http://127.0.0.1:11434"
    assert settings.vllm_url == "http://127.0.0.1:8000"
    assert settings.vlm_engine == "vllm"
    assert settings.token is None
    assert settings.qdrant_url == ""
    assert settings.qdrant_api_key == ""
    assert is_loopback_url(settings.ollama_url)
    assert is_loopback_url(settings.vllm_url)

def test_bind_host_and_port_are_configurable(clean_env, monkeypatch):
    monkeypatch.setenv("CHUNKY_WORKER_HOST", "192.0.2.10")
    monkeypatch.setenv("CHUNKY_WORKER_PORT", "9090")
    monkeypatch.setenv("CHUNKY_OLLAMA_URL", "http://127.0.0.1:11434")
    monkeypatch.setenv("CHUNKY_VLLM_URL", "http://localhost:8000")
    settings = Settings.from_env()
    assert settings.host == "192.0.2.10"
    assert settings.port == 9090
    assert is_loopback_url(settings.vllm_url)

def test_env_token_overrides_file(clean_env, monkeypatch, tmp_path):
    token_file = tmp_path / "worker.token"
    token_file.write_text("from-file\n", encoding="utf-8")
    monkeypatch.setenv("CHUNKY_WORKER_TOKEN_FILE", str(token_file))
    monkeypatch.setenv("CHUNKY_WORKER_TOKEN", "from-env")
    assert load_token() == "from-env"
    assert Settings.from_env().token == "from-env"

def test_token_file_used_when_env_unset(clean_env, monkeypatch, tmp_path):
    token_file = tmp_path / "worker.token"
    token_file.write_text("  from-file \n", encoding="utf-8")
    monkeypatch.setenv("CHUNKY_WORKER_TOKEN_FILE", str(token_file))
    assert load_token() == "from-file"

def test_empty_env_token_does_not_fall_back_to_file(clean_env, monkeypatch, tmp_path):
    token_file = tmp_path / "worker.token"
    token_file.write_text("from-file\n", encoding="utf-8")
    monkeypatch.setenv("CHUNKY_WORKER_TOKEN_FILE", str(token_file))
    monkeypatch.setenv("CHUNKY_WORKER_TOKEN", "   ")
    assert load_token() is None

def test_missing_explicit_token_file_raises(clean_env, monkeypatch, tmp_path):
    monkeypatch.setenv("CHUNKY_WORKER_TOKEN_FILE", str(tmp_path / "missing.token"))
    with pytest.raises(FileNotFoundError):
        load_token()

def test_default_config_file_is_read(clean_env, monkeypatch, tmp_path):
    config = tmp_path / "chunky"
    config.mkdir()
    (config / "worker.token").write_text("xdg-token\n", encoding="utf-8")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert load_token() == "xdg-token"

def test_vlm_engine_from_env(clean_env, monkeypatch):
    monkeypatch.setenv("CHUNKY_VLM_ENGINE", "Transformers")
    assert Settings.from_env().vlm_engine == "transformers"

def test_mlx_vlm_engine_is_rejected(clean_env, monkeypatch):
    monkeypatch.setenv("CHUNKY_VLM_ENGINE", "mlx")
    with pytest.raises(ValueError, match="vllm"):
        Settings.from_env()

def test_qdrant_target_from_env_stays_out_of_repr(clean_env, monkeypatch):
    monkeypatch.setenv("CHUNKY_QDRANT_URL", "https://example.cloud.qdrant.io")
    monkeypatch.setenv("CHUNKY_QDRANT_API_KEY", "secret-key")
    settings = Settings.from_env()
    assert settings.qdrant_url == "https://example.cloud.qdrant.io"
    assert settings.qdrant_api_key == "secret-key"
    assert "secret-key" not in repr(settings)

@pytest.mark.parametrize("host", ["127.0.0.1", "localhost", "::1", "  [::1]  "])
def test_loopback_bind_starts_without_a_token(host):
    settings = Settings(host=host, token=None)
    require_token_when_exposed(settings)
    assert is_loopback_host(host)

@pytest.mark.parametrize("host", ["0.0.0.0", "::", "192.0.2.10", "100.64.1.2", "devbox.tailnet.ts.net"])
def test_exposed_bind_refuses_to_start_without_a_token(host):
    settings = Settings(host=host, port=9090, token=None)
    with pytest.raises(BindWithoutTokenError, match="CHUNKY_WORKER_TOKEN"):
        require_token_when_exposed(settings)

def test_exposed_bind_starts_when_a_token_is_set():
    settings = Settings(host="100.64.1.2", token="secret-token")
    require_token_when_exposed(settings)

def test_create_app_refuses_exposed_bind_without_a_token(tmp_path):
    settings = Settings(host="0.0.0.0", log_dir=tmp_path, work_dir=tmp_path, token=None)
    with pytest.raises(BindWithoutTokenError):
        create_app(settings)

def test_loopback_detection():
    assert is_loopback_url("http://127.0.0.1:11434")
    assert is_loopback_url("http://localhost:8000/v1")
    assert is_loopback_url("http://[::1]:11434")
    assert not is_loopback_url("http://192.0.2.10:11434")
    assert not is_loopback_url("http://10.0.0.1:11434")
