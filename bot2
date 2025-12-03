#!/bin/bash

# --- PEDIR DATOS ---
read -p "Ingrese el TOKEN de Telegram: " BOT_TOKEN
read -p "Ingrese su ID de administrador: " ADMIN_ID
read -p "Ingrese el dominio para HTTPS (ej: midominio.com): " DOMAIN
EMAIL_ADMIN="admin@$DOMAIN"

# --- DIRECTORIOS ---
BOT_DIR="$HOME/bot_json_interactivo"
JSON_DIR="$BOT_DIR/json_files"

# --- ACTUALIZAR SISTEMA ---
sudo apt update && sudo apt upgrade -y

# --- INSTALAR DEPENDENCIAS ---
sudo apt install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx git

# --- CREAR DIRECTORIOS Y JSON DE EJEMPLO ---
mkdir -p "$JSON_DIR"
echo '{"mensaje":"Hola mundo"}' > "$JSON_DIR/config.json"
echo '{"usuario1":"activo","usuario2":"inactivo"}' > "$JSON_DIR/usuarios.json"
echo '{"tema":"oscuro","idioma":"es"}' > "$JSON_DIR/settings.json"

# --- ENTORNO VIRTUAL ---
python3 -m venv "$BOT_DIR/venv"
source "$BOT_DIR/venv/bin/activate"
pip install --upgrade pip
pip install python-telegram-bot==20.3 fastapi uvicorn

# --- CREAR BOT PYTHON COMPLETO ---
cat > "$BOT_DIR/bot.py" <<EOL
import os, json, threading
from fastapi import FastAPI
from fastapi.responses import FileResponse
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes, MessageHandler, filters

TOKEN = "$BOT_TOKEN"
ADMIN_ID = $ADMIN_ID
JSON_DIR = "json_files"
SERVER_HOST = "0.0.0.0"
SERVER_PORT = 8000
DOMAIN = "$DOMAIN"

os.makedirs(JSON_DIR, exist_ok=True)

def listar_json():
    return [f for f in os.listdir(JSON_DIR) if f.endswith(".json")]

def leer_json(file_name):
    path = os.path.join(JSON_DIR, file_name)
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def guardar_json(file_name, data):
    path = os.path.join(JSON_DIR, file_name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)

# --- FastAPI ---
app_fastapi = FastAPI()
@app_fastapi.get("/json/{file_name}")
async def descargar_json(file_name: str):
    path = os.path.join(JSON_DIR, file_name)
    if os.path.exists(path):
        return FileResponse(path, media_type="application/json", filename=file_name)
    return {"error": "Archivo no encontrado"}

def run_server():
    import uvicorn
    uvicorn.run(app_fastapi, host=SERVER_HOST, port=SERVER_PORT)

# --- Bot Telegram ---
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ADMIN_ID:
        await update.message.reply_text("❌ No tienes permisos.")
        return
    files = listar_json()
    if not files:
        await update.message.reply_text("📁 No hay archivos JSON disponibles.")
        return
    keyboard = [[InlineKeyboardButton(f, callback_data=f"archivo|{f}")] for f in files]
    await update.message.reply_text("📁 Archivos JSON disponibles:", reply_markup=InlineKeyboardMarkup(keyboard))

async def boton_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = query.data

    if data.startswith("archivo|"):
        file_name = data.split("|")[1]
        url = f"https://{DOMAIN}/json/{file_name}"
        keyboard = [
            [InlineKeyboardButton("📄 Ver contenido", callback_data=f"ver|{file_name}")],
            [InlineKeyboardButton("⬇ Descargar JSON", url=url)],
            [InlineKeyboardButton("➕ Agregar clave", callback_data=f"agregar|{file_name}")],
            [InlineKeyboardButton("✏️ Modificar clave", callback_data=f"modificar|{file_name}")],
            [InlineKeyboardButton("🗑 Borrar clave", callback_data=f"borrar|{file_name}")],
            [InlineKeyboardButton("⬆ Subir reemplazo", callback_data=f"subir|{file_name}")]
        ]
        await query.edit_message_text(f"📁 Archivo seleccionado: {file_name}", reply_markup=InlineKeyboardMarkup(keyboard))
        return

    if "|" in data:
        accion, file_name = data.split("|")
        context.user_data["archivo_seleccionado"] = file_name
        context.user_data["modo"] = accion

        if accion == "ver":
            contenido = json.dumps(leer_json(file_name), indent=4, ensure_ascii=False)
            await query.edit_message_text(f"📄 Contenido de {file_name}:\n```\n{contenido}\n```", parse_mode="Markdown")
        else:
            mensajes = {
                "agregar": "Envía: clave valor",
                "modificar": "Envía: clave valor",
                "borrar": "Envía la clave a borrar",
                "subir": "Envía el archivo JSON completo"
            }
            await query.edit_message_text(f"Modo {accion}: {mensajes[accion]}")

async def recibir_texto(update: Update, context: ContextTypes.DEFAULT_TYPE):
    modo = context.user_data.get("modo")
    file_name = context.user_data.get("archivo_seleccionado")
    if not file_name or not modo:
        return

    data_json = leer_json(file_name)
    mensaje = update.message.text

    if modo in ["agregar", "modificar"]:
        try:
            clave, valor = mensaje.split(" ", 1)
            data_json[clave] = valor
            guardar_json(file_name, data_json)
            await update.message.reply_text(f"✔ {modo.capitalize()}: {clave} = {valor}")
        except:
            await update.message.reply_text("Formato incorrecto. Usa: clave valor")
    elif modo == "borrar":
        if mensaje in data_json:
            del data_json[mensaje]
            guardar_json(file_name, data_json)
            await update.message.reply_text(f"🗑 Clave {mensaje} eliminada.")
        else:
            await update.message.reply_text("❌ Clave no encontrada.")
    context.user_data.clear()

async def recibir_archivo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if context.user_data.get("modo") != "subir":
        return
    archivo = update.message.document
    if archivo.mime_type != "application/json":
        await update.message.reply_text("❌ Solo archivos JSON")
        return
    file_name = context.user_data.get("archivo_seleccionado")
    path_dest = os.path.join(JSON_DIR, file_name)
    file = await archivo.get_file()
    await file.download_to_drive(path_dest)
    await update.message.reply_text(f"✔ Archivo {file_name} reemplazado correctamente.")
    context.user_data.clear()

def main():
    threading.Thread(target=run_server, daemon=True).start()
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(boton_menu))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, recibir_texto))
    app.add_handler(MessageHandler(filters.Document.MimeType("application/json"), recibir_archivo))
    print(f"Bot interactivo iniciado con JSON en https://{DOMAIN}")
    app.run_polling()

if __name__ == "__main__":
    main()
EOL

# --- Configurar Nginx ---
sudo bash -c "cat > /etc/nginx/sites-available/bot_json" <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/bot_json /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# --- Obtener HTTPS con Certbot ---
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL_ADMIN

# --- Crear servicio systemd ---
SERVICE_FILE="/etc/systemd/system/bot_json.service"
sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Bot JSON Interactivo con Telegram
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python3 $BOT_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable bot_json.service
sudo systemctl start bot_json.service

echo "✅ Instalación completa."
echo "📌 Ver logs: sudo journalctl -u bot_json.service -f"
echo "📌 Bot funcionando en https://$DOMAIN"
