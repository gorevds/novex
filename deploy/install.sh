#!/usr/bin/env bash
set -euo pipefail

# Запускать на сервере под root. Idempotent (можно перезапускать).
# Предусловия:
#   - DNS A-record novex.gorev.space -> server IP
#   - Установлены nginx, certbot, python3.12, sqlite3, rsync
#   - В рабочей директории есть актуальный клон novex-parser (REPO_DIR=$PWD)

REPO_DIR="${REPO_DIR:-$PWD}"
APP_DIR="/opt/novex"
SVC_USER="novex"

# OnSuccess=/OnFailure= в novex-scan.service требуют systemd >= 249
# (Ubuntu 22.04 LTS / Debian 12 / RHEL 9). На более старых системах
# чейн novex-scan-dev молча не сработает (никакой ошибки в daemon-reload).
# Прерываемся ДО изменений: лучше явный fail, чем тихая регрессия.
SYSTEMD_VER=$(systemctl --version | awk 'NR==1{print $2}')
if [ "${SYSTEMD_VER:-0}" -lt 249 ]; then
  echo "ERROR: systemd $SYSTEMD_VER < 249 — нужен Ubuntu 22.04+/Debian 12+ для OnSuccess= в novex-scan.service" >&2
  exit 1
fi

# 1. Системный пользователь
id -u "$SVC_USER" &>/dev/null || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$SVC_USER"

# 2. Раскладка кода (исключаем рабочие артефакты)
install -d -o "$SVC_USER" -g "$SVC_USER" "$APP_DIR" "$APP_DIR/data" "$APP_DIR/static"
rsync -a --delete \
  --exclude='data/' --exclude='.git/' --exclude='venv/' --exclude='__pycache__/' \
  --exclude='.pytest_cache/' --exclude='*.egg-info' \
  "$REPO_DIR/" "$APP_DIR/"
chown -R "$SVC_USER":"$SVC_USER" "$APP_DIR"

# 3. venv с datasette
sudo -u "$SVC_USER" python3.12 -m venv "$APP_DIR/venv"
sudo -u "$SVC_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip
sudo -u "$SVC_USER" "$APP_DIR/venv/bin/pip" install -e "$APP_DIR[serve]"

# 4. systemd unit'ы. После R5 (2026-05-25) единый сканер — novex-scan.service,
# который сразу делает --all (10 застройщиков). novex-scan-dev.{service,timer}
# полностью убраны с системы: сначала останавливаем и сносим, потом ставим
# актуальный набор.
for old in novex-scan-dev.timer novex-scan-dev.service; do
  if [ -e /etc/systemd/system/$old ]; then
    systemctl disable --now $old 2>/dev/null || true
    rm -f /etc/systemd/system/$old
    echo ">>> убран legacy unit $old"
  fi
done

install -m 644 "$APP_DIR/deploy/novex.service"          /etc/systemd/system/novex.service
install -m 644 "$APP_DIR/deploy/novex-scan.service"     /etc/systemd/system/novex-scan.service
install -m 644 "$APP_DIR/deploy/novex-scan.timer"       /etc/systemd/system/novex-scan.timer
install -m 644 "$APP_DIR/deploy/novex-backup.service"   /etc/systemd/system/novex-backup.service
install -m 644 "$APP_DIR/deploy/novex-backup.timer"     /etc/systemd/system/novex-backup.timer
systemctl daemon-reload

# 5. Первый прогон скана. novex-scan.service теперь обходит все 10 застройщиков
# одной командой (см. ExecStart=bin.scan_dev --all). novex-scan-dev.service
# больше не существует — не запрашиваем.
systemctl start novex-scan.service
journalctl -u novex-scan.service --no-pager | tail -30

# Перезапуск Datasette после изменения схемы (он держит соединение с novex.db)
systemctl restart novex.service 2>/dev/null || true

# 6. Поднимаем datasette + ежедневный таймер + бэкап-таймер
systemctl enable --now novex.service
systemctl enable --now novex-scan.timer
systemctl enable --now novex-backup.timer
systemctl status novex.service --no-pager | head -10

# 7. Nginx — двухшаговая раскатка для первичного выпуска TLS-сертификата
ln -sf /etc/nginx/sites-available/novex.gorev.space /etc/nginx/sites-enabled/novex.gorev.space

if [ ! -e /etc/letsencrypt/live/novex.gorev.space/fullchain.pem ]; then
  echo ">>> TLS-сертификат не найден — ставим HTTP-only и зовём certbot."
  install -m 644 "$APP_DIR/deploy/nginx-novex.gorev.space-http.conf" /etc/nginx/sites-available/novex.gorev.space
  mkdir -p /var/www/certbot
  nginx -t
  systemctl reload nginx

  certbot certonly --webroot -w /var/www/certbot -d novex.gorev.space \
    --non-interactive --agree-tos --email "${LETSENCRYPT_EMAIL:-dmitrii@gorev.space}"
fi

install -m 644 "$APP_DIR/deploy/nginx-novex.gorev.space.conf" /etc/nginx/sites-available/novex.gorev.space
nginx -t
systemctl reload nginx
echo ">>> Готово. Откройте https://novex.gorev.space"
