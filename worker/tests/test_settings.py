"""Environment loading for bind address, token, and loopback model servers."""

from __future__ import annotations

import pytest

from chunky_worker.settings import Settings, is_loopback_url, load_token


TOKEN_ENV = [
    "CHUNKY_WORKER_TOKEN",
    "CHUNKY_WORKER_TOKEN_FILE",
    "CHUNKY_WORKER_HOST",
    "CHUNKY_WORKER_PORT",
    "CHUNKY_OLLAMA_URL",
    "CHUNKY_VLLM_URL",
    "CHUNKY_VLM_ENGINE",
    "XDG_CONFIG_HOME",
]


@pytest.fixture
def clean_env(monkeypatch):
    for name in TOKEN_ENV:
        monkeypatch.delenv(name, raising=False)
    # Keep the default token path from pointing at a real home directory.
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")


def test_defaults_are_loopback(clean_env):
    settings = Settings.from_env()
    assert settings.host == "127.0.0.1"
    assert settings.port == 8080
    assert settings.ollama_url == "http://127.0.0.1:11434"
    assert settings.vllm_url == "http://127.0.0.1:8000"
    assert settings.vlm_engine == "vllm"
    assert settings.token is None
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


def test_loopback_detection():
    assert is_loopback_url("http://127.0.0.1:11434")
    assert is_loopback_url("http://localhost:8000/v1")
    assert is_loopback_url("http://[::1]:11434")
    assert not is_loopback_url("http://192.0.2.10:11434")
    assert not is_loopback_url("http://10.0.0.1:11434")
