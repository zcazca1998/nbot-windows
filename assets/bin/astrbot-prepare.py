"""Prepare AstrBot before launch.

Windows port of the Linux astrbot-prepare script:
  * run ``astrbot.cli init`` once when data/cmd_config.json does not exist yet
  * keep dashboard.port in sync with ASTRBOT_PORT from nbot.conf

Runs under the AstrBot venv python (sys.executable). Any failure is printed
but the exit code stays 0 so that a broken prepare step never blocks the
actual launch.
"""

import json
import os
import re
import subprocess
import sys

CONF_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def read_conf():
    """Parse %ProgramData%\\nbot\\nbot.conf into a dict."""
    conf = {}
    program_data = os.environ.get("ProgramData", r"C:\ProgramData")
    path = os.path.join(program_data, "nbot", "nbot.conf")
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            for line in fh:
                match = CONF_LINE.match(line.rstrip("\r\n"))
                if match:
                    conf[match.group(1)] = match.group(2)
    except OSError:
        pass
    return conf


def setting(name, conf, default=None):
    """Environment variables win (the launch .bat sets every config key)."""
    value = os.environ.get(name)
    if value:
        return value
    return conf.get(name, default)


def main():
    conf = read_conf()
    root = setting("ASTRBOT_ROOT", conf)
    if not root:
        print("[astrbot-prepare] ASTRBOT_ROOT is not configured; skipping")
        return
    port = int(setting("ASTRBOT_PORT", conf, "6185"))

    config_path = os.path.join(root, "data", "cmd_config.json")
    if not os.path.isfile(config_path):
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.join(root, "app")
        # astrbot.cli init prompts "Install AstrBot to this directory? [Y/n]".
        # A scheduled task has no interactive stdin, so feed the confirmation
        # through a pipe and never let init block the launch chain.
        try:
            subprocess.run(
                [sys.executable, "-m", "astrbot.cli", "init"],
                cwd=root,
                env=env,
                check=False,
                input="Y\n",
                encoding="utf-8",
                errors="replace",
                timeout=300,
            )
        except subprocess.TimeoutExpired:
            print("[astrbot-prepare] astrbot.cli init timed out; killed")
        if not os.path.isfile(config_path):
            # First launch of the main program will generate the config.
            print("[astrbot-prepare] cmd_config.json still missing after init;"
                  " leaving first-time setup to the main program")
            return

    with open(config_path, "r", encoding="utf-8") as fh:
        config = json.load(fh)
    dashboard = config.setdefault("dashboard", {})
    if dashboard.get("port") == port:
        return
    dashboard["port"] = port
    temp_path = config_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(temp_path, config_path)
    print("[astrbot-prepare] dashboard.port set to %d" % port)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - prepare must never block launch
        print("[astrbot-prepare] error (ignored): %r" % (exc,))
    sys.exit(0)
