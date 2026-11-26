"""Tests for setup_env.py. No real terminal input and no API calls."""

import stat
from pathlib import Path

import app
import setup_env

SECRET = "sk-test-SECRET-do-not-print-123"
HERE = Path(__file__).resolve().parent


def answers(*values):
    it = iter(values)
    return lambda prompt="": next(it)


def test_writes_key_without_printing_it(tmp_path, capsys):
    env_file = tmp_path / ".env"
    code = setup_env.main(env_file, input_fn=answers(""), getpass_fn=answers(SECRET))
    captured = capsys.readouterr()

    assert code == 0
    assert SECRET not in captured.out and SECRET not in captured.err
    assert env_file.read_text() == (
        f"APP_ANTHROPIC_API_KEY={SECRET}\nAPP_ANTHROPIC_MODEL={app.DEFAULT_MODEL}\n"
    )
    assert stat.S_IMODE(env_file.stat().st_mode) == 0o600
    assert app.get_config({}, env_file) == (SECRET, app.DEFAULT_MODEL)


def test_custom_model(tmp_path):
    env_file = tmp_path / ".env"
    setup_env.main(env_file, input_fn=answers("my-model"), getpass_fn=answers(SECRET))
    assert "APP_ANTHROPIC_MODEL=my-model\n" in env_file.read_text()


def test_existing_env_kept_unless_confirmed(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("original\n")
    code = setup_env.main(env_file, input_fn=answers("n"), getpass_fn=answers(SECRET))
    assert code == 1
    assert env_file.read_text() == "original\n"


def test_empty_key_writes_nothing(tmp_path):
    env_file = tmp_path / ".env"
    assert setup_env.main(env_file, input_fn=answers(""), getpass_fn=answers("")) == 1
    assert not env_file.exists()


def test_env_example_has_placeholders_only():
    text = (HERE / ".env.example").read_text()
    assert "APP_ANTHROPIC_API_KEY=your-app-api-key-here" in text
    assert "sk-" not in text


def test_gitignore_excludes_secrets_and_caches():
    lines = (HERE / ".gitignore").read_text().split()
    for entry in (".env", ".venv/", "__pycache__/", ".pytest_cache/"):
        assert entry in lines
