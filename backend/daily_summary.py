#!/usr/bin/env python3
"""Resumen diario de OpenClock: lee el resumen rodante de cada sesión (summaries.json)
y lo manda como push por ntfy. Pensado para correr una vez al día desde un LaunchAgent.
Autocontenido: no importa server.py (evita cargar faster_whisper)."""
import json
import os
from pathlib import Path

import requests

BASE = Path(__file__).parent
ENV_FILE = BASE / ".env"
SUMMARIES_FILE = BASE / "summaries.json"


def load_env():
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        os.environ.setdefault(k, v)


def main():
    load_env()
    server = os.getenv("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
    topic = os.getenv("NTFY_TOPIC", "").strip()
    token = os.getenv("NTFY_TOKEN", "").strip()
    if not topic:
        print("[daily] NTFY_TOPIC no configurado; nada que enviar")
        return

    summaries = {}
    if SUMMARIES_FILE.exists():
        try:
            summaries = json.loads(SUMMARIES_FILE.read_text(encoding="utf-8"))
        except Exception:
            summaries = {}

    partes = [s.strip() for s in summaries.values() if s and s.strip()]
    if not partes:
        cuerpo = "Sin conversaciones registradas. Nada pendiente por ahora."
    else:
        cuerpo = "\n\n".join(partes)

    # Los headers HTTP se codifican como latin-1; evitamos caracteres fuera de rango
    # (guión largo, emojis) en el título para no romper el envío.
    title = "Resumen del dia - OpenClock".encode("latin-1", "replace").decode("latin-1")
    headers = {
        "Title": title,
        "Priority": "default",
        "Tags": "calendar,memo",
        "Content-Type": "text/plain; charset=utf-8",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    resp = requests.post(f"{server}/{topic}", data=cuerpo.encode("utf-8"), headers=headers, timeout=15)
    resp.raise_for_status()
    print(f"[daily] resumen enviado ({len(cuerpo)} chars)")


if __name__ == "__main__":
    main()
