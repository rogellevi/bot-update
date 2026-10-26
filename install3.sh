#!/usr/bin/env bash
# ==============================================================
#  JSON Manager Bot (Telegram) v3 - Panel moderno con botones de color
#  Instalador 1 clic · Ubuntu 20.04 / 22.04 / 24.04
#  Uso:  sudo bash install.sh
#   o :  sudo bash <(curl -fsSL https://TU_URL/install.sh)
#  Si ya está instalado, ofrece actualizar solo el bot
#  conservando token, ID, dominio y tus archivos.
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

apt-get update -y >/dev/null
apt-get install -y curl ca-certificates >/dev/null

# ---------- ¿Instalación previa? ----------
UPGRADE=0
if [[ -f "$APP_DIR/.env" && -f "$APP_DIR/bot.py" ]]; then
  read -r -p "Se detectó una instalación previa. ¿Conservar configuración y solo actualizar el bot? [S/n]: " ans </dev/tty || ans="s"
  ans="$(echo "$ans" | tr 'A-Z' 'a-z')"
  if [[ "$ans" != "n" && "$ans" != "no" ]]; then UPGRADE=1; fi
fi

ask() { # ask VAR "texto"
  local __v="$1" __p="$2" __val=""
  while [[ -z "$__val" ]]; do
    read -r -p "$__p" __val </dev/tty || die "No hay terminal interactiva."
    __val="${__val//[[:space:]]/}"
  done
  printf -v "$__v" '%s' "$__val"
}

if (( UPGRADE )); then
  set -a; . "$APP_DIR/.env"; set +a
  ok "Configuración existente cargada (${DOMAIN})."
else
  echo
  echo "=============================================="
  echo "   JSON Manager Bot · Configuración"
  echo "=============================================="

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

  while true; do
    ask ADMIN_IDS "▶ Tu ID de Telegram (varios separados por coma): "
    [[ "$ADMIN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]] && break
    warn "Solo números, separados por coma. (Obtén tu ID con @userinfobot)"
  done

  while true; do
    ask DOMAIN "▶ Dominio (ej: archivos.midominio.com): "
    DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
    DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z')"
    [[ "$DOMAIN" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] && break
    warn "Dominio inválido."
  done

  read -r -p "▶ Email para el certificado SSL (opcional, Enter para omitir): " EMAIL </dev/tty || EMAIL=""
  EMAIL="${EMAIL//[[:space:]]/}"

  SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)"
  if [[ -n "$SERVER_IP" && "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    warn "El dominio resuelve a '${DOMAIN_IP:-nada}' pero este servidor es ${SERVER_IP}."
    warn "Apunta el registro A a ${SERVER_IP} para que el SSL funcione. Continúo igualmente."
  fi
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
info "Preparando entorno Python..."
[[ -x "$APP_DIR/venv/bin/python" ]] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet "python-telegram-bot==20.8"
ok "Librerías listas."

# ---------- Código del bot ----------
cat > "$APP_DIR/bot.py" <<'PYEOF'
import hashlib
import html
import logging
import os
import re
import shutil
import time
from datetime import datetime
from functools import wraps
from pathlib import Path

from telegram import BotCommand
from telegram import InlineKeyboardButton
from telegram import InlineKeyboardMarkup as Markup
from telegram import Update
from telegram.constants import ChatAction, ParseMode
from telegram.error import BadRequest
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
ACT_LOG = BASE / "activity.log"
for d in (JSON_DIR, BACKUP_DIR, TMP_DIR):
    d.mkdir(parents=True, exist_ok=True)

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,45}\.json$")
MAX_BACKUPS = 10
MAX_BYTES = 20 * 1024 * 1024   # límite de descarga de la Bot API
PAGE_SIZE = 6
DEL_TAG = "-eliminado"
STARTED = datetime.now()
SEP = "━━━━━━━━━━━━━━"

ACT_ICONS = {"subió": "⬆️", "actualizó": "🔄", "eliminó": "🗑", "restauró": "↩️", "recuperó": "♻️"}
TOASTS = {"g": "⬇️ Enviando archivo…", "rs": "↩️ Versión restaurada",
          "tr": "♻️ Archivo recuperado", "dy": "🗑 Archivo eliminado"}


# ───────────────────────── botones (con colores) ─────────────────────────
def btn(text, data=None, style=None, copy=None):
    """Botón inline. style: primary (azul) | success (verde) | danger (rojo).
    copy: texto que el botón copia al portapapeles.
    Los campos nuevos de la Bot API viajan por api_kwargs; los clientes antiguos los ignoran."""
    kw = {}
    if style:
        kw["style"] = style
    if copy:
        kw["copy_text"] = {"text": copy}
    return InlineKeyboardButton(text, callback_data=data, api_kwargs=kw or None)


HOME = btn("🏠 Menú", "m:")
CANCEL = btn("✖ Cancelar", "x:")


# ───────────────────────── utilidades ─────────────────────────
def esc(s): return html.escape(str(s))
def url_for(name): return f"{SCHEME}://{DOMAIN}/json/{name}"
def fmt(ts): return datetime.fromtimestamp(ts).strftime("%d/%m/%Y %H:%M")


def human(n):
    n = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1024


def ago(ts):
    s = max(0, int(time.time() - ts))
    if s < 60:
        return "hace un momento"
    if s < 3600:
        return f"hace {s // 60} min"
    if s < 86400:
        return f"hace {s // 3600} h"
    if s < 7 * 86400:
        return f"hace {s // 86400} d"
    return fmt(ts)


def dot(ts):
    age = time.time() - ts
    return "🟢" if age < 86400 else "🟡" if age < 7 * 86400 else "⚪"


def bar(pct, n=10):
    pct = min(max(pct, 0), 100)
    f = round(pct / 100 * n)
    return "▰" * f + "▱" * (n - f)


def hdr(section=""):
    s = "<b>📦 JSON Manager</b>"
    if section:
        s += f"  ›  <i>{section}</i>"
    return f"{s}\n{SEP}\n"


def list_files(sort="recent"):
    files = [p for p in JSON_DIR.iterdir() if p.is_file() and NAME_RE.match(p.name)]
    if sort == "recent":
        return sorted(files, key=lambda p: -p.stat().st_mtime)
    return sorted(files, key=lambda p: p.name.lower())


def exists(name): return bool(NAME_RE.match(name)) and (JSON_DIR / name).is_file()


def versions(name):
    d = BACKUP_DIR / name
    if not d.is_dir():
        return []
    return sorted((p for p in d.iterdir() if p.is_file()), key=lambda p: p.name, reverse=True)


def trash_items():
    out = []
    for d in BACKUP_DIR.iterdir():
        if (d.is_dir() and NAME_RE.match(d.name) and not (JSON_DIR / d.name).exists()
                and any(f.is_file() for f in d.iterdir())):
            out.append(d.name)
    return sorted(out)


def backup(name, tag=""):
    src = JSON_DIR / name
    if not src.exists():
        return
    d = BACKUP_DIR / name
    d.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    shutil.copy2(src, d / f"{stamp}{tag}")
    for old in sorted(p for p in d.iterdir() if p.is_file())[:-MAX_BACKUPS]:
        old.unlink()


def save_file(tmp: Path, name: str) -> bool:
    """Reemplazo atómico conservando el nombre. True si ya existía."""
    dest = JSON_DIR / name
    existed = dest.exists()
    if existed:
        backup(name)
    os.chmod(tmp, 0o644)
    os.replace(tmp, dest)
    return existed


# ───────────────────────── registro de actividad ─────────────────────────
def log_event(update, action, name):
    try:
        u = update.effective_user
        who = (u.first_name or str(u.id)).replace("\t", " ").replace("\n", " ")[:30]
        with open(ACT_LOG, "a", encoding="utf-8") as f:
            f.write(f"{int(time.time())}\t{who}\t{action}\t{name}\n")
        if ACT_LOG.stat().st_size > 100_000:
            lines = ACT_LOG.read_text(encoding="utf-8").splitlines()[-200:]
            ACT_LOG.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception:
        log.exception("No se pudo registrar la actividad")


def read_events(n=8):
    if not ACT_LOG.exists():
        return []
    out = []
    for line in ACT_LOG.read_text(encoding="utf-8").splitlines()[-n:][::-1]:
        p = line.split("\t")
        if len(p) == 4 and p[0].isdigit():
            out.append((int(p[0]), p[1], p[2], p[3]))
    return out


# ───────────────────────── infraestructura ─────────────────────────
def admin_only(fn):
    @wraps(fn)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        u = update.effective_user
        if not u or u.id not in ADMINS:
            if update.message:
                await update.message.reply_text(f"⛔ No autorizado.\nTu ID: {u.id if u else '?'}")
            return
        return await fn(update, context)
    return wrapper


async def show(update: Update, text: str, rows):
    """Edita el mensaje del botón pulsado, o envía uno nuevo."""
    markup = Markup(rows)
    q = update.callback_query
    try:
        if q:
            await q.edit_message_text(text, parse_mode=ParseMode.HTML,
                                      reply_markup=markup, disable_web_page_preview=True)
        else:
            await update.effective_message.reply_text(text, parse_mode=ParseMode.HTML,
                                                      reply_markup=markup, disable_web_page_preview=True)
    except BadRequest as e:
        if "not modified" not in str(e).lower():
            raise


# ───────────────────────── pantallas ─────────────────────────
async def screen_menu(update, note="", extra_rows=None):
    files = list_files()
    total = sum(p.stat().st_size for p in files)
    du = shutil.disk_usage(BASE)
    pct = du.used / du.total * 100
    if files:
        last = max(files, key=lambda p: p.stat().st_mtime)
        last_line = f"🕒 Último cambio: <b>{esc(last.name)}</b> · {ago(last.stat().st_mtime)}"
    else:
        last_line = "🕒 Sin actividad todavía"
    text = (f"{hdr()}"
            f"<blockquote>📂 <b>{len(files)}</b> archivo(s) · {human(total)}\n"
            f"{last_line}\n"
            f"💾 Disco <code>{bar(pct)}</code> {pct:.0f}%</blockquote>\n"
            f"🌐 <code>{esc(DOMAIN)}</code>")
    if note:
        text = f"{note}\n\n{text}"
    rows = list(extra_rows or [])
    rows += [
        [btn("📂 Mis archivos", "L:v:0"), btn("⬆️ Subir archivo", "up:", style="success")],
        [btn("🔄 Actualizar archivo", "L:u:0", style="primary")],
        [btn("📜 Actividad", "ac:"), btn("📊 Estado", "st:")],
    ]
    n = len(trash_items())
    if n:
        rows.append([btn(f"♻️ Recuperar eliminados ({n})", "tw:")])
    rows.append([btn("❓ Ayuda", "hp:")])
    await show(update, text, rows)


async def screen_list(update, context, mode, page):
    sort = context.user_data.get("sort", "recent")
    files = list_files(sort)
    if not files:
        await show(update, f"{hdr('Archivos')}📭 <b>Aún no hay archivos</b>\n\n"
                           "<blockquote>Sube tu primer .json para empezar.</blockquote>",
                   [[btn("⬆️ Subir archivo", "up:", style="success")], [HOME]])
        return
    pages = max(1, (len(files) + PAGE_SIZE - 1) // PAGE_SIZE)
    page = min(max(page, 0), pages - 1)
    chunk = files[page * PAGE_SIZE:(page + 1) * PAGE_SIZE]
    if mode == "v":
        title, sub = "Mis archivos", "Toca un archivo para ver sus opciones."
    else:
        title, sub = "Actualizar", "Elige el archivo que quieres reemplazar."
    sort_label = "Recientes" if sort == "recent" else "A–Z"
    text = (f"{hdr(title)}{sub}\n"
            f"<blockquote>🟢 hoy   🟡 esta semana   ⚪ anterior\n"
            f"{len(files)} archivo(s) · orden: {sort_label}</blockquote>")
    rows = [[btn(f"{dot(p.stat().st_mtime)} {p.name}  ·  {human(p.stat().st_size)}", f"{mode}:{p.name}")]
            for p in chunk]
    if pages > 1:
        nav = []
        if page > 0:
            nav.append(btn("◀️ Anterior", f"L:{mode}:{page - 1}"))
        nav.append(btn(f"{page + 1}/{pages}", "noop:"))
        if page < pages - 1:
            nav.append(btn("Siguiente ▶️", f"L:{mode}:{page + 1}"))
        rows.append(nav)
    rows.append([btn(f"🔀 Orden: {sort_label}", f"so:{mode}"), btn("⬆️ Subir", "up:", style="success")])
    rows.append([HOME])
    await show(update, text, rows)


async def screen_detail(update, name, note=""):
    p = JSON_DIR / name
    st = p.stat()
    sha = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
    nv = len(versions(name))
    text = (f"{hdr('Archivo')}📄 <b>{esc(name)}</b>\n"
            f"<blockquote>{dot(st.st_mtime)} Modificado <b>{ago(st.st_mtime)}</b>\n"
            f"📏 Tamaño <b>{human(st.st_size)}</b>\n"
            f"🔐 SHA-256 <code>{sha}…</code>\n"
            f"🕘 Versiones anteriores <b>{nv}</b></blockquote>\n"
            f"🔗 <b>URL pública</b>\n<blockquote><code>{esc(url_for(name))}</code></blockquote>")
    if note:
        text = f"{note}\n\n{text}"
    rows = [
        [btn("🔄 Actualizar", f"u:{name}", style="primary"), btn("⬇️ Descargar", f"g:{name}")],
        [btn("📋 Copiar URL", copy=url_for(name)), btn(f"🕘 Versiones ({nv})", f"h:{name}")],
        [btn("🗑 Eliminar", f"d:{name}", style="danger")],
        [btn("◀️ Volver", "L:v:0"), HOME],
    ]
    await show(update, text, rows)


async def screen_versions(update, name):
    vs = versions(name)[:8]
    if not vs:
        await show(update, f"{hdr('Versiones')}🕘 <b>{esc(name)}</b>\n\n"
                           "<blockquote>Todavía no hay versiones anteriores. Se crean "
                           "automáticamente cada vez que actualizas el archivo.</blockquote>",
                   [[btn("◀️ Volver", f"v:{name}"), HOME]])
        return
    rows = [[btn(f"↩️ {ago(v.stat().st_mtime)} · {human(v.stat().st_size)}", f"rs:{i}:{name}")]
            for i, v in enumerate(vs)]
    rows.append([btn("◀️ Volver", f"v:{name}"), HOME])
    await show(update, f"{hdr('Versiones')}🕘 <b>{esc(name)}</b>\n\n"
                       "Toca una versión para restaurarla.\n"
                       "<blockquote>La versión actual se guarda antes de restaurar, "
                       "así que siempre puedes volver atrás.</blockquote>", rows)


async def screen_trash(update):
    items = trash_items()[:10]
    if not items:
        await screen_menu(update, "♻️ No hay archivos eliminados.")
        return
    rows = [[btn(f"♻️ {n}", f"tr:{n}")] for n in items]
    rows.append([HOME])
    await show(update, f"{hdr('Eliminados')}Toca un archivo para recuperarlo.", rows)


async def screen_activity(update):
    events = read_events(8)
    if not events:
        await show(update, f"{hdr('Actividad')}<blockquote>Aún no hay actividad registrada.</blockquote>",
                   [[HOME]])
        return
    lines = []
    for ts, who, action, name in events:
        lines.append(f"{ACT_ICONS.get(action, '•')} <b>{esc(name)}</b>\n"
                     f"     <i>{esc(who)} {esc(action)} · {ago(ts)}</i>")
    await show(update, f"{hdr('Actividad')}Últimos movimientos:\n\n" + "\n".join(lines),
               [[btn("🔃 Refrescar", "ac:"), HOME]])


async def screen_status(update):
    files = list_files()
    total = sum(p.stat().st_size for p in files)
    du = shutil.disk_usage(BASE)
    pct = du.used / du.total * 100
    nb = sum(1 for d in BACKUP_DIR.iterdir() if d.is_dir() for f in d.iterdir() if f.is_file())
    ssl = "🔒 HTTPS activo" if SCHEME == "https" else "⚠️ HTTP (sin SSL)"
    up = datetime.now() - STARTED
    h, m = divmod(int(up.total_seconds()) // 60, 60)
    text = (f"{hdr('Estado')}"
            f"<blockquote>🟢 <b>Bot activo</b> · {up.days}d {h}h {m}m\n"
            f"🌐 <code>{esc(DOMAIN)}</code>\n{ssl}</blockquote>\n"
            f"💾 <b>Disco</b>\n<code>{bar(pct)}</code> {pct:.0f}% · {human(du.free)} libres\n\n"
            f"📂 Archivos: <b>{len(files)}</b> ({human(total)})\n"
            f"🕘 Respaldos: <b>{nb}</b>\n"
            f"👤 Administradores: <b>{len(ADMINS)}</b>")
    await show(update, text, [[btn("🔃 Refrescar", "st:"), HOME]])


async def screen_help(update):
    text = (f"{hdr('Ayuda')}"
            "⬆️ <b>Subir</b>\n<blockquote>Envía un .json como documento. "
            "Si el nombre ya existe, se actualiza.</blockquote>\n"
            "🔄 <b>Actualizar</b>\n<blockquote>Elige un archivo y envía el nuevo. Se guarda con el "
            "<b>mismo nombre</b>: la URL de tus apps nunca cambia.</blockquote>\n"
            "🕘 <b>Versiones y papelera</b>\n<blockquote>Se guardan las últimas 10 versiones de cada "
            "archivo y los eliminados se pueden recuperar.</blockquote>\n"
            "Comandos: /menu · /lista · /cancelar")
    await show(update, text, [[HOME]])


async def screen_upload(update):
    await show(update,
               f"{hdr('Subir')}📎 Envíame el archivo <code>.json</code> como documento.\n"
               "<blockquote>• Si el nombre ya existe, se <b>actualiza</b>.\n"
               "• Máx. 20 MB\n"
               "• Nombre con letras, números, <code>. _ -</code></blockquote>",
               [[btn("📂 Mis archivos", "L:v:0"), HOME]])


# ───────────────────────── comandos ─────────────────────────
@admin_only
async def cmd_menu(update, context):
    context.user_data.pop("update_target", None)
    await screen_menu(update)


@admin_only
async def cmd_list(update, context):
    await screen_list(update, context, "v", 0)


@admin_only
async def on_text(update, context):
    t = context.user_data.get("update_target")
    if t:
        await show(update, f"{hdr('Actualizar')}⏳ Esperando el archivo nuevo para <b>{esc(t)}</b>.\n"
                           "Envíalo como documento 📎", [[CANCEL]])
        return
    await screen_menu(update)


# ───────────────────────── subida de archivos ─────────────────────────
@admin_only
async def on_document(update, context):
    msg = update.message
    doc = msg.document
    target = context.user_data.get("update_target")
    name = target or (doc.file_name or "")

    if not NAME_RE.match(name):
        await show(update,
                   f"{hdr('Subir')}⚠️ <b>Nombre no válido</b>\n"
                   "<blockquote>Debe terminar en <code>.json</code>, usar solo letras, números, "
                   "<code>. _ -</code> y tener máx. 50 caracteres.\n"
                   "Renombra el archivo y vuelve a enviarlo.</blockquote>",
                   [[btn("⬆️ Subir archivo", "up:", style="success"), HOME]])
        return
    if not doc.file_size or doc.file_size > MAX_BYTES:
        await show(update, f"{hdr('Subir')}⚠️ El archivo está vacío o supera los 20 MB "
                           "(límite de Telegram para bots).", [[HOME]])
        return

    await msg.chat.send_action(ChatAction.TYPING)
    tmp = TMP_DIR / f"{os.getpid()}-{doc.file_unique_id}.part"
    try:
        tg_file = await doc.get_file()
        await tg_file.download_to_drive(custom_path=tmp)
        existed = save_file(tmp, name)
    except Exception:
        log.exception("Error guardando %s", name)
        tmp.unlink(missing_ok=True)
        await show(update, "❌ Error al guardar el archivo. Inténtalo de nuevo.", [[HOME]])
        return

    context.user_data.pop("update_target", None)
    log_event(update, "actualizó" if existed else "subió", name)
    extra = ""
    if target and (doc.file_name or "") != name:
        extra = (f"\nℹ️ Se conservó el nombre original "
                 f"(el archivo enviado se llamaba <code>{esc(doc.file_name)}</code>).")
    title = "🔄 <b>Archivo actualizado</b>" if existed else "✅ <b>Archivo guardado</b>"
    text = (f"{hdr()}{title}\n"
            f"<blockquote>📄 <b>{esc(name)}</b>\n📏 {human(doc.file_size)}\n"
            f"🔗 <code>{esc(url_for(name))}</code></blockquote>{extra}")
    rows = []
    if existed:
        rows.append([btn("↩️ Deshacer actualización", f"rs:0:{name}", style="primary")])
    rows.append([btn("📄 Ver archivo", f"v:{name}"), btn("📋 Copiar URL", copy=url_for(name))])
    rows.append([btn("⬆️ Subir otro", "up:"), HOME])
    await show(update, text, rows)


# ───────────────────────── botones ─────────────────────────
async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    if q.from_user.id not in ADMINS:
        await q.answer("⛔ No autorizado", show_alert=True)
        return

    parts = (q.data or "").split(":", 2)
    parts += [""] * (3 - len(parts))
    act, a, b = parts
    await q.answer(TOASTS.get(act))

    if act == "noop":
        return
    if act in ("m", "x"):
        context.user_data.pop("update_target", None)
        await screen_menu(update)
        return
    if act == "L":
        await screen_list(update, context, a if a in ("v", "u") else "v", int(b) if b.isdigit() else 0)
        return
    if act == "so":
        cur = context.user_data.get("sort", "recent")
        context.user_data["sort"] = "name" if cur == "recent" else "recent"
        await screen_list(update, context, a if a in ("v", "u") else "v", 0)
        return
    if act == "up":
        await screen_upload(update); return
    if act == "st":
        await screen_status(update); return
    if act == "ac":
        await screen_activity(update); return
    if act == "hp":
        await screen_help(update); return
    if act == "tw":
        await screen_trash(update); return

    # --- acciones sobre un archivo existente (nombre en 'a') ---
    if act in ("v", "u", "g", "l", "h", "d", "dy"):
        if not exists(a):
            await screen_menu(update, "⚠️ Archivo no encontrado.")
            return
        name = a
        if act == "v":
            await screen_detail(update, name)
        elif act == "u":
            context.user_data["update_target"] = name
            await show(update,
                       f"{hdr('Actualizar')}🔄 <b>{esc(name)}</b>\n"
                       "<blockquote>Envíame ahora el archivo nuevo como documento 📎\n"
                       "Se guardará con <b>el mismo nombre</b> y la URL no cambiará.</blockquote>",
                       [[CANCEL]])
        elif act == "g":
            with open(JSON_DIR / name, "rb") as f:
                await q.message.reply_document(f, filename=name, caption=f"📄 {name}")
        elif act == "l":  # compatibilidad con mensajes antiguos
            await q.message.reply_text(
                f"🔗 <b>{esc(name)}</b>\n<code>{esc(url_for(name))}</code>",
                parse_mode=ParseMode.HTML, disable_web_page_preview=True)
        elif act == "h":
            await screen_versions(update, name)
        elif act == "d":
            await show(update,
                       f"{hdr('Eliminar')}🗑 <b>¿Eliminar {esc(name)}?</b>\n"
                       "<blockquote>⚠️ Las apps que descarguen esta URL recibirán un error 404.\n"
                       "Quedará una copia en «Recuperar eliminados».</blockquote>",
                       [[btn("🗑 Sí, eliminar", f"dy:{name}", style="danger"), btn("↩️ No", f"v:{name}")]])
        elif act == "dy":
            backup(name, tag=DEL_TAG)
            (JSON_DIR / name).unlink()
            log_event(update, "eliminó", name)
            await screen_menu(update, f"🗑 <b>{esc(name)}</b> eliminado.",
                              [[btn("↩️ Deshacer eliminación", f"tr:{name}", style="primary")]])
        return

    # --- restaurar versión: rs:<idx>:<nombre> ---
    if act == "rs":
        name = b
        vs = versions(name) if NAME_RE.match(name) else []
        if not exists(name) or not a.isdigit() or int(a) >= len(vs):
            await screen_menu(update, "⚠️ Versión no disponible.")
            return
        tmp = TMP_DIR / f"restore-{os.getpid()}.part"
        shutil.copy2(vs[int(a)], tmp)
        save_file(tmp, name)
        log_event(update, "restauró", name)
        await screen_detail(update, name, "✅ <b>Versión restaurada</b>")
        return

    # --- recuperar eliminado: tr:<nombre> ---
    if act == "tr":
        name = a
        vs = versions(name) if NAME_RE.match(name) else []
        if not vs or (JSON_DIR / name).exists():
            await screen_menu(update, "⚠️ Nada que recuperar.")
            return
        tmp = TMP_DIR / f"restore-{os.getpid()}.part"
        shutil.copy2(vs[0], tmp)
        save_file(tmp, name)
        if vs[0].name.endswith(DEL_TAG):
            vs[0].unlink()
        log_event(update, "recuperó", name)
        await screen_detail(update, name, "♻️ <b>Archivo recuperado</b>")
        return


async def on_error(update, context):
    log.error("Error: %s", context.error, exc_info=context.error)


async def post_init(app):
    await app.bot.set_my_commands([
        BotCommand("menu", "Abrir el panel"),
        BotCommand("lista", "Ver mis archivos"),
        BotCommand("cancelar", "Cancelar y volver al menú"),
    ])
    try:
        await app.bot.set_my_description(
            "📦 Panel para administrar los archivos JSON de tus apps.\n\n"
            "Sube, actualiza sin cambiar el nombre, restaura versiones y obtén la URL pública.\n\n"
            "Pulsa INICIAR para abrir el panel.")
        await app.bot.set_my_short_description("Gestor de archivos JSON · sube, actualiza y publica.")
    except Exception as e:
        log.warning("No se pudo establecer la descripción del bot: %s", e)


def main():
    app = Application.builder().token(TOKEN).post_init(post_init).build()
    app.add_handler(CommandHandler(["start", "menu", "help", "cancelar"], cmd_menu))
    app.add_handler(CommandHandler("lista", cmd_list))
    app.add_handler(MessageHandler(filters.Document.ALL, on_document))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
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

# ---------- Nginx + SSL (solo instalación nueva) ----------
if (( ! UPGRADE )); then
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

  cat > "$APP_DIR/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
DOMAIN=${DOMAIN}
SCHEME=${SCHEME}
BASE_DIR=${APP_DIR}
EOF
  chown root:"$APP_USER" "$APP_DIR/.env"
  chmod 640 "$APP_DIR/.env"
fi

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
systemctl enable ${SERVICE} >/dev/null 2>&1
systemctl restart ${SERVICE}
sleep 3
systemctl is-active --quiet ${SERVICE} || { journalctl -u ${SERVICE} -n 20 --no-pager; die "El servicio no arrancó."; }
ok "Servicio '${SERVICE}' activo."

# Mensaje de aviso a los admins
IFS=',' read -ra _ids <<< "$ADMIN_IDS"
for id in "${_ids[@]}"; do
  curl -fsS --max-time 10 -o /dev/null "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${id}" \
    --data-urlencode "text=✅ JSON Manager listo. Envía /menu para abrir el panel." || true
done

echo
echo "=============================================="
ok "$( (( UPGRADE )) && echo 'ACTUALIZACIÓN COMPLETA' || echo 'INSTALACIÓN COMPLETA' )"
echo "  Carpeta JSON : ${APP_DIR}/json"
echo "  URL pública  : ${SCHEME}://${DOMAIN}/json/NOMBRE.json"
echo "  Logs         : journalctl -u ${SERVICE} -f"
echo "  Reiniciar    : systemctl restart ${SERVICE}"
echo "=============================================="
