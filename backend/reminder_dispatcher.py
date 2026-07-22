#!/usr/bin/env python3
"""Dispatcher de recordatorios de OpenClock. Corre cada ~60s desde un LaunchAgent:
lee reminders.json, envía por ntfy los que ya vencieron, reprograma los recurrentes
y elimina los de una sola vez. Autocontenido (no importa server.py)."""
import json
import os
import time
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote

import pytz
import requests

BASE = Path(__file__).parent
ENV_FILE = BASE / ".env"
REMINDERS_FILE = BASE / "reminders.json"
TZ = pytz.timezone("America/Santiago")
PUBLIC_BASE = os.getenv("OPENCLOCK_PUBLIC_URL", "https://open.panicbots.com")


def load_env():
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def load_reminders():
    if REMINDERS_FILE.exists():
        try:
            return json.loads(REMINDERS_FILE.read_text(encoding="utf-8"))
        except Exception:
            return []
    return []


def save_reminders(items):
    tmp = REMINDERS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(REMINDERS_FILE)


def next_daily(hour, minute):
    now = datetime.now(TZ)
    cand = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if cand <= now:
        cand += timedelta(days=1)
    return int(cand.timestamp())


def next_weekly(weekday, hour, minute):
    now = datetime.now(TZ)
    cand = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    cand += timedelta(days=(weekday - cand.weekday()) % 7)
    if cand <= now:
        cand += timedelta(days=7)
    return int(cand.timestamp())


def fire(note, server, topic, token):
    # Botón "Posponer 10 min" → reprograma vía el endpoint público del backend.
    snooze_url = f"{PUBLIC_BASE}/reminders/snooze?note={quote(note)}&minutes=10"
    headers = {
        "Title": "Rasputina",
        "Priority": "high",
        "Tags": "bell",
        "Actions": f"http, Posponer 10 min, {snooze_url}, method=POST, clear=true",
        "Content-Type": "text/plain; charset=utf-8",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        requests.post(f"{server}/{topic}", data=note.encode("utf-8"), headers=headers, timeout=10).raise_for_status()
        print(f"[dispatch] enviado: '{note}'")
    except Exception as e:
        print(f"[dispatch] error enviando '{note}': {e}")


def main():
    load_env()
    server = os.getenv("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
    topic = os.getenv("NTFY_TOPIC", "").strip()
    token = os.getenv("NTFY_TOKEN", "").strip()
    if not topic:
        return

    items = load_reminders()
    if not items:
        return
    now = time.time()
    changed = False
    kept = []
    for r in items:
        if r.get("when", 0) > now:
            kept.append(r)
            continue
        fire(r.get("note", "recordatorio"), server, topic, token)
        changed = True
        recur = r.get("recur")
        if recur == "daily":
            r["when"] = next_daily(r["hour"], r["minute"])
            kept.append(r)
        elif recur == "weekly":
            r["when"] = next_weekly(r["weekday"], r["hour"], r["minute"])
            kept.append(r)
        # one-shot → se descarta
    if changed:
        save_reminders(kept)


if __name__ == "__main__":
    main()
