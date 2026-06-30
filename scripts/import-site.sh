#!/usr/bin/env bash
# =====================================================================
#  import-site.sh - Importa un backup "Backup Migration" (BMI) nel
#  WordPress nuovo, impostando dominio e credenziali NUOVE.
#
#  Da eseguire SUL CT (come root):  sudo ./import-site.sh [opzioni]
#
#  Cosa fa, in ordine:
#   1. backup di sicurezza del sito attuale (DB + wp-content)
#   2. estrae lo zip BMI
#   3. svuota le tabelle del DB nuovo e importa quelle del backup
#      (rinominando il prefisso temporaneo del dump nel prefisso reale)
#   4. sincronizza wp-content (uploads/themes/plugins) dal backup
#   5. search-replace dominio vecchio -> nuovo (gestisce i dati serializzati)
#   6. imposta l'utente admin con la NUOVA password
#   7. riattiva la object cache Redis, sistema permessi e cache
#
#  Le credenziali DB (wp-config) NON vengono toccate: restano le nuove.
# =====================================================================
set -Eeuo pipefail

# ---------- Default (sovrascrivibili da flag o env) ----------
ZIP=""
SITE_ROOT=""
OLD_DOMAIN=""                       # autodetect dal manifest se vuoto
NEW_DOMAIN=""                       # autodetect dal sito se vuoto
NEW_ADMIN_USER="${NEW_ADMIN_USER:-miky}"
NEW_ADMIN_EMAIL="${NEW_ADMIN_EMAIL:-}"
NEW_ADMIN_PASS="${NEW_ADMIN_PASS:-}"   # consigliato passarla via env, non via flag
ASSUME_YES="no"
WORKDIR=""

WP() { sudo -u www-data wp --path="$SITE_ROOT" "$@"; }
# WPX: per operazioni che NON richiedono i plugin (evita che un plugin rotto,
# es. Elementor con file incompleti, mandi in fatal l'intero comando).
WPX() { sudo -u www-data wp --path="$SITE_ROOT" --skip-plugins --skip-themes "$@"; }
log()  { echo -e "\033[36m[import]\033[0m $*"; }
ok()   { echo -e "\033[32m[ ok ]\033[0m $*"; }
err()  { echo -e "\033[31m[err ]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<USAGE
Uso: sudo $0 --zip <BM_*.zip> --site-root </var/www/dominio> [opzioni]

Obbligatori:
  --zip PATH            Archivio BMI da importare
  --site-root PATH      Document root del sito nuovo (contiene wp-config.php)

Opzionali:
  --old-domain DOM      Dominio del vecchio sito (default: dal manifest BMI)
  --new-domain DOM      Dominio del sito nuovo (default: rilevato dal sito)
  --admin-user NAME     Utente admin da impostare (default: ${NEW_ADMIN_USER})
  --admin-email MAIL    Email admin (default: invariata)
  --admin-pass PASS     Nuova password admin (meglio via env NEW_ADMIN_PASS)
  -y, --yes             Non chiedere conferma

Esempio:
  NEW_ADMIN_PASS='Segreta123!' sudo -E $0 \\
    --zip /root/BM_xxx.zip --site-root /var/www/romaclubmatera.it \\
    --new-domain romaclubmatera.it --admin-user miky --yes
USAGE
}

# ---------- Parse argomenti ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)         ZIP="$2"; shift 2;;
    --site-root)   SITE_ROOT="${2%/}"; shift 2;;
    --old-domain)  OLD_DOMAIN="$2"; shift 2;;
    --new-domain)  NEW_DOMAIN="$2"; shift 2;;
    --admin-user)  NEW_ADMIN_USER="$2"; shift 2;;
    --admin-email) NEW_ADMIN_EMAIL="$2"; shift 2;;
    --admin-pass)  NEW_ADMIN_PASS="$2"; shift 2;;
    -y|--yes)      ASSUME_YES="yes"; shift;;
    -h|--help)     usage; exit 0;;
    *) die "Opzione sconosciuta: $1 (usa --help)";;
  esac
done

# ---------- Validazioni ----------
[[ $EUID -eq 0 ]] || die "Esegui come root (sudo)."
[[ -n "$ZIP" && -f "$ZIP" ]] || die "Zip non valido: '$ZIP' (--zip)"
[[ -n "$SITE_ROOT" && -f "$SITE_ROOT/wp-config.php" ]] || die "site-root senza wp-config.php: '$SITE_ROOT'"
for bin in wp mysql rsync unzip php; do command -v "$bin" >/dev/null || die "Manca il comando: $bin"; done
[[ -n "$NEW_ADMIN_PASS" ]] || die "Password admin mancante (--admin-pass o env NEW_ADMIN_PASS)"

# Dati dal sito nuovo (wp-config)
DB_NAME="$(WP config get DB_NAME)"
TABLE_PREFIX="$(WP config get table_prefix)"
[[ -n "$NEW_DOMAIN" ]] || NEW_DOMAIN="$(WP option get home | sed -E 's#^https?://##; s#/$##')"
NEW_URL="https://${NEW_DOMAIN}"

# ---------- Area di lavoro ed estrazione manifest ----------
WORKDIR="$(mktemp -d /tmp/bmi-import.XXXXXX)"
cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

log "Estraggo il manifest..."
unzip -o "$ZIP" 'bmi_backup_manifest.json' -d "$WORKDIR" >/dev/null
[[ -n "$OLD_DOMAIN" ]] || OLD_DOMAIN="$(python3 -c "import json,sys;print(json.load(open('$WORKDIR/bmi_backup_manifest.json')).get('domain',''))")"
[[ -n "$OLD_DOMAIN" ]] || die "Dominio vecchio non rilevato: passalo con --old-domain"

# ---------- Riepilogo + conferma ----------
cat <<SUMMARY

  ============ IMPORT SITO ============
  Backup          : $ZIP
  Site root       : $SITE_ROOT
  Database        : $DB_NAME (prefisso ${TABLE_PREFIX})
  Dominio vecchio : $OLD_DOMAIN
  Dominio nuovo   : $NEW_DOMAIN
  Admin           : $NEW_ADMIN_USER  (password: <impostata>)
  =====================================
  ATTENZIONE: l'operazione SOVRASCRIVE database e wp-content del sito nuovo.
  (Viene fatto prima un backup di sicurezza.)

SUMMARY
if [[ "$ASSUME_YES" != "yes" ]]; then
  read -r -p "Procedo? scrivi IMPORTA per confermare: " ans
  [[ "$ans" == "IMPORTA" ]] || die "Annullato."
fi

# ---------- 1) Backup di sicurezza del sito attuale ----------
log "Backup di sicurezza del sito attuale..."
if [[ -x /usr/local/sbin/wp-backup.sh ]]; then
  /usr/local/sbin/wp-backup.sh || err "wp-backup.sh ha segnalato un problema (continuo)."
else
  SAFE="/var/backups/pre-import-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SAFE"
  mysqldump --no-tablespaces "$DB_NAME" | gzip > "$SAFE/db.sql.gz"
  tar -czf "$SAFE/wp-content.tar.gz" -C "$SITE_ROOT" wp-content
  ok "Backup in $SAFE"
fi

# ---------- 2) Estrazione completa del backup ----------
log "Estraggo l'archivio (puo' richiedere un po')..."
unzip -oq "$ZIP" -d "$WORKDIR"
[[ -d "$WORKDIR/db_tables" ]] || die "Struttura BMI inattesa: manca db_tables/"

# ---------- 3) Import database ----------
# Rileva il prefisso temporaneo del dump (es. 1782759132_) dalle CREATE TABLE
TMP_PREFIX="$(grep -aohE 'CREATE TABLE IF NOT EXISTS `[0-9]+_' "$WORKDIR"/db_tables/*.sql \
              | head -1 | sed -E 's/.*`([0-9]+_).*/\1/')"
[[ -n "$TMP_PREFIX" ]] || die "Prefisso temporaneo del dump non rilevato."
# Prefisso originale del dump (es. wp_) = parte dopo il timestamp nella prima tabella
OLD_PREFIX="$(grep -aohE "CREATE TABLE IF NOT EXISTS \`${TMP_PREFIX}[a-zA-Z0-9]+_" "$WORKDIR"/db_tables/*.sql \
              | head -1 | sed -E "s/.*\`${TMP_PREFIX}([a-zA-Z0-9]+_).*/\1/")"
OLD_PREFIX="${OLD_PREFIX:-wp_}"
log "Prefisso dump: ${TMP_PREFIX}${OLD_PREFIX}  ->  ${TABLE_PREFIX}"

log "Svuoto le tabelle attuali del DB ${DB_NAME}..."
mapfile -t CUR_TABLES < <(mysql -N -e "SHOW TABLES" "$DB_NAME")
{
  echo "SET FOREIGN_KEY_CHECKS=0;"
  for t in "${CUR_TABLES[@]:-}"; do [[ -n "$t" ]] && echo "DROP TABLE IF EXISTS \`$t\`;"; done
  echo "SET FOREIGN_KEY_CHECKS=1;"
} | mysql "$DB_NAME"

log "Importo le tabelle dal backup..."
{
  echo "SET NAMES utf8mb4;"
  echo "SET FOREIGN_KEY_CHECKS=0;"
  # concatena tutti i dump, rinominando \`<tmp><oldprefix>  ->  \`<tableprefix>
  cat "$WORKDIR"/db_tables/*.sql | sed -E "s/\`${TMP_PREFIX}${OLD_PREFIX}/\`${TABLE_PREFIX}/g"
  echo "SET FOREIGN_KEY_CHECKS=1;"
} | mysql --max-allowed-packet=512M "$DB_NAME"
ok "Database importato."

# ---------- 4) wp-content dal backup ----------
log "Sincronizzo wp-content (uploads/themes/plugins)..."
set +e
rsync -a --delete \
  --exclude 'upgrade/' --exclude 'upgrade-temp-backup/' --exclude 'cache/' \
  --exclude 'object-cache.php' --exclude 'advanced-cache.php' \
  "$WORKDIR/wordpress/wp-content/" "$SITE_ROOT/wp-content/"
_rc=$?
set -e
# 23/24 = file spariti/non eliminabili durante la copia: non fatali qui
[[ $_rc -eq 0 || $_rc -eq 23 || $_rc -eq 24 ]] || die "rsync fallito (codice $_rc)"
ok "File wp-content sincronizzati."

# ---------- 5) search-replace dominio (e percorsi assoluti) ----------
log "Sostituisco $OLD_DOMAIN -> $NEW_DOMAIN nel database..."
WPX search-replace "//${OLD_DOMAIN}" "//${NEW_DOMAIN}" --all-tables-with-prefix --skip-columns=guid --report-changed-only || true
WPX search-replace "${OLD_DOMAIN}" "${NEW_DOMAIN}" --all-tables-with-prefix --skip-columns=guid --report-changed-only || true
# Percorso assoluto vecchio -> nuovo (Elementor, cache CSS, ecc.)
OLD_PATH="/var/www/clients/client1/web1/web"
WPX search-replace "${OLD_PATH}" "${SITE_ROOT}" --all-tables-with-prefix --skip-columns=guid --report-changed-only || true
# Forza https sul nuovo dominio (evita mixed-content se il vecchio sito era http)
WPX search-replace "http://${NEW_DOMAIN}" "https://${NEW_DOMAIN}" --all-tables-with-prefix --skip-columns=guid --report-changed-only || true

# ---------- 6) URL canonici + utente admin nuovo ----------
log "Imposto siteurl/home e l'utente admin..."
# Il search-replace ha gia' aggiornato gli URL: aggiorno solo se diversi
# (wp option update restituisce errore se il valore e' invariato).
for _opt in home siteurl; do
  _cur="$(WPX option get "$_opt" 2>/dev/null || true)"
  if [[ "$_cur" != "$NEW_URL" ]]; then
    WPX option update "$_opt" "$NEW_URL"
  fi
done

if WPX user get "$NEW_ADMIN_USER" >/dev/null 2>&1; then
  WPX user update "$NEW_ADMIN_USER" --user_pass="$NEW_ADMIN_PASS" --role=administrator
  [[ -n "$NEW_ADMIN_EMAIL" ]] && WPX user update "$NEW_ADMIN_USER" --user_email="$NEW_ADMIN_EMAIL"
  ok "Password aggiornata per l'utente '$NEW_ADMIN_USER'."
else
  WPX user create "$NEW_ADMIN_USER" "${NEW_ADMIN_EMAIL:-$NEW_ADMIN_USER@$NEW_DOMAIN}" \
     --role=administrator --user_pass="$NEW_ADMIN_PASS"
  ok "Creato nuovo utente admin '$NEW_ADMIN_USER'."
fi

# ---------- 7) Redis, DB upgrade, cache, permessi ----------
log "Riattivo Redis object cache..."
WPX plugin install redis-cache --force --activate >/dev/null 2>&1 || true
WP redis enable >/dev/null 2>&1 || err "Redis non riattivato (verifica 'wp redis status')."

log "Aggiorno schema DB, permalink e cache..."
WPX core update-db || true
WPX rewrite flush || true
WPX cache flush || true
# Rigenera CSS/dati Elementor se presente (necessario dopo il cambio dominio)
WP elementor flush-css >/dev/null 2>&1 || true

log "Sistemo proprietario e permessi..."
chown -R www-data:www-data "$SITE_ROOT"
find "$SITE_ROOT" -type d -exec chmod 755 {} +
find "$SITE_ROOT" -type f -exec chmod 644 {} +
chmod 640 "$SITE_ROOT/wp-config.php"

ok "IMPORT COMPLETATO."
echo
echo "  Sito:     $NEW_URL"
echo "  Admin:    $NEW_URL/wp-admin/  (utente: $NEW_ADMIN_USER)"
echo "  Verifica: home, menu, media e i plugin (Elementor/Slider Revolution)."
echo "  Se qualcosa non va, hai il backup pre-import in /var/backups/."
