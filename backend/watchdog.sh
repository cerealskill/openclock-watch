#!/bin/bash
# Watchdog de OpenClock: chequea que el backend esté vivo y avisa por ntfy
# SOLO cuando cambia el estado (arriba<->caído), para no spamear.
# Publica directo a ntfy (no vía el backend) para poder avisar aunque uvicorn esté muerto.
# Se ejecuta desde un LaunchAgent cada pocos minutos.

set -u

BACKEND_DIR="/Users/cereal/Developer/openclock/backend"
ENV_FILE="$BACKEND_DIR/.env"
STATE_FILE="$BACKEND_DIR/.watchdog_state"
LOCAL_URL="http://localhost:8000/watch/health"
PUBLIC_URL="https://open.panicbots.com/watch/health"

# --- Lee config ntfy del .env (sin ejecutar el archivo) ---
val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
NTFY_SERVER="$(val NTFY_SERVER)"; : "${NTFY_SERVER:=https://ntfy.sh}"
NTFY_TOPIC="$(val NTFY_TOPIC)"
NTFY_TOKEN="$(val NTFY_TOKEN)"

[ -z "$NTFY_TOPIC" ] && exit 0   # sin topic, no hay a dónde avisar

push() {  # push <title> <priority> <tags> <message>
  local args=(-s -o /dev/null -H "Title: $1" -H "Priority: $2" -H "Tags: $3")
  [ -n "$NTFY_TOKEN" ] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl "${args[@]}" -d "$4" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1
}

check() {  # check <url> -> 0 si responde 200 (hasta 3 intentos)
  for _ in 1 2 3; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null)" = "200" ] && return 0
    sleep 2
  done
  return 1
}

if check "$LOCAL_URL"; then
  if check "$PUBLIC_URL"; then STATUS="up"; else STATUS="tunnel"; fi
else
  STATUS="down"
fi

PREV="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
echo "$STATUS" > "$STATE_FILE"

[ "$STATUS" = "$PREV" ] && exit 0   # sin cambio, no molestar

case "$STATUS" in
  down)   push "OpenClock caído" high rotating_light "uvicorn no responde en :8000. El backend de la watch está fuera de servicio." ;;
  tunnel) push "OpenClock: tunnel" high warning "uvicorn está vivo pero la URL pública no responde (tunnel cloudflared o internet)." ;;
  up)     [ "$PREV" != "unknown" ] && push "OpenClock recuperado" default white_check_mark "El backend volvió a responder." ;;
esac

exit 0
