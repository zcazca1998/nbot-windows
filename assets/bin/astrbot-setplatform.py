"""Configure AstrBot's aiocqhttp (OneBot v11) platform adapter.

The installer writes NapCat's side (onebot11_<uin>.json) and must configure
AstrBot's side to match, otherwise the reverse WebSocket handshake fails on
token mismatch and the bot never connects.

Environment inputs (never argv, so the token stays out of the process list):
  ASTRBOT_ROOT   - AstrBot data root (contains data/cmd_config.json)
  NBOT_WS_PORT   - reverse WebSocket port AstrBot listens on
  NBOT_WS_TOKEN  - shared OneBot access token
  NBOT_ADAPTER_ID- optional adapter id (default: nbot_napcat)

Idempotent: updates the existing aiocqhttp entry when present, otherwise
appends one; keeps every other platform untouched.
"""

import json
import os
import sys


def main():
    root = os.environ.get("ASTRBOT_ROOT")
    if not root:
        print("[setplatform] ASTRBOT_ROOT not set")
        return 3
    port = os.environ.get("NBOT_WS_PORT")
    if not port:
        print("[setplatform] NBOT_WS_PORT not set")
        return 3
    token = os.environ.get("NBOT_WS_TOKEN", "")
    # 适配器 id 会显示在 AstrBot 的平台列表里，用 QQ 一眼就知道是哪个。
    adapter_id = os.environ.get("NBOT_ADAPTER_ID") or "QQ"

    config_path = os.path.join(root, "data", "cmd_config.json")
    if not os.path.isfile(config_path):
        print("[setplatform] cmd_config.json not found: " + config_path)
        return 3

    # utf-8-sig: AstrBot 写出的 cmd_config.json 带 BOM，用 utf-8 读会抛
    # "Unexpected UTF-8 BOM"。写回时用 utf-8（不带 BOM），AstrBot 两种都能读。
    with open(config_path, "r", encoding="utf-8-sig") as fh:
        config = json.load(fh)

    platforms = config.get("platform")
    if not isinstance(platforms, list):
        platforms = []
        config["platform"] = platforms

    entry = None
    for item in platforms:
        if isinstance(item, dict) and item.get("type") == "aiocqhttp":
            entry = item
            break
    if entry is None:
        entry = {"id": adapter_id, "type": "aiocqhttp"}
        platforms.append(entry)
    else:
        # 已存在的条目：把默认模板 id("default")改成更易识别的名字；
        # 用户自己起过名的就尊重原样，不覆盖。
        current_id = entry.get("id")
        if not current_id or current_id == "default":
            entry["id"] = adapter_id

    entry["enable"] = True
    entry["ws_reverse_host"] = "0.0.0.0"
    entry["ws_reverse_port"] = int(port)
    entry["ws_reverse_token"] = token

    temp_path = config_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(temp_path, config_path)
    print("[setplatform] OK id=%s port=%s token_len=%d"
          % (entry.get("id"), port, len(token)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print("[setplatform] error: %r" % (exc,))
        sys.exit(1)
