#!/usr/bin/env python3
"""Write a project-only .env for app.py. The API key is read with hidden
input and is never printed."""

import getpass
import os
import sys
from pathlib import Path

from app import DEFAULT_MODEL, ENV_PATH


def main(env_path=ENV_PATH, input_fn=input, getpass_fn=getpass.getpass):
    env_path = Path(env_path)
    if env_path.exists():
        answer = input_fn(f"{env_path.name} already exists. Overwrite? [y/N]: ")
        if answer.strip().lower() != "y":
            print(f"Left existing {env_path.name} unchanged.")
            return 1

    key = getpass_fn("APP_ANTHROPIC_API_KEY (input hidden): ").strip()
    if not key or any(ch.isspace() for ch in key):
        print("No valid key entered; nothing written.")
        return 1

    model = input_fn(f"APP_ANTHROPIC_MODEL [{DEFAULT_MODEL}]: ").strip() or DEFAULT_MODEL

    content = f"APP_ANTHROPIC_API_KEY={key}\nAPP_ANTHROPIC_MODEL={model}\n"
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(env_path, 0o600)
    print(f"Wrote {env_path.name} (key hidden, model: {model}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
