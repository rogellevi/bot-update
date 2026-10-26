#!/usr/bin/env bash
# ==============================================================
#  JSON Manager Bot (Telegram) - Instalador 1 clic
#  Ubuntu 20.04 / 22.04 / 24.04
#  Uso:  sudo bash install.sh
#   o :  sudo bash <(curl -fsSL https://TU_URL/install.sh)
# ==============================================================
set -Eeuo pipefail

APP_DIR="/opt/jsonbot"
APP_USER="jsonbot"
SERVICE="jsonbot"
export DEBIAN_FRONTEND=noninteractive

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
info() { echo -e "${B}[i]${N} $*"; }
ok()   { echo -e "${G}[✔]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[✘]${N} $*" >&2; exit 1; }
trap 'die "Error en la línea $LINENO. Revisa el mensaje anterior."' ERR

# ---------- Comprobaciones ----------
[[ $EUID -eq 0 ]] || die "Ejecuta como root:  sudo bash install.sh"
[[ -r /etc/os-release ]] || die "No se pudo detectar el sistema."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Solo Ubuntu 20.04 / 22.04 / 24.04."
case "${VERSION_ID:-}" in
  20.04|22.04|24.04) ok "Ubuntu ${VERSION_ID} detectado." ;;
  *) die "Versión no soportada (${VERSION_ID:-?}). Usa 20.04, 22.04 o 24.04." ;;
esac

# ---------- Datos del usuario ----------
echo
echo "=============================================="
echo "   JSON Manager Bot · Configuración"
echo "=============================================="

ask() { # ask VAR "texto"
  local __v="$1" __p="$2" __val=""
  while [[ -z "$__val" ]]; do
    read -r -p "$__p" __val </dev/tty || die "No hay terminal interactiva."
    __val="${__val//[[:space:]]/}"
  done
  printf -v "$__v" '%s' "$__val"
}

apt-get update -y >/dev/null
apt-get install -y curl ca-certificates >/dev/null

# Token
while true; do
  ask BOT_TOKEN "▶ Token del bot (de @BotFather): "
  if [[ ! "$BOT_TOKEN" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]]; then
    warn "Formato de token inválido."; continue
  fi
  if curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | grep -q '"ok":true'; then
    ok "Token válido."; break
  else
    warn "Telegram rechazó el token (o no hay internet). Inténtalo de nuevo."
  fi
done

# ID(s) de administrador
while true; do
  ask ADMIN_IDS "▶ Tu ID de Telegram (varios separados por coma): "
  [[ "$ADMIN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]] && break
  warn "Solo números, separados por coma. (Obtén tu ID con @userinfobot)"
done

# Dominio
while true; do
  ask DOMAIN "▶ Dominio (ej: archivos.midominio.com): "
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
  DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z')"
  [[ "$DOMAIN" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] && break
  warn "Dominio inválido."
done

read -r -p "▶ Email para el certificado SSL (opcional, Enter para omitir): " EMAIL </dev/tty || EMAIL=""
EMAIL="${EMAIL//[[:space:]]/}"

# Aviso DNS
SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)"
if [[ -n "$SERVER_IP" && "$SERVER_IP" != "$DOMAIN_IP" ]]; then
  warn "El dominio resuelve a '${DOMAIN_IP:-nada}' pero este servidor es ${SERVER_IP}."
  warn "Apunta el registro A a ${SERVER_IP} para que el SSL funcione. Continúo igualmente."
fi

# ---------- Paquetes ----------
info "Instalando dependencias..."
apt-get install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx >/dev/null
ok "Dependencias instaladas."

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 'Nginx Full' >/dev/null || true
  ufw allow OpenSSH >/dev/null || true
fi

# ---------- Usuario y carpetas ----------
id "$APP_USER" >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR"/{json,backups,tmp}
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
chmod 755 "$APP_DIR" "$APP_DIR/json"
chmod 700 "$APP_DIR/backups" "$APP_DIR/tmp"
ok "Carpeta de archivos: $APP_DIR/json"

# ---------- Entorno Python ----------
info "Creando entorno Python..."
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet "python-telegram-bot==20.8"
ok "Librerías instaladas."

# ---------- Código del bot ----------
cat > "$APP_DIR/bot.py" <<'PYEOF'
import html
import logging
import os
import re
import shutil
from datetime import datetime
from functools import wraps
from pathlib import Path

from telegram import BotCommand, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application, CallbackQueryHandler, CommandHandler,
    ContextTypes, MessageHandler, filters,
)

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
log = logging.getLogger("jsonbot")

TOKEN = os.environ["BOT_TOKEN"]
ADMINS = {int(x) for x in os.environ["ADMIN_IDS"].split(",") if x.strip()}
DOMAIN = os.environ["DOMAIN"]
SCHEME = os.environ.get("SCHEME", "http")
BASE = Path(os.environ.get("BASE_DIR", "/opt/jsonbot"))

JSON_DIR = BASE / "json"
BACKUP_DIR = BASE / "backups"
TMP_DIR = BASE / "tmp"
for d in (JSON_DIR, BACKUP_DIR, TMP_DIR):
    d.mkdir(parents=True, exist_ok=True)

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,45}\.json$")
MAX_BACKUPS = 5
MAX_BYTES = 20 * 1024 * 1024  # límite de descarga de la Bot API


def esc(s): return html.escape(str(s))


def url_for(name): return f"{SCHEME}://{DOMAIN}/json/{name}"


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024 or u == "GB":
            return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1024


def list_files():
    return sorted(
        (p for p in JSON_DIR.iterdir() if p.is_file() and NAME_RE.match(p.name)),
        key=lambda p: p.name.lower(),
    )


def backup(name, tag=""):
    src = JSON_DIR / name
    if not src.exists():
        return
    d = BACKUP_DIR / name
    d.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(src, d / f"{tag}{stamp}")
    for old in sorted(d.iterdir())[:-MAX_BACKUPS]:
        old.unlink()


def save_file(tmp: Path, name: str) -> bool:
    """Guarda sobre el mismo nombre (reemplazo atómico). Devuelve True si existía."""
    dest = JSON_DIR / name
    existed = dest.exists()
    if existed:
        backup(name)
    os.chmod(tmp, 0o644)
    os.replace(tmp, dest)
    return existed


def admin_only(fn):
    @wraps(fn)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        u = update.effective_user
        if not u or u.id not in ADMINS:
            if update.message:
                await update.message.reply_text(f"⛔ No autorizado. Tu ID: {u.id if u else '?'}")
            return
        return await fn(update, context)
    return wrapper


def kb(prefix, files):
    rows = [[InlineKeyboardButton(p.name, callback_data=f"{prefix}:{p.name}")] for p in files]
    rows.append([InlineKeyboardButton("✖ Cancelar", callback_data="cancel:")])
    return InlineKeyboardMarkup(rows)


HELP = (
    "<b>📦 JSON Manager</b>\n\n"
    "• Envía un archivo <code>.json</code> → se guarda (si el nombre ya existe, se <b>actualiza</b>).\n"
    "• /actualizar → elige un archivo y envía el nuevo; <b>conserva el nombre original</b>.\n"
    "• /lista → archivos y sus URLs.\n"
    "• /descargar → recibir un archivo.\n"
    "• /eliminar → borrar un archivo.\n"
    "• /cancelar → cancelar acción en curso.\n\n"
    "Se guardan las últimas 5 versiones de cada archivo como respaldo."
)


@admin_only
async def cmd_start(update, context):
    await update.message.reply_text(HELP, parse_mode=ParseMode.HTML)


@admin_only
async def cmd_list(update, context):
    files = list_files()
    if not files:
        await update.message.reply_text("📭 No hay archivos todavía. Envía un .json para empezar.")
        return
    chunk = f"<b>📂 {len(files)} archivo(s)</b>\n\n"
    for p in files:
        st = p.stat()
        item = (f"📄 <b>{esc(p.name)}</b> · {human(st.st_size)} · "
                f"{datetime.fromtimestamp(st.st_mtime):%d/%m/%Y %H:%M}\n"
                f"<code>{esc(url_for(p.name))}</code>\n\n")
        if len(chunk) + len(item) > 3800:
            await update.message.reply_text(chunk, parse_mode=ParseMode.HTML, disable_web_page_preview=True)
            chunk = ""
        chunk += item
    if chunk:
        await update.message.reply_text(chunk, parse_mode=ParseMode.HTML, disable_web_page_preview=True)


async def pick(update, prefix, text):
    files = list_files()
    if not files:
        await update.message.reply_text("📭 No hay archivos.")
        return
    await update.message.reply_text(text, reply_markup=kb(prefix, files))


@admin_only
async def cmd_update(update, context):
    await pick(update, "upd", "🔄 ¿Qué archivo quieres actualizar?")


@admin_only
async def cmd_get(update, context):
    await pick(update, "get", "⬇️ ¿Qué archivo quieres descargar?")


@admin_only
async def cmd_delete(update, context):
    await pick(update, "del", "🗑 ¿Qué archivo quieres eliminar?")


@admin_only
async def cmd_cancel(update, context):
    context.user_data.pop("update_target", None)
    await update.message.reply_text("Cancelado ✅")


@admin_only
async def on_document(update, context):
    msg = update.message
    doc = msg.document
    target = context.user_data.get("update_target")
    name = target or (doc.file_name or "")

    if not NAME_RE.match(name):
        await msg.reply_text(
            "⚠️ Nombre inválido. Debe terminar en <code>.json</code>, usar solo letras, números, "
            "<code>. _ -</code> y tener máx. 50 caracteres.", parse_mode=ParseMode.HTML)
        return
    if not doc.file_size or doc.file_size > MAX_BYTES:
        await msg.reply_text("⚠️ Archivo vacío o mayor de 20 MB (límite de Telegram para bots).")
        return

    tmp = TMP_DIR / f"{os.getpid()}-{doc.file_unique_id}.part"
    try:
        tg_file = await doc.get_file()
        await tg_file.download_to_drive(custom_path=tmp)
        existed = save_file(tmp, name)
    except Exception:
        log.exception("Error guardando %s", name)
        tmp.unlink(missing_ok=True)
        await msg.reply_text("❌ Error al guardar el archivo.")
        return

    context.user_data.pop("update_target", None)
    verb = "actualizado" if existed else "guardado"
    extra = ""
    if target and (doc.file_name or "") != name:
        extra = f"\n(Se conservó el nombre original; el archivo enviado se llamaba <code>{esc(doc.file_name)}</code>)"
    await msg.reply_text(
        f"✅ <b>{esc(name)}</b> {verb} · {human(doc.file_size)}\n<code>{esc(url_for(name))}</code>{extra}",
        parse_mode=ParseMode.HTML, disable_web_page_preview=True)


async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    if q.from_user.id not in ADMINS:
        await q.answer("No autorizado", show_alert=True)
        return
    await q.answer()
    action, _, name = (q.data or "").partition(":")

    if action == "cancel":
        context.user_data.pop("update_target", None)
        await q.edit_message_text("Cancelado ✅")
        return
    if not NAME_RE.match(name) or not (JSON_DIR / name).is_file():
        await q.edit_message_text("⚠️ Archivo no encontrado.")
        return

    if action == "upd":
        context.user_data["update_target"] = name
        await q.edit_message_text(
            f"📤 Envíame ahora el archivo nuevo para <b>{esc(name)}</b>.\n"
            "Se guardará con ese mismo nombre. /cancelar para salir.",
            parse_mode=ParseMode.HTML)
    elif action == "get":
        with open(JSON_DIR / name, "rb") as f:
            await q.message.reply_document(f, filename=name)
        await q.edit_message_text(f"⬇️ Enviado: {name}")
    elif action == "del":
        markup = InlineKeyboardMarkup([[
            InlineKeyboardButton("🗑 Sí, eliminar", callback_data=f"delok:{name}"),
            InlineKeyboardButton("No", callback_data="cancel:"),
        ]])
        await q.edit_message_text(f"¿Eliminar <b>{esc(name)}</b>?", parse_mode=ParseMode.HTML, reply_markup=markup)
    elif action == "delok":
        backup(name, tag="eliminado-")
        (JSON_DIR / name).unlink()
        await q.edit_message_text(f"🗑 <b>{esc(name)}</b> eliminado (queda copia de respaldo).",
                                  parse_mode=ParseMode.HTML)


async def on_error(update, context):
    log.error("Error: %s", context.error, exc_info=context.error)


async def post_init(app):
    await app.bot.set_my_commands([
        BotCommand("lista", "Ver archivos y URLs"),
        BotCommand("actualizar", "Actualizar un archivo"),
        BotCommand("descargar", "Descargar un archivo"),
        BotCommand("eliminar", "Eliminar un archivo"),
        BotCommand("cancelar", "Cancelar acción"),
        BotCommand("help", "Ayuda"),
    ])


def main():
    app = Application.builder().token(TOKEN).post_init(post_init).build()
    app.add_handler(CommandHandler(["start", "help"], cmd_start))
    app.add_handler(CommandHandler("lista", cmd_list))
    app.add_handler(CommandHandler("actualizar", cmd_update))
    app.add_handler(CommandHandler("descargar", cmd_get))
    app.add_handler(CommandHandler("eliminar", cmd_delete))
    app.add_handler(CommandHandler("cancelar", cmd_cancel))
    app.add_handler(MessageHandler(filters.Document.ALL, on_document))
    app.add_handler(CallbackQueryHandler(on_button))
    app.add_error_handler(on_error)
    log.info("Bot iniciado. Admins: %s", sorted(ADMINS))
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
PYEOF
chown "$APP_USER":"$APP_USER" "$APP_DIR/bot.py"
"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/bot.py"
ok "Bot instalado."

# ---------- Nginx ----------
info "Configurando Nginx..."
cat > /etc/nginx/sites-available/${SERVICE}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /json/ {
        alias ${APP_DIR}/json/;
        autoindex off;
        default_type application/json;
        add_header Cache-Control "no-cache, must-revalidate" always;
        add_header Access-Control-Allow-Origin "*" always;
        add_header X-Content-Type-Options "nosniff" always;
    }

    location / { return 404; }
}
EOF
ln -sf /etc/nginx/sites-available/${SERVICE}.conf /etc/nginx/sites-enabled/${SERVICE}.conf
nginx -t >/dev/null 2>&1 || { nginx -t; die "Configuración de Nginx inválida."; }
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx
ok "Nginx configurado."

# ---------- SSL ----------
SCHEME="http"
info "Solicitando certificado SSL (Let's Encrypt)..."
CB_ARGS=(--nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect)
if [[ -n "$EMAIL" ]]; then CB_ARGS+=(-m "$EMAIL"); else CB_ARGS+=(--register-unsafely-without-email); fi
if certbot "${CB_ARGS[@]}" >/tmp/certbot.log 2>&1; then
  SCHEME="https"; ok "SSL activado (renovación automática incluida)."
else
  warn "No se pudo emitir el SSL (¿DNS sin apuntar al servidor?). Seguirá en HTTP."
  warn "Cuando el DNS esté listo ejecuta:  certbot --nginx -d ${DOMAIN}  y luego  sed -i 's/^SCHEME=.*/SCHEME=https/' ${APP_DIR}/.env && systemctl restart ${SERVICE}"
  warn "Detalle: /tmp/certbot.log"
fi

# ---------- Configuración (.env) ----------
cat > "$APP_DIR/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
DOMAIN=${DOMAIN}
SCHEME=${SCHEME}
BASE_DIR=${APP_DIR}
EOF
chown root:"$APP_USER" "$APP_DIR/.env"
chmod 640 "$APP_DIR/.env"

# ---------- Servicio systemd ----------
cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=JSON Manager Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/bot.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ${SERVICE} >/dev/null 2>&1
sleep 3
systemctl is-active --quiet ${SERVICE} || { journalctl -u ${SERVICE} -n 20 --no-pager; die "El servicio no arrancó."; }
ok "Servicio '${SERVICE}' activo."

# Mensaje de prueba a los admins
IFS=',' read -ra _ids <<< "$ADMIN_IDS"
for id in "${_ids[@]}"; do
  curl -fsS --max-time 10 -o /dev/null "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${id}" \
    --data-urlencode "text=✅ JSON Manager instalado. Envía /start" || true
done

echo
echo "=============================================="
ok "INSTALACIÓN COMPLETA"
echo "  Carpeta JSON : ${APP_DIR}/json"
echo "  URL pública  : ${SCHEME}://${DOMAIN}/json/NOMBRE.json"
echo "  Logs         : journalctl -u ${SERVICE} -f"
echo "  Reiniciar    : systemctl restart ${SERVICE}"
echo "=============================================="
