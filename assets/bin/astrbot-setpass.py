"""Reset the AstrBot dashboard password using AstrBot's own hashing.

Reads settings from environment (never argv, so the password is not visible
in the process list):
  ASTRBOT_ROOT    - AstrBot data root (contains data/cmd_config.json)
  NBOT_NEW_USER   - optional new dashboard username (default: keep current)
  NBOT_NEW_PASS   - the new plaintext password

Uses astrbot.cli.commands.cmd_conf._set_dashboard_password so the stored
hashes match exactly what this AstrBot version expects (pbkdf2_sha256 + md5
legacy field + migration flags). Runs under the AstrBot venv python with
PYTHONPATH pointing at <root>/app.
"""

import json
import os
import sys


def main():
    root = os.environ.get("ASTRBOT_ROOT")
    if not root:
        print("[setpass] ASTRBOT_ROOT not set")
        return 3
    new_pass = os.environ.get("NBOT_NEW_PASS")
    if not new_pass:
        print("[setpass] NBOT_NEW_PASS not set")
        return 3
    new_user = os.environ.get("NBOT_NEW_USER")

    config_path = os.path.join(root, "data", "cmd_config.json")
    if not os.path.isfile(config_path):
        print("[setpass] cmd_config.json not found: " + config_path)
        return 3

    # AstrBot's own helpers guarantee the hash format matches this version.
    from astrbot.cli.commands.cmd_conf import _set_dashboard_password
    from astrbot.core.utils.auth_password import validate_dashboard_password

    try:
        validate_dashboard_password(new_pass)
    except Exception as exc:  # noqa: BLE001
        print("[setpass] password rejected: " + str(exc))
        return 4

    # utf-8-sig: 配置文件可能带 BOM，用 utf-8 读会抛 "Unexpected UTF-8 BOM"。
    with open(config_path, "r", encoding="utf-8-sig") as fh:
        config = json.load(fh)

    dashboard = config.setdefault("dashboard", {})
    if new_user:
        dashboard["username"] = new_user

    _set_dashboard_password(config, new_pass)

    temp_path = config_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(temp_path, config_path)
    print("[setpass] OK username=" + str(dashboard.get("username")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print("[setpass] error: %r" % (exc,))
        sys.exit(1)
