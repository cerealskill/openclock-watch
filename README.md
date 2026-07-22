# 🦞 OpenClock

**Un cliente de voz para tu Apple Watch, conectado al agente que tú controlas.**

OpenClock convierte tu Watch en un asistente de voz de pantalla completa: mantienes pulsado el micrófono, hablas, y la respuesta llega en streaming — frase a frase, con voz. En lugar de depender de un asistente cerrado, el reloj habla con un **backend propio** que tú alojas y que puede apuntar a cualquier endpoint **compatible con la API de OpenAI** (self-hosted o comercial).

> Pensado para la corriente *BYO-backend* ("trae tu propio backend"): tú eliges el modelo y dónde corre. El código del backend es abierto; la app es un cliente delgado.

---

## ✨ Características

- 🎙️ **Voz de extremo a extremo** — grabas, se transcribe local con `faster-whisper` (~2 s) y la respuesta se lee en voz alta.
- ⚡ **Streaming SSE frase a frase** — la voz empieza antes de que termine de generarse toda la respuesta.
- 🔘 **Botón de Acción** — lanza la escucha vía App Intents, sin abrir la app.
- 🔄 **Auto-envío** — soltar el micrófono envía; parar muestra vista previa. Barge-in para interrumpir.
- 🤫 **Modo silencio, cancelar en curso, teclado** y vista de conversación completa a pantalla completa.
- 🧠 **Resumen rodante por sesión** en el backend, para mantener contexto sin reenviar todo.
- 🗣️ **Comandos de voz**: *"borra el historial"*, *"modo silencio"*, *"activa el sonido"*, *"avísame…"*.
- 🔔 **Notificaciones push** vía [ntfy](https://ntfy.sh) (sin APNs): recordatorios, resumen diario y watchdog del backend.

## 🧩 Las tres apps de reloj

OpenClock incluye tres esquemas de Watch App que comparten el mismo cliente y difieren solo en el backend al que apuntan:

| App | Backend | Endpoint |
|-----|---------|----------|
| **OpenClock** | Cualquier API compatible con OpenAI (OpenClaw, Ollama, LM Studio, OpenRouter…) | `/watch/*` |
| **HermesClock** | [Hermes Agent](https://github.com/) (API OpenAI-compatible) | `/hermes/*` |
| **ClaudeClock** | API nativa de Anthropic (Claude Messages) | `/claude/*` |

> Los nombres *HermesClock* y *ClaudeClock* describen compatibilidad, no afiliación. Marca propia: **OpenClock** 🦞.

---

## 🏗️ Arquitectura

```
Apple Watch  ──HTTPS──►  Cloudflare Tunnel  ──►  Backend FastAPI (Mac/servidor)  ──►  Tu agente LLM
 (SwiftUI)                (open.tudominio)         (backend/server.py)                 (OpenAI-compat)
   │                                                     │
   └── graba audio                                       ├── faster-whisper (transcripción local)
   └── reproduce voz en streaming                        ├── streaming SSE frase a frase
                                                         ├── resumen rodante por sesión
                                                         └── push vía ntfy
```

---

## 🚀 Puesta en marcha

### 1. Backend

Requisitos: **Python 3.11+** y un endpoint LLM compatible con OpenAI (o una API key de Anthropic para ClaudeClock).

```bash
cd backend

# Entorno virtual + dependencias
python3 -m venv .venv
source .venv/bin/activate
pip install fastapi uvicorn requests pytz faster-whisper python-multipart

# Configura tus endpoints y tokens
cp .env.example .env
$EDITOR .env        # rellena OPENCLAW_URL / HERMES_API_URL / CLAUDE_API_KEY, etc.

# Arranca el servidor
uvicorn server:app --host 0.0.0.0 --port 8000
```

Comprueba que responde:

```bash
curl http://localhost:8000/watch/health
```

### 2. Exponer el backend (opcional pero recomendado)

Para que el reloj llegue desde cualquier red, publica el puerto 8000 con un túnel. Con Cloudflare Tunnel:

```bash
cloudflared tunnel --url http://localhost:8000
```

Usa la URL resultante (p. ej. `https://open.tudominio.com`) como base en la app.

### 3. Apps de reloj (Xcode)

Requisitos: **Xcode 16+**, watchOS 11+, una Apple Watch (o simulador).

```bash
open OpenClock/OpenClock.xcodeproj
```

1. Ajusta el **Team** de firma en cada target y apunta la URL base del backend en el código del cliente.
2. Elige el esquema que quieras: `OpenClock Watch App`, `HermesClock Watch App` o `ClaudeClock Watch App`.
3. Ejecuta (⌘R) sobre tu reloj.

> **Firma gratuita (sin Developer Program):** las builds caducan a los 7 días. El script `reinstall-watch.sh` recompila e instala por CLI:
> ```bash
> ./reinstall-watch.sh            # OpenClock + HermesClock
> ./reinstall-watch.sh claude     # incluye ClaudeClock
> ```
> Ajusta los UDID de tu reloj al principio del script.

---

## ⚙️ Configuración (`backend/.env`)

Copia `backend/.env.example` y rellena solo lo que uses. Resumen:

| Variable | Para qué |
|----------|----------|
| `OPENCLAW_URL` / `OPENCLAW_TOKEN` / `OPENCLAW_MODEL` | Backend de **OpenClock** (cualquier API OpenAI-compat). |
| `HERMES_API_URL` / `HERMES_API_TOKEN` / `HERMES_MODEL` | Backend de **HermesClock**. |
| `CLAUDE_API_KEY` / `CLAUDE_MODEL` | Backend de **ClaudeClock** (Anthropic). Mantén la key solo en el backend, nunca en la app. |
| `NTFY_SERVER` / `NTFY_TOPIC` / `NTFY_TOKEN` | Push. Genera un topic impredecible (actúa como contraseña); vacío = push desactivado. |

Genera un topic ntfy seguro:

```bash
python3 -c "import secrets; print('openclock-' + secrets.token_hex(8))"
```

---

## 🔔 Servicios auxiliares del backend

Autocontenidos (no cargan el modelo de voz); pensados para correr como `LaunchAgent`/cron:

- **`reminder_dispatcher.py`** — cada ~60 s despacha recordatorios vencidos por ntfy y reprograma los recurrentes.
- **`daily_summary.py`** — envía un resumen diario del rolling summary de cada sesión.
- **`watchdog.sh`** — avisa por ntfy solo cuando el backend cambia de estado (arriba ⇄ caído).

---

## 📡 Endpoints principales

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/watch/health` · `/hermes/health` · `/claude/health` | Salud por backend. |
| `POST` | `/watch/transcribe` · `/hermes/transcribe` · `/claude/transcribe` | Audio → texto (faster-whisper). |
| `POST` | `/watch/chat` · `/hermes/chat` · `/claude/chat` | Respuesta completa. |
| `POST` | `/watch/chat/stream` · `/hermes/chat/stream` | Respuesta en streaming SSE. |
| `POST` | `/watch/reset` · `/hermes/reset` | Borra el resumen rodante de la sesión. |
| `POST` | `/notify` · `/reminders` · `/reminders/snooze` | Push y recordatorios. |

---

## 🔒 Privacidad

Los datos de runtime (`profile.json`, `summaries.json`, `reminders.json`, `.env`) contienen información personal y están excluidos en `.gitignore`. **Nunca los subas a un repo público.**

## 📄 Licencia

**GNU Affero General Public License v3.0 (AGPL-3.0)** — ver [`LICENSE`](LICENSE).

Puedes usar, modificar y redistribuir el proyecto libremente; si lo ofreces como servicio en red, debes publicar también tu código modificado. El titular del copyright se reserva el derecho de ofrecer licencias comerciales alternativas.

Copyright © 2026 [cerealskill](https://github.com/cerealskill).
