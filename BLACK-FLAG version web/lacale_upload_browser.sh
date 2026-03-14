#!/bin/sh
# =============================================================================
# Script créé par Theolddispatch & the40n8
#      ___           ___       ___           ___           ___     
#     /\  \         /\__\     /\  \         /\  \         /\__\   
#    /::\  \       /:/  /    /::\  \       /::\  \       /:/  /   
#   /:/\:\  \     /:/  /    /:/\:\  \     /:/\:\  \     /:/__/    
#  /::\~\:\__\   /:/  /    /::\~\:\  \   /:/  \:\  \   /::\__\____
# /:/\:\ \:|__| /:/__/    /:/\:\ \:\__\ /:/__/ \:\__\ /:/\:::::\__\
# \:\~\:\/:/  / \:\  \    \/__\:\/:/  / \:\  \  \/__/ \/_|:|~~|~  
#  \:\ \::/  /   \:\  \        \::/  /   \:\  \          |:|  |   
#   \:\/:/  /     \:\  \       /:/  /     \:\  \         |:|  |   
#    \::/__/       \:\__\     /:/  /       \:\__\        |:|  |   
#     ~~            \/__/     \/__/         \/__/         \|__|    
#      ___           ___       ___           ___     
#     /\  \         /\__\     /\  \         /\  \    
#    /::\  \       /:/  /    /::\  \       /::\  \   
#   /:/\:\  \     /:/  /    /:/\:\  \     /:/\:\  \  
#  /::\~\:\  \   /:/  /    /::\~\:\  \   /:/  \:\  \ 
# /:/\:\ \:\__\ /:/__/    /:/\:\ \:\__\ /:/__/_\:\__\
# \/__\:\ \/__/ \:\  \    \/__\:\/:/  / \:\  /\ \/__/
#      \:\__\    \:\  \        \::/  /   \:\ \:\__\  
#       \/__/     \:\  \       /:/  /     \:\/:/  /  
#                  \:\__\     /:/  /       \::/  /   
#                   \/__/     \/__/         \/__/  — version formulaire web 2.8
# =============================================================================
# lacale_upload_browser.sh — Upload automatique depuis Radarr vers La Cale
#                            via simulation navigateur (https://la-cale.space/upload)
# Version : 2.8 — Adaptation des MAJ de cale-push (github.com/the40n8/cale-push) :
#                 · Nommage amélioré : éditions (DC/EXTENDED/UNRATED/REMASTERED),
#                   IMAX, plateformes (NF/AMZN/DSNP/ATVP/MAX…), canaux audio,
#                   Atmos, codecs VC-1/MPEG, accents/apostrophes nettoyés
#                 · Tags améliorés : VFQ, VOSTFR complet, VC-1, Opus, FLAC audio,
#                   HDLight/4KLight/mHD, COMPLETE BLURAY, DTS-X
#                 · Cache local TSV (TTL 24h présent / 6h absent) pour limiter
#                   les appels API de vérification doublon
#                 · Deux passes : Pass 1 contenus absents de La Cale,
#                   Pass 2 releases alternatives (si quota non atteint)
#                 · Filtre qualité minimale (MIN_QUALITY : 720p/1080p/2160p)
#                 · Fichier d'exclusion (EXCLUDE_FILE : TMDb IDs ou titres)
#                 · Notifications Discord webhook (DISCORD_WEBHOOK_URL)
#                 · Notifications Telegram bot (TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)
#                 · Retry avec backoff exponentiel sur erreurs API (MAX_RETRIES)
#                 · Délai configurable entre uploads (UPLOAD_DELAY)
# Version : 2.7 — Piece length adaptatif selon taille fichier (256K/512K/1M/2M/4M)
# Version : 2.6 — Fix upload : ajout du termId obligatoire "quais" (source WEB/BluRay/etc.)
#                 Découverte dynamique des termGroups depuis /api/internal/categories
#                 Fallback hardcodé si l'API ne retourne pas les quais
# Version : 2.5 — Ajout actualisation radarr si sélection
#                 Ajout d'une vérification seed avant upload
#                 Ajout grades pour max_movies
#                 Ajout d'une vérification pendings
#                 Ajout d'un temps d'attente pour que le seed se charge et s'active
# Emplacement : [chemin-vers-votre-dossier-scripts]
# Dépendances : curl, jq (NAS), docker (pour création torrent via Alpine)
# =============================================================================

# ─── Grades La Cale & limite d'upload ────────────────────────────────────────
# Grade         │ Cargaisons uploadées nécessaires │ MAX_MOVIES conseillé
# ─────────────────────────────────────────────────────────────────────────────
# Observateur   │   0  (débutant, en attente valid.)│  1
# Initié        │   5  cargaisons validées          │  5
# Matelot       │  ?? cargaisons validées           │ ??
# Quartier-     │  ?? cargaisons validées           │ ??
#  maître       │                                   │
# Officier      │  ?? cargaisons validées           │ ??
# Capitaine     │  ?? cargaisons validées           │ ??
# (complétez les grades manquants depuis la-cale.space/forums)
# ─────────────────────────────────────────────────────────────────────────────
MAX_MOVIES="${MAX_MOVIES:-1}"   # ← Modifiez cette valeur selon votre grade

# =============================================================================
# ─── !! À CONFIGURER AVANT UTILISATION !! ────────────────────────────────────
# =============================================================================
# Toutes les valeurs ci-dessous sont à renseigner manuellement.
# Elles peuvent aussi être passées en variables d'environnement (prioritaires).

# -- Radarr --
RADARR_URL="${RADARR_URL:-http://[adresse-ip-nas]:[port-radarr]}"       # ex: http://192.168.1.10:7878
RADARR_API_KEY="${RADARR_API_KEY:-[clé-api-radarr]}"                    # Radarr → Paramètres → Général → Clé API
MEDIAINFO_URL="${MEDIAINFO_URL:-http://[adresse-ip-nas]:[port-mediainfo]}"

# -- La Cale --
LACALE_URL="${LACALE_URL:-https://la-cale.space}"
LACALE_USER="${LACALE_USER:-[email-compte-lacale]}"                     # email du compte La Cale
LACALE_PASS="${LACALE_PASS:-[mot-de-passe-lacale]}"                     # mot de passe du compte La Cale

# Clé API La Cale (optionnelle — nécessite le scope upload:write côté tracker)
# Disponible dans : La Cale → Paramètres → API
# Non utilisée pour l'instant (le script utilise la session interne email/password)
# Sera utilisée automatiquement quand l'API externe sera activée sur La Cale
LACALE_API_KEY="${LACALE_API_KEY:-[clé-api-lacale]}"

TRACKER_URL="${TRACKER_URL:-https://tracker.la-cale.space/announce?passkey=[passkey-lacale]}"  # passkey visible dans votre profil La Cale

# -- qBittorrent --
QB_URL="${QB_URL:-http://[adresse-ip-nas]:[port-qbittorrent]}"          # ex: http://192.168.1.10:8080
QB_USER="${QB_USER:-[utilisateur-qbittorrent]}"
QB_PASS="${QB_PASS:-[mot-de-passe-qbittorrent]}"

# -- Notifications mail (Gmail) --
MAIL_TO="${MAIL_TO:-[email-destinataire]}"
MAIL_FROM="${MAIL_FROM:-[email-expediteur]}"
MAIL_SUBJECT="${MAIL_SUBJECT:-La Cale Upload Report}"
GMAIL_USER="${GMAIL_USER:-[email-gmail]}"
GMAIL_PASS_FILE="${GMAIL_PASS_FILE:-[chemin-vers-fichier-mot-de-passe-app-gmail]}"  # fichier contenant le mot de passe d'application Gmail
SMTP_URL="${SMTP_URL:-smtps://smtp.gmail.com:465}"

# -- Chemins NAS --
# Correspondance chemins Radarr (conteneur) → NAS réel
RADARR_PATH_PREFIX="${RADARR_PATH_PREFIX:-[préfixe-chemin-films-dans-radarr]}"    # ex: /Films/Films
NAS_FILMS_GLOB="[glob-vers-dossier-films-nas]"                                     # ex: /share/DATA/Media*/Films
NAS_PATH_PREFIX="${NAS_PATH_PREFIX:-[préfixe-chemin-nas]}"                         # ex: /share/DATA
QB_PATH_PREFIX="${QB_PATH_PREFIX:-}"  # Préfixe chemin vu par qBittorrent si différent du NAS (ex: Docker)

# -- Répertoires de travail (BLACK FLAG) --
BLACK_FLAG_DIR="${BLACK_FLAG_DIR:-[chemin-complet-dossier-black-flag]}"            # dossier racine du projet sur le NAS
# Les sous-dossiers ci-dessous sont dérivés automatiquement de BLACK_FLAG_DIR :
NFO_DIR="${NFO_DIR:-${BLACK_FLAG_DIR}/NFO}"
TORRENTS_DIR="${TORRENTS_DIR:-${BLACK_FLAG_DIR}/torrents ready}"
LOGS_DIR="${LOGS_DIR:-${BLACK_FLAG_DIR}/_logs}"
HISTORIQUE_DIR="${HISTORIQUE_DIR:-${BLACK_FLAG_DIR}/_historique}"

# -- Script Python altcha (chemin absolu) --
# ALTCHA_SOLVER est utilisé dans lacale_login() — ajuster si le script est ailleurs
# Valeur par défaut : ${BLACK_FLAG_DIR}/scripts/altcha_solver.py

# -- Notifications Discord (laisser vide pour désactiver) --
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"                          # ex: https://discord.com/api/webhooks/xxx/yyy

# -- Notifications Telegram (laisser vide pour désactiver) --
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"                            # ex: 123456:ABCdef...
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"                                # ex: -100123456789

# =============================================================================
# ─── Fin de la section de configuration ──────────────────────────────────────
# =============================================================================

# User-Agent navigateur (doit correspondre au navigateur qui a généré les cookies)
BROWSER_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

# Fonction pour résoudre le chemin réel d'un film via glob
resolve_nas_path() {
    _RADARR_PATH="$1"
    _FOLDER=$(echo "$_RADARR_PATH" | sed "s|^${RADARR_PATH_PREFIX}/||" | cut -d'/' -f1)
    _FILE=$(echo "$_RADARR_PATH" | sed "s|^${RADARR_PATH_PREFIX}/||" | cut -d'/' -f2-)
    _RESOLVED=$(ls -d ${NAS_FILMS_GLOB}/"${_FOLDER}"/"${_FILE}" 2>/dev/null | head -1)
    echo "$_RESOLVED"
}

# Répertoires BLACK FLAG version web
HISTORIQUE_FILE="${HISTORIQUE_DIR}/uploaded_torrents.txt"

# Image Docker pour Python 3
DOCKER_PYTHON="${DOCKER_PYTHON:-alpine:3.20}"

# ─── Nouvelles options v2.8 ───────────────────────────────────────────────────

# Qualité minimale à uploader (laisser vide = tout uploader)
# Valeurs : 720p, 1080p, 2160p
MIN_QUALITY="${MIN_QUALITY:-}"

# Fichier d'exclusion : un TMDb ID ou titre par ligne (# = commentaire)
EXCLUDE_FILE="${EXCLUDE_FILE:-}"

# Délai en secondes entre chaque upload (évite le rate limit API)
UPLOAD_DELAY="${UPLOAD_DELAY:-3}"

# Nombre max de tentatives sur erreur API (backoff exponentiel : 2s, 4s, 8s…)
MAX_RETRIES="${MAX_RETRIES:-3}"

# Cache local pour les vérifications doublon La Cale (évite les appels répétés)
CACHE_FILE="${CACHE_FILE:-${HISTORIQUE_DIR}/lacale_cache.tsv}"
CACHE_TTL_PRESENT="${CACHE_TTL_PRESENT:-86400}"   # 24h si présent sur La Cale
CACHE_TTL_ABSENT="${CACHE_TTL_ABSENT:-21600}"      # 6h si absent


# ─── Init répertoires & logs ──────────────────────────────────────────────────
mkdir -p "$NFO_DIR" "$TORRENTS_DIR" "$LOGS_DIR" "$HISTORIQUE_DIR" 2>/dev/null

LOG_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="${LOGS_DIR}/lacale_upload_${LOG_DATE}.log"
WORK_DIR="${BLACK_FLAG_DIR}/_tmp/lacale_$$"
mkdir -p "$WORK_DIR"
REPORT_FILE="${WORK_DIR}/report.txt"
COOKIE_FILE="${WORK_DIR}/lacale_cookies.txt"
touch "$REPORT_FILE" "$LOG_FILE"

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
    _msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$_msg"
    echo "$_msg" >> "$REPORT_FILE"
    echo "$_msg" >> "$LOG_FILE"
}
log_section() {
    log ""; log "══════════════════════════════════════════"
    log "  $*"; log "══════════════════════════════════════════"
}

# ─── Retry avec backoff exponentiel ──────────────────────────────────────────
# Usage : curl_retry curl [args...]
curl_retry() {
    local attempt=0 output
    while [ "$attempt" -lt "$MAX_RETRIES" ]; do
        attempt=$((attempt + 1))
        if output=$("$@" 2>&1); then
            echo "$output"
            return 0
        fi
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            local wait=$((2 ** attempt))
            log "  WARN: requête échouée (tentative $attempt/$MAX_RETRIES), retry dans ${wait}s..."
            sleep "$wait"
        fi
    done
    echo "$output"
    return 1
}

# ─── Filtre qualité minimale ──────────────────────────────────────────────────
_quality_rank() {
    case "$1" in
        *2160*|*4K*|*UHD*) echo 4 ;;
        *1080*)             echo 3 ;;
        *720*)              echo 2 ;;
        *480*|*SD*)         echo 1 ;;
        *)                  echo 0 ;;
    esac
}

meets_min_quality() {
    [ -z "$MIN_QUALITY" ] && return 0
    local rank min_rank
    rank=$(_quality_rank "$1")
    min_rank=$(_quality_rank "$MIN_QUALITY")
    [ "$rank" -ge "$min_rank" ]
}

# ─── Fichier d'exclusion ─────────────────────────────────────────────────────
is_excluded() {
    local tmdb_id="$1" title="$2"
    { [ -z "$EXCLUDE_FILE" ] || [ ! -f "$EXCLUDE_FILE" ]; } && return 1
    [ -n "$tmdb_id" ] && [ "$tmdb_id" != "null" ] && \
        grep -qxF "$tmdb_id" "$EXCLUDE_FILE" 2>/dev/null && return 0
    [ -n "$title" ] && grep -qiF "$title" "$EXCLUDE_FILE" 2>/dev/null && return 0
    return 1
}

# ─── Cache local TSV (clé → count, timestamp) ────────────────────────────────
_cache_get() {
    local key="$1" now line cached_count cached_ts ttl
    now=$(date +%s)
    touch "$CACHE_FILE" 2>/dev/null || return 1
    line=$(grep -m1 "^${key}	" "$CACHE_FILE" 2>/dev/null) || return 1
    cached_count=$(echo "$line" | cut -f2)
    cached_ts=$(echo "$line"   | cut -f3)
    [ "$cached_count" -gt 0 ] 2>/dev/null && ttl=$CACHE_TTL_PRESENT || ttl=$CACHE_TTL_ABSENT
    [ $((now - cached_ts)) -lt "$ttl" ] && { echo "$cached_count"; return 0; }
    return 1
}

_cache_set() {
    local key="$1" count="$2" now
    now=$(date +%s)
    touch "$CACHE_FILE" 2>/dev/null || return
    grep -v "^${key}	" "$CACHE_FILE" > "${CACHE_FILE}.tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$key" "$count" "$now" >> "${CACHE_FILE}.tmp"
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
}

# Vérifie combien de releases existent sur La Cale pour un TMDb ID
# Utilise le cache, puis l'API de recherche navigateur en fallback
count_releases_lacale() {
    local tmdb_id="$1" title="$2"
    local cache_key="${tmdb_id:-title:${title}}"

    local cached
    if cached=$(_cache_get "$cache_key"); then
        echo "$cached"; return 0
    fi

    # Appel API de recherche
    local count=0
    local title_enc
    title_enc=$(printf '%s' "$title" | sed 's/ /+/g')
    local search_result
    search_result=$(curl -sf --max-time 20 \
        -A "$BROWSER_UA" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H "Accept: application/json" \
        --compressed \
        "${LACALE_URL}/api/internal/torrents/filter?search=${title_enc}&category=films" 2>/dev/null)

    if [ -n "$search_result" ]; then
        count=$(echo "$search_result" | jq 'if type=="array" then length else (.data // [] | length) end' 2>/dev/null || echo 0)
    fi

    _cache_set "$cache_key" "$count"
    echo "$count"
}

# Même chose mais invalide le cache d'abord (re-vérification juste avant upload)
count_releases_lacale_fresh() {
    local tmdb_id="$1" title="$2"
    local cache_key="${tmdb_id:-title:${title}}"
    grep -v "^${cache_key}	" "$CACHE_FILE" > "${CACHE_FILE}.tmp" 2>/dev/null || true
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE" 2>/dev/null || true
    count_releases_lacale "$tmdb_id" "$title"
}

# ─── Notifications ────────────────────────────────────────────────────────────
notify_discord() {
    [ -z "$DISCORD_WEBHOOK_URL" ] && return 0
    local event="$1" title="$2" message="$3"
    local color
    case "$event" in
        upload_ok)   color=5763719  ;;  # vert
        upload_fail) color=15548997 ;;  # rouge
        summary)     color=5793266  ;;  # bleu
        *)           color=9807270  ;;  # gris
    esac
    local payload
    payload=$(jq -nc \
        --arg t "$title" --arg d "$message" --argjson c "$color" \
        '{embeds:[{title:$t,description:$d,color:$c,footer:{text:"BLACK FLAG Upload v2.8"}}]}')
    curl -sf -H "Content-Type: application/json" -d "$payload" \
        "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

notify_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    local event="$1" title="$2" message="$3"
    local icon
    case "$event" in
        upload_ok)   icon="✅" ;;
        upload_fail) icon="❌" ;;
        summary)     icon="📊" ;;
        *)           icon="ℹ️" ;;
    esac
    local text="${icon} *${title}*
${message}"
    curl -sf -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=Markdown" >/dev/null 2>&1 || true
}

notify() {
    local event="$1" title="$2" message="$3"
    notify_discord  "$event" "$title" "$message"
    notify_telegram "$event" "$title" "$message"
}

# ─── Génération BBCode (description La Cale) ──────────────────────────────────
# Reproduit EXACTEMENT le comportement de generateBBCode() du frontend La Cale
# (analysé depuis le bundle 8dd0f5d0032cce4a_js, confirmé dans 9f1380cda80e4497_js).
# Template : [center][img]…[size=6][color=#eab308]…[quote]synopsis…[DÉTAILS]…[CASTING]
generate_bbcode() {
    local title="$1"
    local year="$2"
    local overview="$3"
    local cover_url="$4"
    local quality_name="$5"
    local video_codec="$6"
    local audio_codec="$7"
    local audio_langs="$8"
    local file_size_bytes="$9"
    local rating="${10}"       # ex: "7.2"
    local genres="${11}"       # ex: "Thriller, Horreur"
    local cast_json="${12}"    # JSON array: [{"name":"...","character":"..."},…]
    local subtitles="${13}"
    local dyn_range="${14}"
    local dyn_type="${15}"

    # ── Résolution depuis quality_name ────────────────────────────────────────
    local resolution="1080p"
    case "$quality_name" in
        *2160*|*4K*|*UHD*) resolution="2160p" ;;
        *1080*)             resolution="1080p" ;;
        *720*)              resolution="720p"  ;;
        *576*)              resolution="576p"  ;;
        *480*)              resolution="480p"  ;;
    esac

    # ── Format conteneur ──────────────────────────────────────────────────────
    local container="MKV"

    # ── Taille fichier lisible (formatBytes: ≥1GiB→GiB, sinon MiB) ───────────
    local file_size_hr="Variable"
    if [ -n "$file_size_bytes" ] && [ "$file_size_bytes" -gt 0 ] 2>/dev/null; then
        file_size_hr=$(awk "BEGIN {
            b=$file_size_bytes
            if (b >= 1073741824) printf \"%.2f GiB\", b/1073741824
            else printf \"%.2f MiB\", b/1048576
        }")
    fi

    # ── Langues / sous-titres ─────────────────────────────────────────────────
    local lang_display="${audio_langs:-Français (VFF)}"
    [ -z "$audio_langs" ] || [ "$audio_langs" = "null" ] && lang_display="Français (VFF)"
    local subs_display="${subtitles:-Français}"
    [ -z "$subtitles" ] || [ "$subtitles" = "null" ] && subs_display="Français"

    # ── Note (arrondie à 1 décimale) ─────────────────────────────────────────
    local rating_display="N/A"
    if [ -n "$rating" ] && [ "$rating" != "null" ] && [ "$rating" != "0" ]; then
        rating_display=$(printf "%.1f" "$rating" 2>/dev/null || echo "$rating")
    fi

    # ── Genres ────────────────────────────────────────────────────────────────
    local genres_display="${genres:-N/A}"
    [ -z "$genres" ] || [ "$genres" = "null" ] && genres_display="N/A"

    # ── Poster URL (si relatif, préfixer https://image.tmdb.org/t/p/w500) ─────
    local poster_url="$cover_url"
    if [ -n "$poster_url" ] && [ "$poster_url" != "null" ]; then
        case "$poster_url" in
            http*) : ;;  # déjà absolu
            *)     poster_url="https://image.tmdb.org/t/p/w500${poster_url}" ;;
        esac
    fi

    # ── Casting (5 premiers acteurs depuis JSON) ───────────────────────────────
    local cast_block=""
    if [ -n "$cast_json" ] && [ "$cast_json" != "null" ] && [ "$cast_json" != "[]" ]; then
        local cast_lines
        cast_lines=$(printf '%s' "$cast_json" | \
            jq -r '.[:5][] | select(.name != null and .name != "") | "[b]" + .name + "[/b] (" + (.character // .role // "") + ")"' \
            2>/dev/null)
        if [ -n "$cast_lines" ]; then
            cast_block="

[color=#eab308][b]--- CASTING ---[/b][/color]

${cast_lines}"
        fi
    fi

    # ── Construction BBCode (template exact du site) ───────────────────────────
    printf '[center]\n'
    if [ -n "$poster_url" ] && [ "$poster_url" != "null" ]; then
        printf '[img]%s[/img]\n\n' "$poster_url"
    fi
    printf '[size=6][color=#eab308][b]%s (%s)[/b][/color][/size]\n\n' "$title" "$year"
    printf '[b]Note :[/b] %s/10\n' "$rating_display"
    printf '[b]Genre :[/b] %s\n\n' "$genres_display"
    if [ -n "$overview" ] && [ "$overview" != "null" ]; then
        printf '[quote]%s[/quote]\n\n' "$overview"
    fi
    printf '[color=#eab308][b]--- DÉTAILS ---[/b][/color]\n\n'
    printf '[b]Qualité :[/b] %s\n' "$resolution"
    printf '[b]Format :[/b] %s\n' "$container"
    printf '[b]Codec Vidéo :[/b] %s\n' "${video_codec:-x264}"
    printf '[b]Codec Audio :[/b] %s\n' "${audio_codec:-AAC}"
    printf '[b]Langues :[/b] %s\n' "$lang_display"
    printf '[b]Sous-titres :[/b] %s\n' "$subs_display"
    printf '[b]Taille :[/b] %s' "$file_size_hr"
    if [ -n "$cast_block" ]; then
        printf '%s' "$cast_block"
    fi
    printf '\n\n[i]Généré par La Cale[/i]\n[/center]'
}

# ─── Utilitaires ──────────────────────────────────────────────────────────────
radarr_get() {
    curl -sf --max-time 30 \
        -H "X-Api-Key: $RADARR_API_KEY" \
        "${RADARR_URL}/api/v3/$1"
}

# ─── Requête navigateur générique (avec cookies, Referer, User-Agent) ─────────
browser_get() {
    curl -sf --max-time 30 \
        -A "$BROWSER_UA" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8" \
        -H "Accept-Encoding: gzip, deflate, br" \
        -H "Connection: keep-alive" \
        -H "Upgrade-Insecure-Requests: 1" \
        --compressed \
        "${LACALE_URL}$1"
}

# ─── Connexion à La Cale (API REST JSON — Next.js) ────────────────────────────
# Le site utilise POST /api/auth/login en JSON avec {email, password, altcha, formLoadedAt}
# altcha est un Proof-of-Work (SHA-256) résolu localement depuis le challenge
# fourni par /api/auth/altcha/challenge?scope=login (spec open-source: altcha.org)
# Cloudflare peut bloquer la page /login mais l'API POST reste accessible
lacale_login() {
    log "Connexion à La Cale via API REST JSON..."

    if [ -z "$LACALE_USER" ] || [ -z "$LACALE_PASS" ]; then
        log "ERREUR: LACALE_USER et LACALE_PASS doivent être définis."
        return 1
    fi

    # ── Login avec PoW Altcha ─────────────────────────────────────────────────
    # Pas besoin de cf_clearance : Cloudflare laisse passer l'IP du NAS directement.
    # Le flow : GET challenge → solver SHA-256 → POST login → cookie session HttpOnly
    log "  Récupération du challenge Altcha..."
    FORM_LOADED_AT=$(awk "BEGIN{print int(systime()*1000)}" /dev/null 2>/dev/null || echo "$(date +%s)000")
    ALTCHA_CHALLENGE=$(curl -sf --max-time 15 \
        -A "$BROWSER_UA" \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "Accept: application/json" \
        -H "Referer: ${LACALE_URL}/login" \
        --compressed \
        "${LACALE_URL}/api/auth/altcha/challenge?scope=login" 2>/dev/null)

    ALTCHA_TOKEN=""
    if [ -n "$ALTCHA_CHALLENGE" ]; then
        # ── Étape 2 : résoudre le PoW SHA-256 via fichier Python temporaire ──
        log "  Résolution du PoW Altcha..."
        ALTCHA_SOLVER="${BLACK_FLAG_DIR}/scripts/altcha_solver.py"
        # Écrire le challenge dans un fichier pour éviter les problèmes d'échappement shell
        CHALLENGE_FILE="${WORK_DIR}/altcha_challenge.json"
        printf '%s' "$ALTCHA_CHALLENGE" > "$CHALLENGE_FILE"
        ALTCHA_TOKEN=$(python "$ALTCHA_SOLVER" "$CHALLENGE_FILE" 2>/dev/null)
        if [ -n "$ALTCHA_TOKEN" ]; then
            log "  ✓ PoW résolu"
        else
            log "  WARN: PoW non résolu, tentative sans altcha"
        fi
    else
        log "  WARN: challenge Altcha non disponible, tentative sans"
    fi

    # ── Étape 3 : POST login avec altcha ──────────────────────────────────────
    LOGIN_BUILDER="${WORK_DIR}/login_payload.py"
    cat > "$LOGIN_BUILDER" << 'BUILDER_EOF'
import json, os, sys
payload = {
    'email': os.environ['LOGIN_EMAIL'],
    'password': os.environ['LOGIN_PASS'],
    'formLoadedAt': int(os.environ['FORM_LOADED_AT'])
}
altcha = os.environ.get('ALTCHA_TOKEN', '').strip()
if altcha:
    payload['altcha'] = altcha
sys.stdout.write(json.dumps(payload) + "
")
BUILDER_EOF
    # Build JSON payload with jq (no python needed on host)
    if [ -n "$ALTCHA_TOKEN" ]; then
        LOGIN_PAYLOAD=$(jq -cn --arg e "$LACALE_USER" --arg p "$LACALE_PASS" \
            --argjson f "$FORM_LOADED_AT" --arg a "$ALTCHA_TOKEN" \
            '{email:$e, password:$p, formLoadedAt:$f, altcha:$a}')
    else
        LOGIN_PAYLOAD=$(jq -cn --arg e "$LACALE_USER" --arg p "$LACALE_PASS" \
            --argjson f "$FORM_LOADED_AT" \
            '{email:$e, password:$p, formLoadedAt:$f}')
    fi

    LOGIN_RESPONSE=$(curl -si --max-time 30 \
        -A "$BROWSER_UA" \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Referer: ${LACALE_URL}/login" \
        -H "Origin: ${LACALE_URL}" \
        --compressed \
        -X POST \
        -d "$LOGIN_PAYLOAD" \
        "${LACALE_URL}/api/auth/login")

    HTTP_CODE=$(echo "$LOGIN_RESPONSE" | grep -oE '^HTTP/[0-9.]+ [0-9]+' | tail -1 | grep -oE '[0-9]+$')
    LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | sed -n '/^\r\{0,1\}$/,$ p' | tail -n +2)

    log "  HTTP login: ${HTTP_CODE:-?}"

    if [ "$HTTP_CODE" = "200" ] || echo "$LOGIN_BODY" | grep -q '"success"\s*:\s*true\|"user"\s*:'; then
        log "  ✓ Connexion réussie"
        return 0
    fi

    # Fallback : cookie de session manuel (export depuis navigateur)
    ERR=$(echo "$LOGIN_BODY" | grep -oE '"message":"[^"]*"' | head -1)
    log "  ERREUR: connexion échouée (HTTP $HTTP_CODE) — $ERR"
    log "  → Vérifiez LACALE_USER et LACALE_PASS dans le script"
    return 1
}

# ─── Récupération du CSRF token depuis la page upload ─────────────────────────
# NOTE: L'app est 100% Next.js avec API REST — pas de CSRF token HTML.
# Cette fonction est conservée pour compatibilité mais retourne vide.
get_upload_csrf() {
    UPLOAD_PAGE=$(browser_get "/upload")
    if [ -z "$UPLOAD_PAGE" ]; then
        log "ERREUR: impossible de charger la page /upload"
        echo ""
        return 1
    fi

    # Chercher le token dans le formulaire (Next.js n'en a pas, retournera vide)
    _TOKEN=$(echo "$UPLOAD_PAGE" | grep -oE 'name="_token"\s+value="[^"]+"' | grep -oE 'value="[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | head -1)
    if [ -z "$_TOKEN" ]; then
        _TOKEN=$(echo "$UPLOAD_PAGE" | grep -oE '"csrfToken":"[^"]+"' | grep -oE '"[^"]+"}' | sed 's/["}]//g' | head -1)
    fi
    echo "$_TOKEN"
}

# ─── Vérification doublon via page de recherche ───────────────────────────────
lacale_check_duplicate() {
    _TMDB_ID="$1"
    _TITLE="$2"

    # Recherche par titre sur le moteur interne
    SEARCH_RESULT=$(curl -sf --max-time 30 \
        -A "$BROWSER_UA" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H "Accept: application/json, */*" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Referer: ${LACALE_URL}/torrents" \
        --compressed \
        "${LACALE_URL}/api/internal/torrents/filter?search=$(echo "$_TITLE" | sed 's/ /+/g')&category=films" 2>/dev/null)

    if [ -z "$SEARCH_RESULT" ]; then
        # Fallback : chercher via la page /torrents avec paramètre GET
        SEARCH_RESULT=$(browser_get "/torrents?search=$(echo "$_TITLE" | sed 's/ /+/g')&categories%5B%5D=films")
    fi

    FOUND=$(echo "$SEARCH_RESULT" | grep -ic "$_TITLE" 2>/dev/null || echo "0")
    [ "$FOUND" -gt 0 ] && echo "true" || echo "false"
}

send_report() {
    _subject="$1"; _body="$2"
    [ -f "$GMAIL_PASS_FILE" ] || { log "WARN: mot de passe Gmail introuvable: $GMAIL_PASS_FILE"; return 1; }
    _pass=$(cat "$GMAIL_PASS_FILE")
    curl -sf --url "$SMTP_URL" --ssl-reqd \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        --user "$GMAIL_USER:$_pass" \
        --upload-file - << MAIL_EOF
From: $MAIL_FROM
To: $MAIL_TO
Subject: $_subject
Content-Type: text/plain; charset=utf-8

$(cat "$_body")
MAIL_EOF
    log "✓ Mail envoyé à $MAIL_TO"
}

# ─── Démarrage ────────────────────────────────────────────────────────────────
printf '\n'
echo 'Script créé par Theolddispatch & the40n8'
echo '     ___           ___       ___           ___           ___     '
echo '    /\  \         /\__\     /\  \         /\  \         /\__\   '
echo '   /::\  \       /:/  /    /::\  \       /::\  \       /:/  /   '
echo '  /:/\:\  \     /:/  /    /:/\:\  \     /:/\:\  \     /:/__/    '
echo ' /::\~\:\__\   /:/  /    /::\~\:\  \   /:/  \:\  \   /::\__\____'
echo '/:/\:\ \:|__| /:/__/    /:/\:\ \:\__\ /:/__/ \:\__\ /:/\:::::\__\'
echo '\:\~\:\/:/  / \:\  \    \/__\:\/:/  / \:\  \  \/__/ \/_|:|~~|~  '
echo ' \:\ \::/  /   \:\  \        \::/  /   \:\  \          |:|  |   '
echo '  \:\/:/  /     \:\  \       /:/  /     \:\  \         |:|  |   '
echo '   \::/__/       \:\__\     /:/  /       \:\__\        |:|  |   '
echo '    ~~            \/__/     \/__/         \/__/         \|__|    '
echo '     ___           ___       ___           ___     '
echo '    /\  \         /\__\     /\  \         /\  \    '
echo '   /::\  \       /:/  /    /::\  \       /::\  \   '
echo '  /:/\:\  \     /:/  /    /:/\:\  \     /:/\:\  \  '
echo ' /::\~\:\  \   /:/  /    /::\~\:\  \   /:/  \:\  \ '
echo '/:/\:\ \:\__\ /:/__/    /:/\:\ \:\__\ /:/__/_\:\__\'
echo '\/__\:\ \/__/ \:\  \    \/__\:\/:/  / \:\  /\ \/__/'
echo '     \:\__\    \:\  \        \::/  /   \:\ \:\__\  '
echo '      \/__/     \:\  \       /:/  /     \:\/:/  /  '
echo '                 \:\__\     /:/  /       \::/  /   '
echo '                  \/__/     \/__/         \/__/  — version formulaire web 2.8'
printf '\n'
log_section "Démarrage La Cale Upload Script v2.8 (deux passes · cache · nommage étendu · notifications)"
log "MAX_MOVIES : $MAX_MOVIES"
log "NFO dir    : $NFO_DIR"
log "Torrents   : $TORRENTS_DIR"
log "Log file   : $LOG_FILE"
log "Mode       : Simulation navigateur (https://la-cale.space/upload)"

# ─── Connexion à La Cale ──────────────────────────────────────────────────────
lacale_login || { log "ERREUR: connexion La Cale impossible. Abandon."; exit 1; }

# ─── Récupération des métadonnées (catégorie Films) via API ───────────────────
log ""
log "Récupération de la catégorie Films via /api/internal/categories..."

# Utilise l'API REST plutôt que le HTML de /upload (la page peut être bloquée par Cloudflare)
CATEGORIES_JSON=$(curl -sf --max-time 15 \
    -A "$BROWSER_UA" \
    -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
    -H "Accept: application/json" \
    --compressed \
    "${LACALE_URL}/api/internal/categories" 2>/dev/null)

CATEGORY_ID=""
if [ -n "$CATEGORIES_JSON" ]; then
    # Chercher une catégorie dont le nom contient "film" ou "movie" (insensible à la casse)
    CATEGORY_ID=$(printf '%s' "$CATEGORIES_JSON" | \
        jq -r '
          (if type == "array" then . else (.data // .categories // []) end)
          | .. | objects | select(.name? and ((.name | ascii_downcase) | test("film|movie")))
          | .id
        ' 2>/dev/null | head -1)
fi

if [ -z "$CATEGORY_ID" ] || [ "$CATEGORY_ID" = "null" ]; then
    log "WARN: catégorie Films non trouvée dans /api/internal/categories — utilisation de l'ID hardcodé"
    CATEGORY_ID="[id-categorie-films-lacale]"  # À récupérer via /api/internal/categories ou dans les DevTools
fi

log "Catégorie Films : id=$CATEGORY_ID"

# ─── Découverte des termGroups (quais obligatoires) ───────────────────────────
# Le site exige au moins un term du groupe "quais" (source de la release).
# On tente de récupérer les IDs depuis l'API ; fallback sur valeurs hardcodées
# issues de l'analyse du bundle JS de la-cale.space.
log ""
log "Découverte des termGroups (quais) via /api/internal/categories/${CATEGORY_ID}/terms..."

TERM_GROUPS_JSON=$(curl -sf --max-time 15 \
    -A "$BROWSER_UA" \
    -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
    -H "Accept: application/json" \
    --compressed \
    "${LACALE_URL}/api/internal/categories/${CATEGORY_ID}/terms" 2>/dev/null)

# Fallback : essayer directement /api/internal/terms?categoryId=...
if [ -z "$TERM_GROUPS_JSON" ] || echo "$TERM_GROUPS_JSON" | grep -q '"error"\|"message"'; then
    TERM_GROUPS_JSON=$(curl -sf --max-time 15 \
        -A "$BROWSER_UA" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H "Accept: application/json" \
        --compressed \
        "${LACALE_URL}/api/internal/terms?categoryId=${CATEGORY_ID}" 2>/dev/null)
fi

# Logger les groupes trouvés pour diagnostic
if [ -n "$TERM_GROUPS_JSON" ] && ! echo "$TERM_GROUPS_JSON" | grep -q '"error"'; then
    log "  Groupes de termes disponibles :"
    printf '%s' "$TERM_GROUPS_JSON" | \
        jq -r '
          (if type == "array" then . else (.data // .termGroups // .groups // []) end)
          | .[] | "  - " + (.name // .slug // "?") + " [required=" + ((.required // false) | tostring) + "] : " +
            ([ .terms[]? | .name + "=" + .id ] | join(", "))
        ' 2>/dev/null | while IFS= read -r L; do log "$L"; done

    # Extraire dynamiquement les IDs du groupe "quais" (slug ou name contenant "quai")
    QUAI_WEB=$(printf '%s' "$TERM_GROUPS_JSON" | jq -r '
        (if type == "array" then . else (.data // .termGroups // .groups // []) end)
        | .[] | select((.name // .slug // "") | ascii_downcase | test("quai"))
        | .terms[]? | select((.name // "") | ascii_downcase | test("web-dl|webdl|web dl")) | .id
    ' 2>/dev/null | head -1)

    QUAI_WEBRIP=$(printf '%s' "$TERM_GROUPS_JSON" | jq -r '
        (if type == "array" then . else (.data // .termGroups // .groups // []) end)
        | .[] | select((.name // .slug // "") | ascii_downcase | test("quai"))
        | .terms[]? | select((.name // "") | ascii_downcase | test("webrip")) | .id
    ' 2>/dev/null | head -1)

    QUAI_BLURAY=$(printf '%s' "$TERM_GROUPS_JSON" | jq -r '
        (if type == "array" then . else (.data // .termGroups // .groups // []) end)
        | .[] | select((.name // .slug // "") | ascii_downcase | test("quai"))
        | .terms[]? | select((.name // "") | ascii_downcase | test("blu.?ray") and (test("remux") | not)) | .id
    ' 2>/dev/null | head -1)

    QUAI_REMUX=$(printf '%s' "$TERM_GROUPS_JSON" | jq -r '
        (if type == "array" then . else (.data // .termGroups // .groups // []) end)
        | .[] | select((.name // .slug // "") | ascii_downcase | test("quai"))
        | .terms[]? | select((.name // "") | ascii_downcase | test("remux")) | .id
    ' 2>/dev/null | head -1)

    QUAI_DVDRIP=$(printf '%s' "$TERM_GROUPS_JSON" | jq -r '
        (if type == "array" then . else (.data // .termGroups // .groups // []) end)
        | .[] | select((.name // .slug // "") | ascii_downcase | test("quai"))
        | .terms[]? | select((.name // "") | ascii_downcase | test("dvd")) | .id
    ' 2>/dev/null | head -1)

    QUAI_HDTV=$(printf '%s' "$TERM_GROUPS_JSON" | jq -r '
        (if type == "array" then . else (.data // .termGroups // .groups // []) end)
        | .[] | select((.name // .slug // "") | ascii_downcase | test("quai"))
        | .terms[]? | select((.name // "") | ascii_downcase | test("hdtv")) | .id
    ' 2>/dev/null | head -1)

    # Loguer les IDs trouvés
    log "  Quais découverts dynamiquement :"
    log "    WEB-DL  : ${QUAI_WEB:-<non trouvé>}"
    log "    WEBRip  : ${QUAI_WEBRIP:-<non trouvé>}"
    log "    BluRay  : ${QUAI_BLURAY:-<non trouvé>}"
    log "    REMUX   : ${QUAI_REMUX:-<non trouvé>}"
    log "    DVDRip  : ${QUAI_DVDRIP:-<non trouvé>}"
    log "    HDTV    : ${QUAI_HDTV:-<non trouvé>}"
else
    log "  WARN: termGroups non disponibles via API — utilisation des IDs hardcodés"
fi

# ── Fallback hardcodé si découverte dynamique échouée ────────────────────────
# Ces IDs sont issus de l'analyse du JS du site (bundle upload).
# À METTRE À JOUR si le site change ses IDs — relancer avec LOG_LEVEL=debug
# pour voir les groupes retournés par l'API et corriger ces valeurs.
# NOTE: vous pouvez les trouver en cherchant le terme dans le formulaire
# /upload du site et en inspectant les requêtes réseau (DevTools → Network).
[ -z "$QUAI_WEB" ]    && QUAI_WEB="UNKNOWN_RUN_DISCOVERY"
[ -z "$QUAI_WEBRIP" ] && QUAI_WEBRIP="UNKNOWN_RUN_DISCOVERY"
[ -z "$QUAI_BLURAY" ] && QUAI_BLURAY="UNKNOWN_RUN_DISCOVERY"
[ -z "$QUAI_REMUX" ]  && QUAI_REMUX="UNKNOWN_RUN_DISCOVERY"
[ -z "$QUAI_DVDRIP" ] && QUAI_DVDRIP="UNKNOWN_RUN_DISCOVERY"
[ -z "$QUAI_HDTV" ]   && QUAI_HDTV="UNKNOWN_RUN_DISCOVERY"

# ─── Récupération films Radarr ────────────────────────────────────────────────
log ""; log "Récupération des films Radarr..."
MOVIES_JSON="${WORK_DIR}/movies.json"
radarr_get "movie" > "$MOVIES_JSON" || { log "ERREUR: impossible de joindre Radarr"; exit 1; }
TOTAL=$(jq 'length' "$MOVIES_JSON")
TOTAL_WITH_FILE=$(jq '[.[] | select(.hasFile==true)] | length' "$MOVIES_JSON")
log "Total films : $TOTAL (avec fichier : $TOTAL_WITH_FILE)"

# ─── Statistiques ─────────────────────────────────────────────────────────────
UPLOADED=0; SKIPPED=0; ERRORS=0; LAST_ERROR=""
RESULTS_FILE="${WORK_DIR}/results.txt"
touch "$RESULTS_FILE"

# ─── Script Python pour création du torrent ───────────────────────────────────
PY="${WORK_DIR}/make_torrent.py"
printf '%s\n' '#!/usr/bin/env python3' > "$PY"
printf '%s\n' 'import sys, os, hashlib, time' >> "$PY"
printf '%s\n' '' >> "$PY"
printf '%s\n' 'def bencode(v):' >> "$PY"
printf '%s\n' '    if isinstance(v, int): return b"i" + str(v).encode() + b"e"' >> "$PY"
printf '%s\n' '    if isinstance(v, (bytes, bytearray)): return str(len(v)).encode() + b":" + bytes(v)' >> "$PY"
printf '%s\n' '    if isinstance(v, str):' >> "$PY"
printf '%s\n' '        e = v.encode("utf-8"); return str(len(e)).encode() + b":" + e' >> "$PY"
printf '%s\n' '    if isinstance(v, list): return b"l" + b"".join(bencode(i) for i in v) + b"e"' >> "$PY"
printf '%s\n' '    if isinstance(v, dict):' >> "$PY"
printf '%s\n' '        out = b"d"' >> "$PY"
printf '%s\n' '        for k in sorted(v.keys()):' >> "$PY"
printf '%s\n' '            bk = k.encode() if isinstance(k, str) else k' >> "$PY"
printf '%s\n' '            out += str(len(bk)).encode() + b":" + bk + bencode(v[k])' >> "$PY"
printf '%s\n' '        return out + b"e"' >> "$PY"
printf '%s\n' '' >> "$PY"
printf '%s\n' 'file_path, release_name, tracker_url, output_path = sys.argv[1:5]' >> "$PY"
printf '%s\n' '# Piece length adaptatif selon taille fichier (convention BitTorrent)' >> "$PY"
printf '%s\n' '# <  512 MiB  →  256 KiB' >> "$PY"
printf '%s\n' '# <    2 GiB  →  512 KiB' >> "$PY"
printf '%s\n' '# <    4 GiB  →    1 MiB' >> "$PY"
printf '%s\n' '# <    8 GiB  →    2 MiB' >> "$PY"
printf '%s\n' '# >=   8 GiB  →    4 MiB  (standard trackers privés, cible ~1000-2000 pièces)' >> "$PY"
printf '%s\n' 'import os as _os_tmp; _sz = _os_tmp.path.getsize(file_path)' >> "$PY"
printf '%s\n' 'if   _sz <  512 * 1024**2: piece_length = 256 * 1024' >> "$PY"
printf '%s\n' 'elif _sz <    2 * 1024**3: piece_length = 512 * 1024' >> "$PY"
printf '%s\n' 'elif _sz <    4 * 1024**3: piece_length = 1024 * 1024' >> "$PY"
printf '%s\n' 'elif _sz <    8 * 1024**3: piece_length = 2 * 1024 * 1024' >> "$PY"
printf '%s\n' 'else:                      piece_length = 4 * 1024 * 1024' >> "$PY"
printf '%s\n' 'if not os.path.exists(file_path):' >> "$PY"
printf '%s\n' '    print("ERREUR: fichier non trouve: " + file_path, file=sys.stderr); sys.exit(1)' >> "$PY"
printf '%s\n' 'file_size = os.path.getsize(file_path)' >> "$PY"
printf '%s\n' 'pieces = bytearray(); read = 0; last_pct = -1' >> "$PY"
printf '%s\n' 'print("  Fichier : " + os.path.basename(file_path))' >> "$PY"
printf '%s\n' 'print("  Taille  : " + str(round(file_size/(1024**3),2)) + " GiB")' >> "$PY"
printf '%s\n' 'print("  Calcul SHA1...")' >> "$PY"
printf '%s\n' 'with open(file_path, "rb") as f:' >> "$PY"
printf '%s\n' '    while True:' >> "$PY"
printf '%s\n' '        chunk = f.read(piece_length)' >> "$PY"
printf '%s\n' '        if not chunk: break' >> "$PY"
printf '%s\n' '        pieces += hashlib.sha1(chunk).digest(); read += len(chunk)' >> "$PY"
printf '%s\n' '        pct = int(read * 100 / file_size)' >> "$PY"
printf '%s\n' '        if pct // 10 != last_pct // 10: print("  " + str(pct) + "%", flush=True); last_pct = pct' >> "$PY"
printf '%s\n' '# Utiliser le nom de fichier réel (sans extension) comme nom dans le torrent' >> "$PY"
printf '%s\n' '# pour que qBittorrent puisse seeder sans renommage' >> "$PY"
printf '%s\n' 'import os as _os' >> "$PY"
printf '%s\n' '# info.name = nom complet avec extension (requis pour seed single-file)' >> "$PY"
printf '%s\n' 'file_basename = _os.path.basename(file_path)' >> "$PY"
printf '%s\n' 'info = {"name": file_basename, "piece length": piece_length, "pieces": bytes(pieces), "length": file_size, "private": 1, "source": "lacale"}' >> "$PY"
printf '%s\n' 'torrent = {"announce": tracker_url, "info": info, "created by": "uTorrent/3.5.5", "creation date": int(time.time()), "comment": ""}' >> "$PY"
printf '%s\n' 'with open(output_path, "wb") as f: f.write(bencode(torrent))' >> "$PY"
printf '%s\n' 'print("  Torrent OK: " + output_path)' >> "$PY"

# ─── Boucle sur les films (deux passes) ──────────────────────────────────────
# Pass 1 : contenus absents de La Cale (priorité maximale)
# Pass 2 : releases alternatives si quota non atteint (PASS_MODE=all)
jq -c '.[] | select(.hasFile==true and .movieFile != null)' "$MOVIES_JSON" \
    > "${WORK_DIR}/movies_with_files.jsonl"

PASS_MODE="unique"
log ""
log_section "Pass 1 — contenus absents de La Cale"

while IFS= read -r MOVIE_JSON; do

    [ "$UPLOADED" -ge "$MAX_MOVIES" ] && break

    # ── Extraction des champs ────────────────────────────────────────────
    MOVIE_ID=$(echo "$MOVIE_JSON"       | jq -r '.id')
    TITLE=$(echo "$MOVIE_JSON"          | jq -r '.title')
    YEAR=$(echo "$MOVIE_JSON"           | jq -r '.year')
    TMDB_ID=$(echo "$MOVIE_JSON"        | jq -r '.tmdbId // ""')
    OVERVIEW=$(echo "$MOVIE_JSON"       | jq -r '.overview // ""')
    RADARR_PATH=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.path // ""')
    RELEASE_GROUP=$(echo "$MOVIE_JSON"  | jq -r '.movieFile.releaseGroup // ""')
    QUALITY_NAME=$(echo "$MOVIE_JSON"   | jq -r '.movieFile.quality.quality.name // ""')
    VIDEO_CODEC=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.videoCodec // ""')
    AUDIO_LANGS=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.audioLanguages // ""')
    DYN_RANGE=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.videoDynamicRange // ""')
    DYN_TYPE=$(echo "$MOVIE_JSON"       | jq -r '.movieFile.mediaInfo.videoDynamicRangeType // ""')
    FILE_SIZE=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.size // 0')
    RUN_TIME=$(echo "$MOVIE_JSON"       | jq -r '.movieFile.mediaInfo.runTime // ""')
    AUDIO_CODEC=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.audioCodec // ""')
    AUDIO_CH=$(echo "$MOVIE_JSON"       | jq -r '.movieFile.mediaInfo.audioChannels // ""')
    SUBTITLES=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.subtitles // ""')
    VIDEO_BIT=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.videoBitrate // ""')
    VIDEO_FPS=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.videoFps // ""')
    VIDEO_DEPTH=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.videoBitDepth // ""')
    AUDIO_BIT=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.audioBitrate // ""')
    COVER_URL=$(echo "$MOVIE_JSON"      | jq -r '.images[]? | select(.coverType=="poster") | .remoteUrl // ""' | head -1)
    RATING=$(echo "$MOVIE_JSON"         | jq -r '.ratings.tmdb.value // .ratings.value // 0')
    GENRES=$(echo "$MOVIE_JSON"         | jq -r '[.genres[]? ] | join(", ")' 2>/dev/null || echo "")

    log ""
    log "────────────────────────────────────────────────────────────"
    log "Film          : $TITLE ($YEAR)  [Radarr ID: $MOVIE_ID]"

    FILENAME=$(basename "$RADARR_PATH")
    FNAME_UP=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]')

    log "Fichier       : $FILENAME"
    log "ReleaseGroup  : ${RELEASE_GROUP:-<vide>}"
    log "Qualite       : $QUALITY_NAME"

    [ -z "$RADARR_PATH" ] && {
        log "  SKIP: chemin fichier vide"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Chemin vide" >> "$RESULTS_FILE"
        continue
    }

    # ── Chemin réel sur le NAS ───────────────────────────────────────────
    NAS_FILE_PATH=$(resolve_nas_path "$RADARR_PATH")
    log "Chemin NAS    : ${NAS_FILE_PATH:-INTROUVABLE}"

    if [ -z "$NAS_FILE_PATH" ] || [ ! -f "$NAS_FILE_PATH" ]; then
        log "  SKIP: fichier introuvable sur le NAS (Radarr desynchronise ?)"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Fichier manquant" >> "$RESULTS_FILE"
        continue
    fi

    # ── Filtre qualité minimale ───────────────────────────────────────────
    if ! meets_min_quality "$QUALITY_NAME"; then
        log "  SKIP: qualité insuffisante ($QUALITY_NAME < ${MIN_QUALITY})"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Qualité insuffisante ($QUALITY_NAME)" >> "$RESULTS_FILE"
        continue
    fi

    # ── Fichier d'exclusion ──────────────────────────────────────────────
    if is_excluded "$TMDB_ID" "$TITLE"; then
        log "  SKIP: exclu (EXCLUDE_FILE)"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Exclusion explicite" >> "$RESULTS_FILE"
        continue
    fi

    # ── Release group ────────────────────────────────────────────────────
    if [ -z "$RELEASE_GROUP" ] || [ "$RELEASE_GROUP" = "null" ]; then
        STEM=$(echo "$FILENAME" | sed 's/\.[^.]*$//')
        RELEASE_GROUP=$(echo "$STEM" | grep -oE '\-[A-Za-z0-9]+$' | tr -d '-')
        if [ -n "$RELEASE_GROUP" ]; then
            log "  WARN: releaseGroup vide → extrait du nom de fichier: $RELEASE_GROUP"
        else
            log "  WARN: releaseGroup inconnu → release name sans groupe"
        fi
    fi

    # ── Construction du nom de release ───────────────────────────────────
    # Si le fichier est déjà au format scene (points, pas d'espaces ni parenthèses)
    # → utiliser directement le stem du fichier comme RELEASE_NAME
    FILE_STEM=$(echo "$FILENAME" | sed 's/\.[^.]*$//')
    if ! echo "$FILE_STEM" | grep -q '[[:space:]()\[]'; then
        RELEASE_NAME="$FILE_STEM"
        log "Release name  : $RELEASE_NAME  (depuis nom fichier)"
    else
        # Fallback : reconstruction depuis métadonnées Radarr
        # Nettoyage du titre : accents, apostrophes, cédilles, ponctuation
        log "  WARN: nom fichier non-scene → reconstruction depuis métadonnées"
        TITLE_CLEAN=$(echo "$TITLE" \
            | sed "y/àâäåéèêëïîìôöòùûüçñÀÂÄÅÉÈÊËÏÎÌÔÖÒÙÛÜÇÑ/aaaaeeeeiiiooouuucnAAAAEEEEIIIOOOUUUCN/" \
            | sed "s/[''ʼ]//g" \
            | sed 's/://g' \
            | sed 's/["!?,;{}()\[\]]//g' \
            | sed 's/  */ /g' \
            | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' \
            | sed 's/ /./g' \
            | sed 's/\.\././g')

        # ── Info (REPACK, PROPER) ─────────────────────────────────────────
        INFO_TAG=""
        case "$FNAME_UP" in
            *REPACK2*) INFO_TAG="REPACK2" ;;
            *REPACK*)  INFO_TAG="REPACK" ;;
            *PROPER2*) INFO_TAG="PROPER2" ;;
            *PROPER*)  INFO_TAG="PROPER" ;;
            *RERIP*)   INFO_TAG="RERip" ;;
        esac

        # ── Édition (DC, EXTENDED, UNRATED, REMASTERED, CRITERION…) ──────
        EDITION_TAG=""
        _ed=""
        echo "$FNAME_UP" | grep -qE '\.DC\.|DIRECTORS.CUT' && _ed="${_ed}.DC"
        echo "$FNAME_UP" | grep -q 'EXTENDED'              && _ed="${_ed}.EXTENDED"
        echo "$FNAME_UP" | grep -q 'UNRATED'               && _ed="${_ed}.UNRATED"
        echo "$FNAME_UP" | grep -qE 'REMASTER'             && _ed="${_ed}.REMASTERED"
        echo "$FNAME_UP" | grep -q 'RESTORED'              && _ed="${_ed}.Restored"
        echo "$FNAME_UP" | grep -q 'CRITERION'             && _ed="${_ed}.CRiTERION"
        echo "$FNAME_UP" | grep -q 'FINAL.CUT'             && _ed="${_ed}.FiNAL.CUT"
        EDITION_TAG=$(echo "$_ed" | sed 's/^\.//')

        # ── IMAX ─────────────────────────────────────────────────────────
        IMAX_TAG=""
        echo "$FNAME_UP" | grep -q 'IMAX' && IMAX_TAG="iMAX"

        # ── Langue ───────────────────────────────────────────────────────
        if echo "$FNAME_UP" | grep -q 'MULTI'; then
            if   echo "$FNAME_UP" | grep -qE 'TRUEFRENCH|VFF'; then LANG_TAG="MULTi.VFF"
            elif echo "$FNAME_UP" | grep -q 'VFQ';             then LANG_TAG="MULTi.VFQ"
            elif echo "$FNAME_UP" | grep -q 'VF2';             then LANG_TAG="MULTi.VF2"
            elif echo "$FNAME_UP" | grep -q 'VFI';             then LANG_TAG="MULTi.VFi"
            else                                                     LANG_TAG="MULTi"
            fi
        elif echo "$FNAME_UP" | grep -qE 'TRUEFRENCH|VFF'; then LANG_TAG="TRUEFRENCH"
        elif echo "$FNAME_UP" | grep -q 'VOSTFR';          then LANG_TAG="VOSTFR"
        elif echo "$FNAME_UP" | grep -q 'VOF';             then LANG_TAG="VOF"
        elif echo "$FNAME_UP" | grep -qE 'FRENCH';         then LANG_TAG="FRENCH"
        elif echo "$FNAME_UP" | grep -q 'DUAL';            then LANG_TAG="DUAL"
        else
            LANG_COUNT=$(echo "$AUDIO_LANGS" | tr '/' '\n' | grep -c '[a-z]' 2>/dev/null || echo 0)
            if [ "$LANG_COUNT" -gt 1 ]; then LANG_TAG="MULTi"
            elif echo "$AUDIO_LANGS" | grep -qi 'french\|fra'; then LANG_TAG="FRENCH"
            else LANG_TAG="FRENCH"
            fi
        fi

        # Descripteur langue additionnel (AD = audiodescription)
        LANG_INFO=""
        echo "$FNAME_UP" | grep -qE '\.AD\.|\-AD\.' && LANG_INFO="AD"

        # ── HDR / DV ─────────────────────────────────────────────────────
        HDR_TAG=""
        if echo "$FNAME_UP$DYN_RANGE$DYN_TYPE" | grep -qi 'HDR10+\|HDR10PLUS'; then HDR_TAG="HDR10+"
        elif echo "$FNAME_UP$DYN_RANGE$DYN_TYPE" | grep -qi 'HDR'; then HDR_TAG="HDR"
        fi
        if echo "$FNAME_UP$DYN_TYPE" | grep -qi 'DV\|DOLBY.VISION\|DOLBYVISION'; then
            [ -n "$HDR_TAG" ] && HDR_TAG="${HDR_TAG}.DV" || HDR_TAG="DV"
        fi

        # ── Résolution ───────────────────────────────────────────────────
        QN_UP=$(echo "$QUALITY_NAME" | tr '[:lower:]' '[:upper:]')
        if   echo "$QN_UP$FNAME_UP" | grep -qE '2160|4K'; then RESOLUTION="2160p"
        elif echo "$QN_UP$FNAME_UP" | grep -q '1080';     then RESOLUTION="1080p"
        elif echo "$QN_UP$FNAME_UP" | grep -q '720';      then RESOLUTION="720p"
        else RESOLUTION=""
        fi

        # ── Plateforme de streaming ───────────────────────────────────────
        PLATFORM=""
        case "$FNAME_UP" in
            *\.NF\.*|*\.NETFLIX\.*) PLATFORM="NF" ;;
            *\.AMZN\.*|*\.AMAZON\.*) PLATFORM="AMZN" ;;
            *\.DSNP\.*|*\.DISNEY\.*) PLATFORM="DSNP" ;;
            *\.ATVP\.*)             PLATFORM="ATVP" ;;
            *\.HMAX\.*|*\.MAX\.*)   PLATFORM="MAX" ;;
            *\.PMTP\.*)             PLATFORM="PMTP" ;;
            *\.HULU\.*)             PLATFORM="HULU" ;;
            *\.ADN\.*)              PLATFORM="ADN" ;;
            *\.PCOK\.*)             PLATFORM="PCOK" ;;
        esac

        # ── Source ───────────────────────────────────────────────────────
        QL=$(echo "$QUALITY_NAME" | tr '[:upper:]' '[:lower:]')
        case "$FNAME_UP" in
            *COMPLETE*UHD*BLU*)       SOURCE="COMPLETE.UHD.BLURAY" ;;
            *COMPLETE*BLU*)           SOURCE="COMPLETE.BLURAY" ;;
            *BLU*REMUX*|*BD*REMUX*)   SOURCE="BluRay.REMUX" ;;
            *DVD*REMUX*)              SOURCE="DVD.REMUX" ;;
            *REMUX*)                  SOURCE="REMUX" ;;
            *4KLIGHT*)                SOURCE="4KLight" ;;
            *HDLIGHT*)                SOURCE="HDLight" ;;
            *\.MHD\.*)                SOURCE="mHD" ;;
            *BLURAY*|*BLU-RAY*|*BDRIP*) SOURCE="BluRay" ;;
            *WEB-DL*|*WEBDL*)         SOURCE="WEB-DL" ;;
            *WEBRIP*)                 SOURCE="WEBRip" ;;
            *DVDRIP*)                 SOURCE="DVDRip" ;;
            *HDTV*)                   SOURCE="HDTV" ;;
            *) case "$QL" in
                *webdl*|*web-dl*) SOURCE="WEB-DL" ;;
                *webrip*)         SOURCE="WEBRip" ;;
                *bluray*)         SOURCE="BluRay" ;;
                *)                SOURCE="WEB" ;;
               esac ;;
        esac

        # ── Codec vidéo ──────────────────────────────────────────────────
        if   echo "$FNAME_UP$VIDEO_CODEC" | grep -qiE 'X265|H265|HEVC'; then CODEC="x265"
        elif echo "$FNAME_UP$VIDEO_CODEC" | grep -qiE 'X264|H264|AVC';  then CODEC="x264"
        elif echo "$FNAME_UP$VIDEO_CODEC" | grep -qi  'AV1';            then CODEC="AV1"
        elif echo "$FNAME_UP$VIDEO_CODEC" | grep -qi  'VC.1\|VC-1';    then CODEC="VC-1"
        elif echo "$FNAME_UP"             | grep -qi  'XVID';           then CODEC="XviD"
        elif echo "$FNAME_UP"             | grep -qiE 'MPEG2|MPEG';     then CODEC="MPEG"
        else CODEC="x264"
        fi

        # ── Codec audio ──────────────────────────────────────────────────
        AUDIO_TAG=""
        AC_UP=$(echo "$AUDIO_CODEC" | tr '[:lower:]' '[:upper:]')
        case "$AC_UP" in
            *TRUEHD*)              AUDIO_TAG="TrueHD" ;;
            *EAC3*|*E-AC3*|*DDP*) AUDIO_TAG="EAC3" ;;
            *AC3*|*DD*)            AUDIO_TAG="AC3" ;;
            *DTS:X*|*DTSX*)        AUDIO_TAG="DTS-X" ;;
            *DTS-HD*MA*|*DTSHDMA*) AUDIO_TAG="DTS-HD.MA" ;;
            *DTS-HD*|*DTSHD*)      AUDIO_TAG="DTS-HD" ;;
            *DTS*)                 AUDIO_TAG="DTS" ;;
            *AAC*)                 AUDIO_TAG="AAC" ;;
            *FLAC*)                AUDIO_TAG="FLAC" ;;
            *OPUS*)                AUDIO_TAG="OPUS" ;;
        esac

        # Canaux audio (5.1, 7.1…)
        AUDIO_CH_TAG=""
        if   echo "$FNAME_UP" | grep -qE '7\.1'; then AUDIO_CH_TAG="7.1"
        elif echo "$FNAME_UP" | grep -qE '5\.1'; then AUDIO_CH_TAG="5.1"
        elif echo "$FNAME_UP" | grep -qE '2\.0'; then AUDIO_CH_TAG="2.0"
        fi

        # Atmos
        AUDIO_SPEC=""
        echo "$FNAME_UP" | grep -q 'ATMOS' && AUDIO_SPEC="Atmos"

        # ── Assemblage selon règles La Cale ──────────────────────────────
        # Ordre : Titre.Année.[Info].[Edition].[IMAX].Langue.[LangInfo].[HDR].[Résolution].[Plateforme].Source.[Audio].[Canaux].[Spec].Codec-Groupe
        RELEASE_NAME="${TITLE_CLEAN}.${YEAR}"
        [ -n "$INFO_TAG" ]    && RELEASE_NAME="${RELEASE_NAME}.${INFO_TAG}"
        [ -n "$EDITION_TAG" ] && RELEASE_NAME="${RELEASE_NAME}.${EDITION_TAG}"
        [ -n "$IMAX_TAG" ]    && RELEASE_NAME="${RELEASE_NAME}.${IMAX_TAG}"
        RELEASE_NAME="${RELEASE_NAME}.${LANG_TAG}"
        [ -n "$LANG_INFO" ]   && RELEASE_NAME="${RELEASE_NAME}.${LANG_INFO}"
        [ -n "$HDR_TAG" ]     && RELEASE_NAME="${RELEASE_NAME}.${HDR_TAG}"
        [ -n "$RESOLUTION" ]  && RELEASE_NAME="${RELEASE_NAME}.${RESOLUTION}"
        [ -n "$PLATFORM" ]    && RELEASE_NAME="${RELEASE_NAME}.${PLATFORM}"
        RELEASE_NAME="${RELEASE_NAME}.${SOURCE}"
        [ -n "$AUDIO_TAG" ]   && RELEASE_NAME="${RELEASE_NAME}.${AUDIO_TAG}"
        [ -n "$AUDIO_CH_TAG" ] && RELEASE_NAME="${RELEASE_NAME}.${AUDIO_CH_TAG}"
        [ -n "$AUDIO_SPEC" ]  && RELEASE_NAME="${RELEASE_NAME}.${AUDIO_SPEC}"
        if [ -n "$RELEASE_GROUP" ] && [ "$RELEASE_GROUP" != "null" ]; then
            RELEASE_NAME="${RELEASE_NAME}.${CODEC}-${RELEASE_GROUP}"
        else
            RELEASE_NAME="${RELEASE_NAME}.${CODEC}-NOGRP"
        fi
        log "Release name  : $RELEASE_NAME  (reconstruit)"
    fi

    # FNAME_UP recalculé depuis RELEASE_NAME final pour les termIds
    FNAME_UP=$(echo "$RELEASE_NAME" | tr '[:lower:]' '[:upper:]')

    # ── Vérification historique local ────────────────────────────────────
    if [ -f "$HISTORIQUE_FILE" ] && grep -qiF "$RELEASE_NAME" "$HISTORIQUE_FILE"; then
        log "  SKIP: déjà dans l'historique local"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Historique local" >> "$RESULTS_FILE"
        continue
    fi

    # ── Vérification doublon sur La Cale (avec cache TTL) ────────────────
    log "  Vérification doublon sur La Cale (TMDb:${TMDB_ID:-?})..."
    RELEASE_COUNT=$(count_releases_lacale "$TMDB_ID" "$TITLE")
    log "  Trouvé $RELEASE_COUNT release(s) sur La Cale"

    if [ "$PASS_MODE" = "unique" ] && [ "$RELEASE_COUNT" -gt 0 ]; then
        log "  SKIP: déjà sur La Cale ($RELEASE_COUNT release(s)) — pass 1 (unique)"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Déjà sur La Cale (pass 1)" >> "$RESULTS_FILE"
        continue
    fi

    log "  → Absent sur La Cale (pass ${PASS_MODE:-1}), on continue."

    # ── Récupération casting TMDB (via API La Cale) ───────────────────────
    CAST_JSON="[]"
    if [ -n "$TMDB_ID" ] && [ "$TMDB_ID" != "null" ] && [ "$TMDB_ID" != "0" ]; then
        TMDB_DETAIL=$(curl -sf --max-time 15 \
            -A "$BROWSER_UA" \
            -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
            -H "Accept: application/json" \
            --compressed \
            "${LACALE_URL}/api/internal/tmdb/details?id=${TMDB_ID}&type=movie" 2>/dev/null)
        if [ -n "$TMDB_DETAIL" ]; then
            # Extraire cast: array [{name, character}]
            CAST_JSON=$(printf '%s' "$TMDB_DETAIL" | jq '[.cast[]? | {name:.name, character:.character}] // []' 2>/dev/null || echo "[]")
            # Récupérer rating/genres TMDB si meilleurs que ceux de Radarr
            TMDB_RATING=$(printf '%s' "$TMDB_DETAIL" | jq -r '.rating // 0' 2>/dev/null)
            TMDB_GENRES=$(printf '%s' "$TMDB_DETAIL" | jq -r '.genres // ""' 2>/dev/null)
            [ -n "$TMDB_RATING" ] && [ "$TMDB_RATING" != "0" ] && [ "$TMDB_RATING" != "null" ] && RATING="$TMDB_RATING"
            [ -n "$TMDB_GENRES" ] && [ "$TMDB_GENRES" != "null" ] && GENRES="$TMDB_GENRES"
        fi
    fi

    # ── Rescan Radarr pour synchroniser relativePath avec le fichier réel ──
    RESCAN_RESP=$(curl -sf --max-time 30 \
        -X POST \
        -H "Content-Type: application/json" \
        "${RADARR_URL}/api/v3/command?apikey=${RADARR_API_KEY}" \
        -d "{\"name\":\"RescanMovie\",\"movieId\":${MOVIE_ID}}" 2>/dev/null)
    if [ -n "$RESCAN_RESP" ]; then
        sleep 5
        FRESH_JSON=$(curl -sf --max-time 15 \
            "${RADARR_URL}/api/v3/movie/${MOVIE_ID}?apikey=${RADARR_API_KEY}" 2>/dev/null)
        if [ -n "$FRESH_JSON" ]; then
            RADARR_PATH=$(echo "$FRESH_JSON"  | jq -r '.movieFile.path // ""')
            RELEASE_GROUP=$(echo "$FRESH_JSON"| jq -r '.movieFile.releaseGroup // ""')
            QUALITY_NAME=$(echo "$FRESH_JSON" | jq -r '.movieFile.quality.quality.name // ""')
            VIDEO_CODEC=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.videoCodec // ""')
            AUDIO_LANGS=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.audioLanguages // ""')
            DYN_RANGE=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.videoDynamicRange // ""')
            DYN_TYPE=$(echo "$FRESH_JSON"     | jq -r '.movieFile.mediaInfo.videoDynamicRangeType // ""')
            FILE_SIZE=$(echo "$FRESH_JSON"    | jq -r '.movieFile.size // 0')
            RUN_TIME=$(echo "$FRESH_JSON"     | jq -r '.movieFile.mediaInfo.runTime // ""')
            AUDIO_CODEC=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.audioCodec // ""')
            AUDIO_CH=$(echo "$FRESH_JSON"     | jq -r '.movieFile.mediaInfo.audioChannels // ""')
            SUBTITLES=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.subtitles // ""')
            VIDEO_BIT=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.videoBitrate // ""')
            VIDEO_FPS=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.videoFps // ""')
            VIDEO_DEPTH=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.videoBitDepth // ""')
            AUDIO_BIT=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.audioBitrate // ""')
            FILENAME=$(basename "$RADARR_PATH")
            FNAME_UP=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]')
            log "  ✓ Rescan Radarr OK — fichier: $FILENAME"
        fi
    else
        log "  WARN: Rescan Radarr echoue — donnees potentiellement obsoletes"
    fi

    # ── MediaInfo + Création du torrent (Docker Alpine) ──────────────────
    log "  Génération NFO (mediainfo) + création du torrent..."
    NFO_PATH="${NFO_DIR}/${RELEASE_NAME}.nfo"
    TORRENT_PATH="${TORRENTS_DIR}/${RELEASE_NAME}.torrent"

    FOLDER_NAME=$(echo "$RADARR_PATH" | sed "s|^${RADARR_PATH_PREFIX}/||" | cut -d'/' -f1)
    log "  Dossier film  : $FOLDER_NAME"

    TORRENT_OK=0
    docker run --rm \
        -v "${NAS_PATH_PREFIX}:/mnt/zfs:ro" \
        -v "${WORK_DIR}:/work:rw" \
        -e "IN_FOLDER=${FOLDER_NAME}" \
        -e "IN_FILE=$(echo "$RADARR_PATH" | sed "s|^${RADARR_PATH_PREFIX}/||" | cut -d'/' -f2-)" \
        -e "REL_NAME=${RELEASE_NAME}" \
        -e "TRACKER=${TRACKER_URL}" \
        "$DOCKER_PYTHON" \
        sh -c '
            apk add --no-cache python3 mediainfo -q 2>/dev/null
            FULL_PATH=$(ls -d /mnt/zfs/*/Films/"$IN_FOLDER"/"$IN_FILE" 2>/dev/null | head -1)
            if [ -z "$FULL_PATH" ] || [ ! -f "$FULL_PATH" ]; then
                echo "ERREUR: fichier non trouvé dans Docker: $IN_FOLDER/$IN_FILE" >&2
                exit 1
            fi
            echo "  Chemin Docker : $FULL_PATH"
            mediainfo "$FULL_PATH" > "/work/$REL_NAME.nfo" 2>/dev/null || true
            python3 /work/make_torrent.py \
                "$FULL_PATH" \
                "$REL_NAME" \
                "$TRACKER" \
                "/work/$REL_NAME.torrent"
        ' && TORRENT_OK=1

    # NFO : priorité mediainfo, fallback Radarr
    NFO_SOURCE="mediainfo (Alpine)"
    if [ -f "${WORK_DIR}/${RELEASE_NAME}.nfo" ] && [ -s "${WORK_DIR}/${RELEASE_NAME}.nfo" ]; then
        # Nettoie le chemin Docker interne (/mnt/zfs/...) → juste le nom de fichier
        _EXT=$(echo "$FILENAME" | grep -oE '\.[^.]+$' | tr '[:upper:]' '[:lower:]')
        sed "s|Complete name[[:space:]]*:.*|Complete name                            : ${RELEASE_NAME}${_EXT}|g" \
            "${WORK_DIR}/${RELEASE_NAME}.nfo" > "$NFO_PATH"
        log "  NFO : $(wc -c < "$NFO_PATH") chars via $NFO_SOURCE"
    else
        NFO_SOURCE="Radarr mediaInfo (fallback)"
        SIZE_GIB=$(echo "$FILE_SIZE" | awk '{printf "%.2f", $1/1073741824}')
        printf 'General\nComplete name : %s\nFile size     : %s GiB\nDuration      : %s\n\nVideo\nFormat        : %s\nBit rate      : %s kb/s\nFrame rate    : %s FPS\nBit depth     : %s bits\nHDR           : %s\n\nAudio\nFormat        : %s\nBit rate      : %s kb/s\nChannel(s)    : %s channels\nLanguage(s)   : %s\n\nSubtitles     : %s\n' \
            "$FILENAME" "$SIZE_GIB" "$RUN_TIME" \
            "$VIDEO_CODEC" "$VIDEO_BIT" "$VIDEO_FPS" "$VIDEO_DEPTH" "$DYN_RANGE" \
            "$AUDIO_CODEC" "$AUDIO_BIT" "$AUDIO_CH" "$AUDIO_LANGS" \
            "$SUBTITLES" > "$NFO_PATH"
        log "  WARN: mediainfo échoué → NFO depuis données Radarr"
        log "  NFO : $(wc -c < "$NFO_PATH") chars via $NFO_SOURCE"
    fi
    log "  NFO sauvegardé : $NFO_PATH"

    if [ "$TORRENT_OK" -eq 1 ] && [ -f "${WORK_DIR}/${RELEASE_NAME}.torrent" ]; then
        cp "${WORK_DIR}/${RELEASE_NAME}.torrent" "$TORRENT_PATH"
    fi

    if [ "$TORRENT_OK" -eq 0 ] || [ ! -f "$TORRENT_PATH" ]; then
        log "  ERREUR: création du torrent échouée"
        ERRORS=$((ERRORS+1))
        echo "ERREUR|$TITLE ($YEAR)|Création torrent échouée" >> "$RESULTS_FILE"
        continue
    fi
    log "  ✓ Torrent créé : $TORRENT_PATH"

    # ── Re-vérification fraîche avant upload (invalide le cache) ─────────────
    FRESH_COUNT=$(count_releases_lacale_fresh "$TMDB_ID" "$TITLE")
    if [ "$PASS_MODE" = "unique" ] && [ "$FRESH_COUNT" -gt 0 ]; then
        log "  SKIP: apparu sur La Cale pendant le traitement ($FRESH_COUNT release(s))"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Apparu sur La Cale pendant traitement" >> "$RESULTS_FILE"
        continue
    fi

    # ── Vérification doublon par info_hash (API parse) ────────────────────────
    PARSE_RESULT=$(curl -sf --max-time 30 \
        -A "$BROWSER_UA" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H "Accept: application/json" \
        -H "Referer: ${LACALE_URL}/upload" \
        -H "Origin: ${LACALE_URL}" \
        --compressed \
        -X POST \
        -F "file=@${TORRENT_PATH};type=application/x-bittorrent" \
        "${LACALE_URL}/api/internal/torrents/parse" 2>/dev/null)
    if echo "$PARSE_RESULT" | grep -qi '"duplicate"[[:space:]]*:[[:space:]]*true\|"exists"[[:space:]]*:[[:space:]]*true\|already exist\|torrentId'; then
        log "  SKIP: torrent déjà présent sur La Cale (info_hash identique)"
        echo "$RELEASE_NAME" >> "$HISTORIQUE_FILE"
        SKIPPED=$((SKIPPED+1))
        echo "SKIP|$TITLE ($YEAR)|Doublon hash détecté via /api/internal/torrents/parse" >> "$RESULTS_FILE"
        continue
    fi

    # ── Délai anti-rate-limit entre uploads ──────────────────────────────────
    [ "$UPLOADED" -gt 0 ] && [ "${UPLOAD_DELAY:-3}" -gt 0 ] && sleep "$UPLOAD_DELAY"

    # ── Mapping des termIds (Caractéristiques de la release) ─────────────────
    TERM_IDS=""

    # Helper: ajouter un term
    add_term() { TERM_IDS="${TERM_IDS:+${TERM_IDS},}$1"; }


    # --- Genres (depuis Radarr/TMDB) ---
    echo "$GENRES" | tr ',/' '\n' | while read -r G; do
        G=$(echo "$G" | sed 's/^ *//;s/ *$//')
        case "$G" in
            Action)           echo "term_561bfb1bc6aa4eb236a0096055df56d3" ;;
            Animation)        echo "term_104b4c4889059907b69469199e91e650" ;;
            Adventure|Aventure) echo "term_53318115f9881cba4ea3c5d5fbcbdd7a" ;;
            Biography|Biopic) echo "term_fc1f45b5830a6c43ac1e04c15de20fd6" ;;
            Comedy|Comédie)   echo "term_2565c6c823f8770fd7bcaaf8825676e1" ;;
            Documentary|Documentaire) echo "term_5c93004f538b8ff2d0384371e52f6926" ;;
            Drama|Drame)      echo "term_86aac9f2daee035fd7fdbec3c01ec49c" ;;
            Family|Familial)  echo "term_15736578e8038ed0adb120204921a6e3" ;;
            Fantasy|Fantastique) echo "term_2c74d8bf4a34c8b3f1f41e66aebd5ec9" ;;
            History|Historique) echo "term_6b60cdc761f4ea38e98a035868a73692" ;;
            Horror|Horreur)   echo "term_6ec3481f6e45a178a3246e09a3be844b" ;;
            Music|Musical)    echo "term_983454715ab3dbc095012bf20dc27ba7" ;;
            "Crime"|"Policier / Thriller"|Thriller|Crime) echo "term_6dbb7e22f0aae37746d710ea3e23ce03" ;;
            Romance)          echo "term_fb1342ef0b14b7384a3e450335e3fdc2" ;;
            "Science Fiction"|"Science-fiction"|Sci-Fi) echo "term_845f0e31f46f4cfdf305681732759559" ;;
            Sport|Sports)     echo "term_c6d861d65b8d6191e24d48fd18347581" ;;
            War|Guerre)       echo "term_ffcb1f78a535d21a627116bb84b9fdb3" ;;
            Western)          echo "term_6ba0e4717a668f400cd2526debb7d0fc" ;;
            Suspense)         echo "term_788f7971971cfa7d4f7ff3028b17dcda" ;;
            "TV Movie"|Téléfilm) echo "term_30d959f14ad88fc00700173a23c386d8" ;;
        esac
    done > "${WORK_DIR}/genre_terms.txt"
    while IFS= read -r T; do [ -n "$T" ] && add_term "$T"; done < "${WORK_DIR}/genre_terms.txt"

    # --- Qualité / Résolution ---
    case "$RESOLUTION" in
        2160p) add_term "term_947df6343911cdf2c9e477cf4bddfc56" ;;
        1080p) add_term "term_e7dd3707cd20c0cfccd272334eba5bbf" ;;
        720p)  add_term "term_4437c0c05981fa692427eb0d92a25a34" ;;
        *)     add_term "term_6ade2712b8348f39b892c00119915454" ;;  # SD
    esac

    # --- Codec vidéo ---
    case "$CODEC" in
        x265) add_term "term_27dc36ee2c6fad6b87d71ed27e4b8266" ;;
        x264) add_term "term_9289368e710fa0c350a4c64f36fb03b5" ;;
        AV1)  add_term "term_e2806600360399f7597c9d582325d1ea" ;;
    esac

    # --- Caractéristiques vidéo ---
    case "$HDR_TAG" in
        *HDR10+*) add_term "term_3458ddfaf530675b6566cf48cda76001" ;;
        *HDR*)    add_term "term_1e6061fe0dd0f6ce8027b1bce83b6b7d" ;;
    esac
    case "$HDR_TAG" in *DV*) add_term "term_51d58202387e82525468fc738da02246" ;; esac
    [ "$VIDEO_DEPTH" = "10" ] && add_term "term_ca34690b0fb2717154811a343bbfe05a"

    # --- Source / Type (ET quai obligatoire) ─────────────────────────────────
    # IMPORTANT: Le site exige EXACTEMENT UN term du groupe "quais".
    case "$SOURCE" in
        "COMPLETE.UHD.BLURAY"|"COMPLETE.BLURAY")
            add_term "term_6251bf6918d6193d846e871b8b1c2f58"
            [ "$QUAI_BLURAY" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_BLURAY" || \
              log "  WARN: ID quai BluRay inconnu — upload pourrait échouer (400)"
            ;;
        "BluRay.REMUX"|"DVD.REMUX"|"REMUX")
            add_term "term_fdb58f8f752de86716d0312fcfecbc71"
            add_term "term_6251bf6918d6193d846e871b8b1c2f58"
            [ "$QUAI_REMUX"  != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_REMUX"  || \
            { log "  WARN: ID quai REMUX inconnu — fallback BluRay"; add_term "$QUAI_BLURAY"; }
            ;;
        "BluRay")
            add_term "term_6251bf6918d6193d846e871b8b1c2f58"
            [ "$QUAI_BLURAY" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_BLURAY" || \
              log "  WARN: ID quai BluRay inconnu — upload pourrait échouer (400)"
            ;;
        "WEB-DL"|"WEB"|"HDLight"|"4KLight"|"mHD")
            add_term "term_8d7cfc3d0e1178ae2925ef270235b8d3"
            [ "$QUAI_WEB"    != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_WEB"    || \
              log "  WARN: ID quai WEB-DL inconnu — upload pourrait échouer (400)"
            ;;
        "WEBRip")
            add_term "term_2ad87475841ea5d8111d089e5f6f2108"
            [ "$QUAI_WEBRIP" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_WEBRIP" || \
            { log "  WARN: ID quai WEBRip inconnu — fallback WEB-DL";
              [ "$QUAI_WEB" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_WEB"; }
            ;;
        "DVDRip")
            add_term "term_7321eb03c51abdd81902fcff4cd26171"
            [ "$QUAI_DVDRIP" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_DVDRIP" || \
              log "  WARN: ID quai DVDRip inconnu — upload pourrait échouer (400)"
            ;;
        "HDTV")
            add_term "term_b3cd9652a11c4bd9cdcbb7597ab8c39b"
            [ "$QUAI_HDTV"   != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_HDTV"   || \
              log "  WARN: ID quai HDTV inconnu — upload pourrait échouer (400)"
            ;;
    esac

    # --- Codec audio ---
    AUDIO_UP=$(echo "$AUDIO_CODEC" | tr '[:lower:]' '[:upper:]')
    case "$AUDIO_UP" in
        *TRUEHD*ATMOS*|*ATMOS*TRUEHD*) add_term "term_a2cf45267addea22635047c4d69465a0" ;;
        *TRUEHD*)    add_term "term_99a276df7596f2eb0902463e95111b76" ;;
        *EAC3*ATMOS*|*ATMOS*EAC3*) add_term "term_4671d371281904dcc885ddc92e92136d" ;;
        *EAC3*|*E-AC3*) add_term "term_8945be80314068e014c773f9d4cd7eb2" ;;
        *AC3*|*DD*)  add_term "term_e72a6bc1a89ca8c39f7a7fac21b95ef8" ;;
        *DTS:X*|*DTSX*) add_term "term_b3c9a9660e1c6ab6910859254fd592e1" ;;
        *DTSHDMA*|*DTSHD*MA*) add_term "term_49617ee39348e811452a2a4b7f5c0c64" ;;
        *DTSHD*|*DTS-HD*) add_term "term_934dcc048eaa8b4ef48548427735a797" ;;
        *DTS*)       add_term "term_d908f74951dee053ddada1bc0a8206db" ;;
        *AAC*)       add_term "term_b7ce0315952660c99a4ef7099b9154cb" ;;
        *FLAC*)      add_term "term_d857503fbf92ed967f81742146619c40" ;;
        *OPUS*)      add_term "term_b7ce0315952660c99a4ef7099b9154cb" ;;
        *MP3*)       add_term "term_0e2cdd8fd9f0031e7ffdbdb9255b8a31" ;;
    esac
    echo "$FNAME_UP" | grep -q 'ATMOS' && add_term "term_4671d371281904dcc885ddc92e92136d"

    # --- Langues audio ---
    case "$LANG_TAG" in
        MULTi*VFF|MULTi*VF2)
            add_term "term_fd7d017b825ebf12ce579dacea342e9d"  # MULTI
            add_term "term_bf31bb0a956b133988c2514f62eb1535"  # VFF
            ;;
        MULTi*VFQ)
            add_term "term_fd7d017b825ebf12ce579dacea342e9d"  # MULTI
            add_term "term_5fe7a76209bfc33e981ac5a2ca5a2e40"  # VFQ
            add_term "term_c87b5416341e6516baac12aa01fc5bc9"  # English
            ;;
        MULTi)
            add_term "term_fd7d017b825ebf12ce579dacea342e9d"  # MULTI
            add_term "term_bf918c3858a7dfe3b44ca70232f50272"  # French
            add_term "term_c87b5416341e6516baac12aa01fc5bc9"  # English
            ;;
        TRUEFRENCH|VFF)
            add_term "term_bf31bb0a956b133988c2514f62eb1535"  # VFF
            ;;
        FRENCH)
            add_term "term_bf918c3858a7dfe3b44ca70232f50272"  # French
            ;;
        VOSTFR)
            add_term "term_c87b5416341e6516baac12aa01fc5bc9"  # English (VO)
            add_term "term_5557a0dc2dff9923f8665c96246e2964"  # VOSTFR marker
            ;;
        VOF)
            add_term "term_bf918c3858a7dfe3b44ca70232f50272"  # French
            ;;
    esac

    # --- Sous-titres ---
    if [ -n "$SUBTITLES" ]; then
        echo "$SUBTITLES" | grep -qi 'fre\|fra\|fr\b' && add_term "term_9ef8bba2b9cd0d6c167f97b64c216d91"
        echo "$SUBTITLES" | grep -qi 'eng\|en\b'       && add_term "term_c0468b06760040c3a9a0674cd7eb224f"
    fi

    # --- Langues parlées (champ séparé) ---
    case "$LANG_TAG" in
        MULTi*)
            add_term "term_9cf21ecaa17940f8ea4f3b2d44627876"  # Français
            add_term "term_de9f4583ec916d7778e08783574796a5"  # Anglais
            ;;
        FRENCH|TRUEFRENCH|VFF|VOF)
            add_term "term_9cf21ecaa17940f8ea4f3b2d44627876"  # Français
            ;;
        VOSTFR)
            add_term "term_de9f4583ec916d7778e08783574796a5"  # Anglais (VO)
            ;;
    esac

    # --- Extension ---
    FILE_EXT=$(echo "$FILENAME" | grep -oE '\.[^.]+$' | tr '[:upper:]' '[:lower:]')
    case "$FILE_EXT" in
        .mkv) add_term "term_513ee8e7d062c6868b092c9a4267da8a" ;;
        .mp4) add_term "term_069f4f60531ce23f9f2bfe4ce834d660" ;;
        .avi) add_term "term_79db12fca0a1e537f6185f7aee22b8d7" ;;
    esac

    log "  TermIds : ${TERM_IDS:-<aucun>}"


    # Construire les arguments -F termIds[] pour curl
    TERM_CURL_ARGS=""
    if [ -n "$TERM_IDS" ]; then
        OLD_IFS="$IFS"; IFS=','
        for TID in $TERM_IDS; do
            [ -n "$TID" ] && TERM_CURL_ARGS="$TERM_CURL_ARGS -F termIds[]=$TID"
        done
        IFS="$OLD_IFS"
    fi

    # ── Vérification seed : fichier physique accessible par qBittorrent ─────────
    log "  Vérification seed qBittorrent..."
    SEED_OK=0

    # Chemin vu par qBittorrent (sans le préfixe NAS)
    QB_FILE_PATH=$(echo "$NAS_FILE_PATH" | sed "s|^${NAS_PATH_PREFIX}||")

    # Vérifier via l'API qBittorrent si le fichier est accessible
    QB_COOKIE_PRE="${WORK_DIR}/qb_pre_cookie.txt"
    QB_LOGIN_PRE=$(curl -sf --max-time 10 \
        -c "$QB_COOKIE_PRE" -X POST \
        "${QB_URL}/api/v2/auth/login" \
        -d "username=${QB_USER}&password=${QB_PASS}" 2>/dev/null)

    if echo "$QB_LOGIN_PRE" | grep -qi 'Ok'; then
        # Vérifier si le fichier existe déjà dans un torrent qBittorrent en seed
        _QB_ALL=$(curl -sf --max-time 10 \
            -b "$QB_COOKIE_PRE" \
            "${QB_URL}/api/v2/torrents/info" 2>/dev/null)
        _ALREADY_SEEDING=$(echo "$_QB_ALL" | python -c "
import json,sys
data=json.loads(sys.stdin.read())
fname='$(echo "$FILENAME" | sed "s/'/'\''/g")'
for t in data:
    n = t.get('name','')
    state = t.get('state','')
    if (n == fname or n == fname.rsplit('.',1)[0]) and any(s in state for s in ['UP','seeding','uploading']):
        print('already_seeding')
        break
" 2>/dev/null)

        if [ "$_ALREADY_SEEDING" = "already_seeding" ]; then
            log "  ✓ Fichier déjà en seed dans qBittorrent"
            SEED_OK=1
        else
            # Vérifier simplement que le fichier physique est accessible
            QB_CHECK=$(curl -sf --max-time 10 \
                -b "$QB_COOKIE_PRE" \
                "${QB_URL}/api/v2/app/version" 2>/dev/null)
            if [ -n "$QB_CHECK" ] && [ -f "$NAS_FILE_PATH" ]; then
                log "  ✓ Fichier accessible — seed possible après upload"
                SEED_OK=1
            else
                log "  ✗ Fichier inaccessible : $NAS_FILE_PATH"
            fi
        fi
    else
        log "  ✗ Connexion qBittorrent échouée"
    fi

    if [ "$SEED_OK" -eq 0 ]; then
        log "  ✗ ERREUR: La cargaison n'est pas scellée !"
        ERRORS=$((ERRORS+1))
        echo "ERREUR|$TITLE ($YEAR)|La cargaison n'est pas scellée !" >> "$RESULTS_FILE"
        continue
    fi

    # ── Upload sur La Cale via /api/internal/torrents/upload (API REST Next.js) ───────
    log "  Upload sur La Cale via API REST /api/internal/torrents/upload..."

    # Pas de CSRF token (app Next.js full REST, sessions via cookies httpOnly)
    # isAnonymous: "false" ou "true" (string)
    # IMPORTANT: les champs multilignes (nfoText, description) doivent être passés
    # via fichiers temporaires avec la syntaxe curl -F "champ=<fichier"
    # (évite la corruption des sauts de ligne quand bash expand la variable)
    NFO_TEXT_FILE="${WORK_DIR}/nfotext_field.txt"
    DESCRIPTION_FILE="${WORK_DIR}/description_field.txt"
    printf '%s' "" > "$NFO_TEXT_FILE"
    printf '%s' "" > "$DESCRIPTION_FILE"
    [ -f "$NFO_PATH" ] && cat "$NFO_PATH" > "$NFO_TEXT_FILE"
    generate_bbcode \
        "$TITLE" "$YEAR" "$OVERVIEW" "$COVER_URL" \
        "$QUALITY_NAME" "$VIDEO_CODEC" "$AUDIO_CODEC" "$AUDIO_LANGS" \
        "$FILE_SIZE" "$RATING" "$GENRES" "$CAST_JSON" \
        "$SUBTITLES" "$DYN_RANGE" "$DYN_TYPE" \
        > "$DESCRIPTION_FILE"

    CURL_DEBUG="${WORK_DIR}/curl_upload_debug.txt"

    UPLOAD_RESPONSE=$(curl -si --max-time 120 \
        --trace-ascii "$CURL_DEBUG" \
        -A "$BROWSER_UA" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H "Accept: application/json" \
        -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8" \
        -H "Referer: ${LACALE_URL}/upload" \
        -H "Origin: ${LACALE_URL}" \
        --compressed \
        -X POST \
        -F "title=${RELEASE_NAME}" \
        -F "categoryId=${CATEGORY_ID}" \
        -F "isAnonymous=false" \
        -F "file=@${TORRENT_PATH};type=application/x-bittorrent" \
        -F "nfoText=<${NFO_TEXT_FILE}" \
        -F "nfoFile=@${NFO_PATH};type=text/plain" \
        -F "description=<${DESCRIPTION_FILE}" \
        ${TMDB_ID:+-F "tmdbId=${TMDB_ID}" -F "tmdbType=MOVIE"} \
        ${TERM_CURL_ARGS} \
        "${LACALE_URL}/api/internal/torrents/upload" 2>/dev/null)

    HTTP_UPLOAD=$(echo "$UPLOAD_RESPONSE" | grep -oE '^HTTP/[0-9.]+ [0-9]+' | tail -1 | grep -oE '[0-9]+$')
    # Séparer headers et body
    UPLOAD_HEADERS=$(echo "$UPLOAD_RESPONSE" | sed -n '1,/^\r\{0,1\}$/p')
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE" | sed -n '/^\r\{0,1\}$/,$ p' | tail -n +2)
    log "  HTTP upload: ${HTTP_UPLOAD:-?}"
    log "  Headers réponse: $(echo "$UPLOAD_HEADERS" | grep -iE 'content-type|x-|cf-' | tr '\n' ' ')"
    # Log du body complet pour diagnostic (limité à 800 chars)
    log "  Body upload: $(echo "$UPLOAD_BODY" | head -c 800)"
    # Copier le debug curl dans les logs permanents
    [ -f "$CURL_DEBUG" ] && cp "$CURL_DEBUG" "${LOGS_DIR}/curl_upload_debug_${LOG_DATE}.txt" && \
        log "  Debug curl: ${LOGS_DIR}/curl_upload_debug_${LOG_DATE}.txt"

    # Détection du résultat JSON
    UPLOAD_OK="false"
    TORRENT_SLUG=""
    TORRENT_LINK=""

    # Parsing JSON de la réponse API REST
    if echo "$UPLOAD_BODY" | grep -q '"success"'; then
        UPLOAD_OK=$(echo "$UPLOAD_BODY" | jq -r '.success // false' 2>/dev/null)
        TORRENT_SLUG=$(echo "$UPLOAD_BODY" | jq -r '.slug // ""' 2>/dev/null)
        TORRENT_LINK=$(echo "$UPLOAD_BODY" | jq -r '.link // ""' 2>/dev/null)
    fi

    # Fallback : HTTP 200 avec data.torrentId = succès
    if [ "$UPLOAD_OK" != "true" ] && [ "$HTTP_UPLOAD" = "200" ]; then
        if echo "$UPLOAD_BODY" | grep -q '"torrentId"\|"infoHash"\|"slug"'; then
            UPLOAD_OK="true"
            TORRENT_SLUG=$(echo "$UPLOAD_BODY" | jq -r '.slug // .data.slug // ""' 2>/dev/null)
        fi
    fi

    if [ "$UPLOAD_OK" != "true" ]; then
        ERR_MSG=$(echo "$UPLOAD_BODY" | jq -r '.message // .error // ""' 2>/dev/null)
        [ -z "$ERR_MSG" ] && ERR_MSG=$(echo "$UPLOAD_BODY" | head -c 300)
        LAST_ERROR="$ERR_MSG"
        log "  ERREUR upload (HTTP $HTTP_UPLOAD): $ERR_MSG"
        # 403 Limite de rang / pending → compter comme uploadé pour stopper la boucle
        if echo "$ERR_MSG" | grep -qi 'Limite'; then
            log "  ⚓ Limite de pending atteinte — arrêt immédiat (compté comme upload)"
            notify "upload_fail" "La Cale — Limite pending" "$ERR_MSG"
            UPLOADED=$((UPLOADED+1))
            echo "LIMIT|$TITLE ($YEAR)|$ERR_MSG" >> "$RESULTS_FILE"
            break
        fi
        # Aide diagnostic spécifique au groupe "quais"
        if echo "$ERR_MSG" | grep -qi 'quai'; then
            log "  ╔══ DIAGNOSTIC QUAIS ══════════════════════════════════════════════╗"
            log "  ║ Le site exige un termId du groupe obligatoire 'quais'.          ║"
            log "  ║ Les IDs découverts au démarrage : WEB=$QUAI_WEB"
            log "  ║ Pour trouver les bons IDs :                                    ║"
            log "  ║  1. Connectez-vous sur la-cale.space                           ║"
            log "  ║  2. Allez sur /upload, ouvrez DevTools → Network               ║"
            log "  ║  3. Soumettez un upload manuellement                           ║"
            log "  ║  4. Cherchez la requête POST /api/internal/torrents/upload      ║"
            log "  ║  5. Dans le payload, notez les termIds[] du groupe 'quais'     ║"
            log "  ║  6. Mettez à jour les variables QUAI_* hardcodées              ║"
            log "  ╚═══════════════════════════════════════════════════════════════╝"
        fi
        ERRORS=$((ERRORS+1))
        echo "ERREUR|$TITLE ($YEAR)|Upload: $ERR_MSG" >> "$RESULTS_FILE"
        continue
    fi

    log "  ✓ Upload OK"
    [ -n "$TORRENT_SLUG" ] && log "  ✓ Slug : $TORRENT_SLUG"
    [ -n "$TORRENT_LINK" ] && log "  ✓ Lien : $TORRENT_LINK"

    # ── Ajout dans qBittorrent (seed) ─────────────────────────────────────
    log "  Ajout qBittorrent (seed mode)..."
    NAS_SAVE_DIR=$(dirname "$NAS_FILE_PATH" | sed "s|^${NAS_PATH_PREFIX}||" | python -c "import sys,unicodedata; print(unicodedata.normalize('NFC', sys.stdin.read().strip()))")
    QB_COOKIE="${WORK_DIR}/qb_cookie.txt"

    QB_LOGIN=$(curl -sf --max-time 10 \
        -c "$QB_COOKIE" -X POST \
        "${QB_URL}/api/v2/auth/login" \
        -d "username=${QB_USER}&password=${QB_PASS}" 2>/dev/null)

    QB_OK=0
    QB_HASH=""
    if echo "$QB_LOGIN" | grep -qi 'Ok'; then
        QB_ADD=$(curl -sf --max-time 30 \
            -b "$QB_COOKIE" -X POST \
            "${QB_URL}/api/v2/torrents/add" \
            -F "torrents=@${TORRENT_PATH};type=application/x-bittorrent" \
            -F "savepath=${NAS_SAVE_DIR}" \
            -F "skip_checking=true" \
            -F "paused=false" \
            2>/dev/null)
        if echo "$QB_ADD" | grep -qi 'Ok'; then
            QB_OK=1
            # Récupérer le hash du torrent ajouté pour vérification
            log "  ~ Chargement de la cargaison en cours, attendez 30 secondes ~"
            sleep 30
            QB_HASH=$(curl -sf --max-time 10 \
                -b "$QB_COOKIE" \
                "${QB_URL}/api/v2/torrents/info" 2>/dev/null | python -c "
import json,sys
data=json.loads(sys.stdin.read())
fname='$(echo "$FILENAME" | sed "s/'/'\''/g")'
for t in data:
    n = t.get('name','')
    if n == fname or n == fname.rsplit('.',1)[0]:
        print(t.get('hash',''))
        break
" 2>/dev/null)
            if [ -n "$QB_HASH" ]; then
                QB_STATE=$(curl -sf --max-time 10 \
                    -b "$QB_COOKIE" \
                    "${QB_URL}/api/v2/torrents/info?hashes=${QB_HASH}" 2>/dev/null | python -c "
import json,sys
data=json.loads(sys.stdin.read())
print(data[0].get('state','') if data else '')
" 2>/dev/null)
                log "  État qBittorrent : ${QB_STATE:-inconnu}"

                # Si en cours de vérification → attendre 30s et re-vérifier
                if echo "$QB_STATE" | grep -qiE 'checking|metaDL'; then
                    log "  ~ Vérification en cours, attendez 30 secondes ~"
                    sleep 30
                    QB_STATE=$(curl -sf --max-time 10 \
                        -b "$QB_COOKIE" \
                        "${QB_URL}/api/v2/torrents/info?hashes=${QB_HASH}" 2>/dev/null | python -c "
import json,sys
data=json.loads(sys.stdin.read())
print(data[0].get('state','') if data else '')
" 2>/dev/null)
                    log "  État après attente : ${QB_STATE:-inconnu}"
                fi

                # Si missingFiles → forcer recheck
                if echo "$QB_STATE" | grep -qi 'missingFiles\|error'; then
                    log "  WARN: fichier non trouvé par qBittorrent — recheck forcé..."
                    curl -sf --max-time 10 -b "$QB_COOKIE" -X POST \
                        -d "hashes=${QB_HASH}" \
                        "${QB_URL}/api/v2/torrents/recheck" >/dev/null 2>&1
                    sleep 30
                    QB_STATE=$(curl -sf --max-time 10 \
                        -b "$QB_COOKIE" \
                        "${QB_URL}/api/v2/torrents/info?hashes=${QB_HASH}" 2>/dev/null | python -c "
import json,sys
data=json.loads(sys.stdin.read())
print(data[0].get('state','') if data else '')
" 2>/dev/null)
                    log "  État après recheck : ${QB_STATE:-inconnu}"
                fi

                log "  État final qBittorrent : ${QB_STATE:-inconnu}"
            fi
        fi
    fi

    if [ "$QB_OK" -eq 1 ]; then
        log "  ✓ Torrent ajouté dans qBittorrent (état: ${QB_STATE:-OK})"
    else
        log "  WARN: ajout qBittorrent échoué (upload La Cale OK)"
        log "  qBittorrent login: $QB_LOGIN"
    fi

    # ── Historique ────────────────────────────────────────────────────────
    echo "$RELEASE_NAME" >> "$HISTORIQUE_FILE"
    UPLOADED=$((UPLOADED+1))
    QB_STATUS="OK"; [ "$QB_OK" -eq 0 ] && QB_STATUS="ERREUR"
    echo "OK|$TITLE ($YEAR)|$RELEASE_NAME|${TORRENT_LINK}|qBittorrent=$QB_STATUS|NFO=$NFO_SOURCE" >> "$RESULTS_FILE"
    # Mise à jour cache : ce film est maintenant sur La Cale
    _cache_set "${TMDB_ID:-title:${TITLE}}" "1"
    # Notification upload OK
    notify "upload_ok" "Upload OK — $TITLE ($YEAR)" "$RELEASE_NAME${TORRENT_LINK:+ — $TORRENT_LINK}"

done < "${WORK_DIR}/movies_with_files.jsonl"

# Pass 2 : releases alternatives si quota non atteint
if [ "$UPLOADED" -lt "$MAX_MOVIES" ]; then
    PASS_MODE="all"
    log ""
    log_section "Pass 2 — releases alternatives (quota restant : $((MAX_MOVIES - UPLOADED)))"

    while IFS= read -r MOVIE_JSON; do

        [ "$UPLOADED" -ge "$MAX_MOVIES" ] && break

        # ── Extraction des champs ────────────────────────────────────────────
        MOVIE_ID=$(echo "$MOVIE_JSON"       | jq -r '.id')
        TITLE=$(echo "$MOVIE_JSON"          | jq -r '.title')
        YEAR=$(echo "$MOVIE_JSON"           | jq -r '.year')
        TMDB_ID=$(echo "$MOVIE_JSON"        | jq -r '.tmdbId // ""')
        OVERVIEW=$(echo "$MOVIE_JSON"       | jq -r '.overview // ""')
        RADARR_PATH=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.path // ""')
        RELEASE_GROUP=$(echo "$MOVIE_JSON"  | jq -r '.movieFile.releaseGroup // ""')
        QUALITY_NAME=$(echo "$MOVIE_JSON"   | jq -r '.movieFile.quality.quality.name // ""')
        VIDEO_CODEC=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.videoCodec // ""')
        AUDIO_LANGS=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.audioLanguages // ""')
        DYN_RANGE=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.videoDynamicRange // ""')
        DYN_TYPE=$(echo "$MOVIE_JSON"       | jq -r '.movieFile.mediaInfo.videoDynamicRangeType // ""')
        FILE_SIZE=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.size // 0')
        RUN_TIME=$(echo "$MOVIE_JSON"       | jq -r '.movieFile.mediaInfo.runTime // ""')
        AUDIO_CODEC=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.audioCodec // ""')
        AUDIO_CH=$(echo "$MOVIE_JSON"       | jq -r '.movieFile.mediaInfo.audioChannels // ""')
        SUBTITLES=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.subtitles // ""')
        VIDEO_BIT=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.videoBitrate // ""')
        VIDEO_FPS=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.videoFps // ""')
        VIDEO_DEPTH=$(echo "$MOVIE_JSON"    | jq -r '.movieFile.mediaInfo.videoBitDepth // ""')
        AUDIO_BIT=$(echo "$MOVIE_JSON"      | jq -r '.movieFile.mediaInfo.audioBitrate // ""')
        COVER_URL=$(echo "$MOVIE_JSON"      | jq -r '.images[]? | select(.coverType=="poster") | .remoteUrl // ""' | head -1)
        RATING=$(echo "$MOVIE_JSON"         | jq -r '.ratings.tmdb.value // .ratings.value // 0')
        GENRES=$(echo "$MOVIE_JSON"         | jq -r '[.genres[]? ] | join(", ")' 2>/dev/null || echo "")

        log ""
        log "────────────────────────────────────────────────────────────"
        log "Film          : $TITLE ($YEAR)  [Radarr ID: $MOVIE_ID]"

        FILENAME=$(basename "$RADARR_PATH")
        FNAME_UP=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]')

        log "Fichier       : $FILENAME"
        log "ReleaseGroup  : ${RELEASE_GROUP:-<vide>}"
        log "Qualite       : $QUALITY_NAME"

        [ -z "$RADARR_PATH" ] && {
            log "  SKIP: chemin fichier vide"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Chemin vide" >> "$RESULTS_FILE"
            continue
        }

        # ── Chemin réel sur le NAS ───────────────────────────────────────────
        NAS_FILE_PATH=$(resolve_nas_path "$RADARR_PATH")
        log "Chemin NAS    : ${NAS_FILE_PATH:-INTROUVABLE}"

        if [ -z "$NAS_FILE_PATH" ] || [ ! -f "$NAS_FILE_PATH" ]; then
            log "  SKIP: fichier introuvable sur le NAS (Radarr desynchronise ?)"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Fichier manquant" >> "$RESULTS_FILE"
            continue
        fi

        # ── Filtre qualité minimale ───────────────────────────────────────────
        if ! meets_min_quality "$QUALITY_NAME"; then
            log "  SKIP: qualité insuffisante ($QUALITY_NAME < ${MIN_QUALITY})"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Qualité insuffisante ($QUALITY_NAME)" >> "$RESULTS_FILE"
            continue
        fi

        # ── Fichier d'exclusion ──────────────────────────────────────────────
        if is_excluded "$TMDB_ID" "$TITLE"; then
            log "  SKIP: exclu (EXCLUDE_FILE)"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Exclusion explicite" >> "$RESULTS_FILE"
            continue
        fi

        # ── Release group ────────────────────────────────────────────────────
        if [ -z "$RELEASE_GROUP" ] || [ "$RELEASE_GROUP" = "null" ]; then
            STEM=$(echo "$FILENAME" | sed 's/\.[^.]*$//')
            RELEASE_GROUP=$(echo "$STEM" | grep -oE '\-[A-Za-z0-9]+$' | tr -d '-')
            if [ -n "$RELEASE_GROUP" ]; then
                log "  WARN: releaseGroup vide → extrait du nom de fichier: $RELEASE_GROUP"
            else
                log "  WARN: releaseGroup inconnu → release name sans groupe"
            fi
        fi

        # ── Construction du nom de release ───────────────────────────────────
        # Si le fichier est déjà au format scene (points, pas d'espaces ni parenthèses)
        # → utiliser directement le stem du fichier comme RELEASE_NAME
        FILE_STEM=$(echo "$FILENAME" | sed 's/\.[^.]*$//')
        if ! echo "$FILE_STEM" | grep -q '[[:space:]()\[]'; then
            RELEASE_NAME="$FILE_STEM"
            log "Release name  : $RELEASE_NAME  (depuis nom fichier)"
        else
            # Fallback : reconstruction depuis métadonnées Radarr
            # Nettoyage du titre : accents, apostrophes, cédilles, ponctuation
            log "  WARN: nom fichier non-scene → reconstruction depuis métadonnées"
            TITLE_CLEAN=$(echo "$TITLE" \
                | sed "y/àâäåéèêëïîìôöòùûüçñÀÂÄÅÉÈÊËÏÎÌÔÖÒÙÛÜÇÑ/aaaaeeeeiiiooouuucnAAAAEEEEIIIOOOUUUCN/" \
                | sed "s/[''ʼ]//g" \
                | sed 's/://g' \
                | sed 's/["!?,;{}()\[\]]//g' \
                | sed 's/  */ /g' \
                | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' \
                | sed 's/ /./g' \
                | sed 's/\.\././g')

            # ── Info (REPACK, PROPER) ─────────────────────────────────────────
            INFO_TAG=""
            case "$FNAME_UP" in
                *REPACK2*) INFO_TAG="REPACK2" ;;
                *REPACK*)  INFO_TAG="REPACK" ;;
                *PROPER2*) INFO_TAG="PROPER2" ;;
                *PROPER*)  INFO_TAG="PROPER" ;;
                *RERIP*)   INFO_TAG="RERip" ;;
            esac

            # ── Édition (DC, EXTENDED, UNRATED, REMASTERED, CRITERION…) ──────
            EDITION_TAG=""
            _ed=""
            echo "$FNAME_UP" | grep -qE '\.DC\.|DIRECTORS.CUT' && _ed="${_ed}.DC"
            echo "$FNAME_UP" | grep -q 'EXTENDED'              && _ed="${_ed}.EXTENDED"
            echo "$FNAME_UP" | grep -q 'UNRATED'               && _ed="${_ed}.UNRATED"
            echo "$FNAME_UP" | grep -qE 'REMASTER'             && _ed="${_ed}.REMASTERED"
            echo "$FNAME_UP" | grep -q 'RESTORED'              && _ed="${_ed}.Restored"
            echo "$FNAME_UP" | grep -q 'CRITERION'             && _ed="${_ed}.CRiTERION"
            echo "$FNAME_UP" | grep -q 'FINAL.CUT'             && _ed="${_ed}.FiNAL.CUT"
            EDITION_TAG=$(echo "$_ed" | sed 's/^\.//')

            # ── IMAX ─────────────────────────────────────────────────────────
            IMAX_TAG=""
            echo "$FNAME_UP" | grep -q 'IMAX' && IMAX_TAG="iMAX"

            # ── Langue ───────────────────────────────────────────────────────
            if echo "$FNAME_UP" | grep -q 'MULTI'; then
                if   echo "$FNAME_UP" | grep -qE 'TRUEFRENCH|VFF'; then LANG_TAG="MULTi.VFF"
                elif echo "$FNAME_UP" | grep -q 'VFQ';             then LANG_TAG="MULTi.VFQ"
                elif echo "$FNAME_UP" | grep -q 'VF2';             then LANG_TAG="MULTi.VF2"
                elif echo "$FNAME_UP" | grep -q 'VFI';             then LANG_TAG="MULTi.VFi"
                else                                                     LANG_TAG="MULTi"
                fi
            elif echo "$FNAME_UP" | grep -qE 'TRUEFRENCH|VFF'; then LANG_TAG="TRUEFRENCH"
            elif echo "$FNAME_UP" | grep -q 'VOSTFR';          then LANG_TAG="VOSTFR"
            elif echo "$FNAME_UP" | grep -q 'VOF';             then LANG_TAG="VOF"
            elif echo "$FNAME_UP" | grep -qE 'FRENCH';         then LANG_TAG="FRENCH"
            elif echo "$FNAME_UP" | grep -q 'DUAL';            then LANG_TAG="DUAL"
            else
                LANG_COUNT=$(echo "$AUDIO_LANGS" | tr '/' '\n' | grep -c '[a-z]' 2>/dev/null || echo 0)
                if [ "$LANG_COUNT" -gt 1 ]; then LANG_TAG="MULTi"
                elif echo "$AUDIO_LANGS" | grep -qi 'french\|fra'; then LANG_TAG="FRENCH"
                else LANG_TAG="FRENCH"
                fi
            fi

            # Descripteur langue additionnel (AD = audiodescription)
            LANG_INFO=""
            echo "$FNAME_UP" | grep -qE '\.AD\.|\-AD\.' && LANG_INFO="AD"

            # ── HDR / DV ─────────────────────────────────────────────────────
            HDR_TAG=""
            if echo "$FNAME_UP$DYN_RANGE$DYN_TYPE" | grep -qi 'HDR10+\|HDR10PLUS'; then HDR_TAG="HDR10+"
            elif echo "$FNAME_UP$DYN_RANGE$DYN_TYPE" | grep -qi 'HDR'; then HDR_TAG="HDR"
            fi
            if echo "$FNAME_UP$DYN_TYPE" | grep -qi 'DV\|DOLBY.VISION\|DOLBYVISION'; then
                [ -n "$HDR_TAG" ] && HDR_TAG="${HDR_TAG}.DV" || HDR_TAG="DV"
            fi

            # ── Résolution ───────────────────────────────────────────────────
            QN_UP=$(echo "$QUALITY_NAME" | tr '[:lower:]' '[:upper:]')
            if   echo "$QN_UP$FNAME_UP" | grep -qE '2160|4K'; then RESOLUTION="2160p"
            elif echo "$QN_UP$FNAME_UP" | grep -q '1080';     then RESOLUTION="1080p"
            elif echo "$QN_UP$FNAME_UP" | grep -q '720';      then RESOLUTION="720p"
            else RESOLUTION=""
            fi

            # ── Plateforme de streaming ───────────────────────────────────────
            PLATFORM=""
            case "$FNAME_UP" in
                *\.NF\.*|*\.NETFLIX\.*) PLATFORM="NF" ;;
                *\.AMZN\.*|*\.AMAZON\.*) PLATFORM="AMZN" ;;
                *\.DSNP\.*|*\.DISNEY\.*) PLATFORM="DSNP" ;;
                *\.ATVP\.*)             PLATFORM="ATVP" ;;
                *\.HMAX\.*|*\.MAX\.*)   PLATFORM="MAX" ;;
                *\.PMTP\.*)             PLATFORM="PMTP" ;;
                *\.HULU\.*)             PLATFORM="HULU" ;;
                *\.ADN\.*)              PLATFORM="ADN" ;;
                *\.PCOK\.*)             PLATFORM="PCOK" ;;
            esac

            # ── Source ───────────────────────────────────────────────────────
            QL=$(echo "$QUALITY_NAME" | tr '[:upper:]' '[:lower:]')
            case "$FNAME_UP" in
                *COMPLETE*UHD*BLU*)       SOURCE="COMPLETE.UHD.BLURAY" ;;
                *COMPLETE*BLU*)           SOURCE="COMPLETE.BLURAY" ;;
                *BLU*REMUX*|*BD*REMUX*)   SOURCE="BluRay.REMUX" ;;
                *DVD*REMUX*)              SOURCE="DVD.REMUX" ;;
                *REMUX*)                  SOURCE="REMUX" ;;
                *4KLIGHT*)                SOURCE="4KLight" ;;
                *HDLIGHT*)                SOURCE="HDLight" ;;
                *\.MHD\.*)                SOURCE="mHD" ;;
                *BLURAY*|*BLU-RAY*|*BDRIP*) SOURCE="BluRay" ;;
                *WEB-DL*|*WEBDL*)         SOURCE="WEB-DL" ;;
                *WEBRIP*)                 SOURCE="WEBRip" ;;
                *DVDRIP*)                 SOURCE="DVDRip" ;;
                *HDTV*)                   SOURCE="HDTV" ;;
                *) case "$QL" in
                    *webdl*|*web-dl*) SOURCE="WEB-DL" ;;
                    *webrip*)         SOURCE="WEBRip" ;;
                    *bluray*)         SOURCE="BluRay" ;;
                    *)                SOURCE="WEB" ;;
                   esac ;;
            esac

            # ── Codec vidéo ──────────────────────────────────────────────────
            if   echo "$FNAME_UP$VIDEO_CODEC" | grep -qiE 'X265|H265|HEVC'; then CODEC="x265"
            elif echo "$FNAME_UP$VIDEO_CODEC" | grep -qiE 'X264|H264|AVC';  then CODEC="x264"
            elif echo "$FNAME_UP$VIDEO_CODEC" | grep -qi  'AV1';            then CODEC="AV1"
            elif echo "$FNAME_UP$VIDEO_CODEC" | grep -qi  'VC.1\|VC-1';    then CODEC="VC-1"
            elif echo "$FNAME_UP"             | grep -qi  'XVID';           then CODEC="XviD"
            elif echo "$FNAME_UP"             | grep -qiE 'MPEG2|MPEG';     then CODEC="MPEG"
            else CODEC="x264"
            fi

            # ── Codec audio ──────────────────────────────────────────────────
            AUDIO_TAG=""
            AC_UP=$(echo "$AUDIO_CODEC" | tr '[:lower:]' '[:upper:]')
            case "$AC_UP" in
                *TRUEHD*)              AUDIO_TAG="TrueHD" ;;
                *EAC3*|*E-AC3*|*DDP*) AUDIO_TAG="EAC3" ;;
                *AC3*|*DD*)            AUDIO_TAG="AC3" ;;
                *DTS:X*|*DTSX*)        AUDIO_TAG="DTS-X" ;;
                *DTS-HD*MA*|*DTSHDMA*) AUDIO_TAG="DTS-HD.MA" ;;
                *DTS-HD*|*DTSHD*)      AUDIO_TAG="DTS-HD" ;;
                *DTS*)                 AUDIO_TAG="DTS" ;;
                *AAC*)                 AUDIO_TAG="AAC" ;;
                *FLAC*)                AUDIO_TAG="FLAC" ;;
                *OPUS*)                AUDIO_TAG="OPUS" ;;
            esac

            # Canaux audio (5.1, 7.1…)
            AUDIO_CH_TAG=""
            if   echo "$FNAME_UP" | grep -qE '7\.1'; then AUDIO_CH_TAG="7.1"
            elif echo "$FNAME_UP" | grep -qE '5\.1'; then AUDIO_CH_TAG="5.1"
            elif echo "$FNAME_UP" | grep -qE '2\.0'; then AUDIO_CH_TAG="2.0"
            fi

            # Atmos
            AUDIO_SPEC=""
            echo "$FNAME_UP" | grep -q 'ATMOS' && AUDIO_SPEC="Atmos"

            # ── Assemblage selon règles La Cale ──────────────────────────────
            # Ordre : Titre.Année.[Info].[Edition].[IMAX].Langue.[LangInfo].[HDR].[Résolution].[Plateforme].Source.[Audio].[Canaux].[Spec].Codec-Groupe
            RELEASE_NAME="${TITLE_CLEAN}.${YEAR}"
            [ -n "$INFO_TAG" ]    && RELEASE_NAME="${RELEASE_NAME}.${INFO_TAG}"
            [ -n "$EDITION_TAG" ] && RELEASE_NAME="${RELEASE_NAME}.${EDITION_TAG}"
            [ -n "$IMAX_TAG" ]    && RELEASE_NAME="${RELEASE_NAME}.${IMAX_TAG}"
            RELEASE_NAME="${RELEASE_NAME}.${LANG_TAG}"
            [ -n "$LANG_INFO" ]   && RELEASE_NAME="${RELEASE_NAME}.${LANG_INFO}"
            [ -n "$HDR_TAG" ]     && RELEASE_NAME="${RELEASE_NAME}.${HDR_TAG}"
            [ -n "$RESOLUTION" ]  && RELEASE_NAME="${RELEASE_NAME}.${RESOLUTION}"
            [ -n "$PLATFORM" ]    && RELEASE_NAME="${RELEASE_NAME}.${PLATFORM}"
            RELEASE_NAME="${RELEASE_NAME}.${SOURCE}"
            [ -n "$AUDIO_TAG" ]   && RELEASE_NAME="${RELEASE_NAME}.${AUDIO_TAG}"
            [ -n "$AUDIO_CH_TAG" ] && RELEASE_NAME="${RELEASE_NAME}.${AUDIO_CH_TAG}"
            [ -n "$AUDIO_SPEC" ]  && RELEASE_NAME="${RELEASE_NAME}.${AUDIO_SPEC}"
            if [ -n "$RELEASE_GROUP" ] && [ "$RELEASE_GROUP" != "null" ]; then
                RELEASE_NAME="${RELEASE_NAME}.${CODEC}-${RELEASE_GROUP}"
            else
                RELEASE_NAME="${RELEASE_NAME}.${CODEC}-NOGRP"
            fi
            log "Release name  : $RELEASE_NAME  (reconstruit)"
        fi

        # FNAME_UP recalculé depuis RELEASE_NAME final pour les termIds
        FNAME_UP=$(echo "$RELEASE_NAME" | tr '[:lower:]' '[:upper:]')

        # ── Vérification historique local ────────────────────────────────────
        if [ -f "$HISTORIQUE_FILE" ] && grep -qiF "$RELEASE_NAME" "$HISTORIQUE_FILE"; then
            log "  SKIP: déjà dans l'historique local"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Historique local" >> "$RESULTS_FILE"
            continue
        fi

        # ── Vérification doublon sur La Cale (avec cache TTL) ────────────────
        log "  Vérification doublon sur La Cale (TMDb:${TMDB_ID:-?})..."
        RELEASE_COUNT=$(count_releases_lacale "$TMDB_ID" "$TITLE")
        log "  Trouvé $RELEASE_COUNT release(s) sur La Cale"

        if [ "$PASS_MODE" = "unique" ] && [ "$RELEASE_COUNT" -gt 0 ]; then
            log "  SKIP: déjà sur La Cale ($RELEASE_COUNT release(s)) — pass 1 (unique)"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Déjà sur La Cale (pass 1)" >> "$RESULTS_FILE"
            continue
        fi

        log "  → Absent sur La Cale (pass ${PASS_MODE:-1}), on continue."

        # ── Récupération casting TMDB (via API La Cale) ───────────────────────
        CAST_JSON="[]"
        if [ -n "$TMDB_ID" ] && [ "$TMDB_ID" != "null" ] && [ "$TMDB_ID" != "0" ]; then
            TMDB_DETAIL=$(curl -sf --max-time 15 \
                -A "$BROWSER_UA" \
                -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                -H "Accept: application/json" \
                --compressed \
                "${LACALE_URL}/api/internal/tmdb/details?id=${TMDB_ID}&type=movie" 2>/dev/null)
            if [ -n "$TMDB_DETAIL" ]; then
                # Extraire cast: array [{name, character}]
                CAST_JSON=$(printf '%s' "$TMDB_DETAIL" | jq '[.cast[]? | {name:.name, character:.character}] // []' 2>/dev/null || echo "[]")
                # Récupérer rating/genres TMDB si meilleurs que ceux de Radarr
                TMDB_RATING=$(printf '%s' "$TMDB_DETAIL" | jq -r '.rating // 0' 2>/dev/null)
                TMDB_GENRES=$(printf '%s' "$TMDB_DETAIL" | jq -r '.genres // ""' 2>/dev/null)
                [ -n "$TMDB_RATING" ] && [ "$TMDB_RATING" != "0" ] && [ "$TMDB_RATING" != "null" ] && RATING="$TMDB_RATING"
                [ -n "$TMDB_GENRES" ] && [ "$TMDB_GENRES" != "null" ] && GENRES="$TMDB_GENRES"
            fi
        fi

        # ── Rescan Radarr pour synchroniser relativePath avec le fichier réel ──
        RESCAN_RESP=$(curl -sf --max-time 30 \
            -X POST \
            -H "Content-Type: application/json" \
            "${RADARR_URL}/api/v3/command?apikey=${RADARR_API_KEY}" \
            -d "{\"name\":\"RescanMovie\",\"movieId\":${MOVIE_ID}}" 2>/dev/null)
        if [ -n "$RESCAN_RESP" ]; then
            sleep 5
            FRESH_JSON=$(curl -sf --max-time 15 \
                "${RADARR_URL}/api/v3/movie/${MOVIE_ID}?apikey=${RADARR_API_KEY}" 2>/dev/null)
            if [ -n "$FRESH_JSON" ]; then
                RADARR_PATH=$(echo "$FRESH_JSON"  | jq -r '.movieFile.path // ""')
                RELEASE_GROUP=$(echo "$FRESH_JSON"| jq -r '.movieFile.releaseGroup // ""')
                QUALITY_NAME=$(echo "$FRESH_JSON" | jq -r '.movieFile.quality.quality.name // ""')
                VIDEO_CODEC=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.videoCodec // ""')
                AUDIO_LANGS=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.audioLanguages // ""')
                DYN_RANGE=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.videoDynamicRange // ""')
                DYN_TYPE=$(echo "$FRESH_JSON"     | jq -r '.movieFile.mediaInfo.videoDynamicRangeType // ""')
                FILE_SIZE=$(echo "$FRESH_JSON"    | jq -r '.movieFile.size // 0')
                RUN_TIME=$(echo "$FRESH_JSON"     | jq -r '.movieFile.mediaInfo.runTime // ""')
                AUDIO_CODEC=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.audioCodec // ""')
                AUDIO_CH=$(echo "$FRESH_JSON"     | jq -r '.movieFile.mediaInfo.audioChannels // ""')
                SUBTITLES=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.subtitles // ""')
                VIDEO_BIT=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.videoBitrate // ""')
                VIDEO_FPS=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.videoFps // ""')
                VIDEO_DEPTH=$(echo "$FRESH_JSON"  | jq -r '.movieFile.mediaInfo.videoBitDepth // ""')
                AUDIO_BIT=$(echo "$FRESH_JSON"    | jq -r '.movieFile.mediaInfo.audioBitrate // ""')
                FILENAME=$(basename "$RADARR_PATH")
                FNAME_UP=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]')
                log "  ✓ Rescan Radarr OK — fichier: $FILENAME"
            fi
        else
            log "  WARN: Rescan Radarr echoue — donnees potentiellement obsoletes"
        fi

        # ── MediaInfo + Création du torrent (Docker Alpine) ──────────────────
        log "  Génération NFO (mediainfo) + création du torrent..."
        NFO_PATH="${NFO_DIR}/${RELEASE_NAME}.nfo"
        TORRENT_PATH="${TORRENTS_DIR}/${RELEASE_NAME}.torrent"

        FOLDER_NAME=$(echo "$RADARR_PATH" | sed "s|^${RADARR_PATH_PREFIX}/||" | cut -d'/' -f1)
        log "  Dossier film  : $FOLDER_NAME"

        TORRENT_OK=0
        docker run --rm \
            -v "${NAS_PATH_PREFIX}:/mnt/zfs:ro" \
            -v "${WORK_DIR}:/work:rw" \
            -e "IN_FOLDER=${FOLDER_NAME}" \
            -e "IN_FILE=$(echo "$RADARR_PATH" | sed "s|^${RADARR_PATH_PREFIX}/||" | cut -d'/' -f2-)" \
            -e "REL_NAME=${RELEASE_NAME}" \
            -e "TRACKER=${TRACKER_URL}" \
            "$DOCKER_PYTHON" \
            sh -c '
                apk add --no-cache python3 mediainfo -q 2>/dev/null
                FULL_PATH=$(ls -d /mnt/zfs/*/Films/"$IN_FOLDER"/"$IN_FILE" 2>/dev/null | head -1)
                if [ -z "$FULL_PATH" ] || [ ! -f "$FULL_PATH" ]; then
                    echo "ERREUR: fichier non trouvé dans Docker: $IN_FOLDER/$IN_FILE" >&2
                    exit 1
                fi
                echo "  Chemin Docker : $FULL_PATH"
                mediainfo "$FULL_PATH" > "/work/$REL_NAME.nfo" 2>/dev/null || true
                python3 /work/make_torrent.py \
                    "$FULL_PATH" \
                    "$REL_NAME" \
                    "$TRACKER" \
                    "/work/$REL_NAME.torrent"
            ' && TORRENT_OK=1

        # NFO : priorité mediainfo, fallback Radarr
        NFO_SOURCE="mediainfo (Alpine)"
        if [ -f "${WORK_DIR}/${RELEASE_NAME}.nfo" ] && [ -s "${WORK_DIR}/${RELEASE_NAME}.nfo" ]; then
            # Nettoie le chemin Docker interne (/mnt/zfs/...) → juste le nom de fichier
            _EXT=$(echo "$FILENAME" | grep -oE '\.[^.]+$' | tr '[:upper:]' '[:lower:]')
            sed "s|Complete name[[:space:]]*:.*|Complete name                            : ${RELEASE_NAME}${_EXT}|g" \
                "${WORK_DIR}/${RELEASE_NAME}.nfo" > "$NFO_PATH"
            log "  NFO : $(wc -c < "$NFO_PATH") chars via $NFO_SOURCE"
        else
            NFO_SOURCE="Radarr mediaInfo (fallback)"
            SIZE_GIB=$(echo "$FILE_SIZE" | awk '{printf "%.2f", $1/1073741824}')
            printf 'General\nComplete name : %s\nFile size     : %s GiB\nDuration      : %s\n\nVideo\nFormat        : %s\nBit rate      : %s kb/s\nFrame rate    : %s FPS\nBit depth     : %s bits\nHDR           : %s\n\nAudio\nFormat        : %s\nBit rate      : %s kb/s\nChannel(s)    : %s channels\nLanguage(s)   : %s\n\nSubtitles     : %s\n' \
                "$FILENAME" "$SIZE_GIB" "$RUN_TIME" \
                "$VIDEO_CODEC" "$VIDEO_BIT" "$VIDEO_FPS" "$VIDEO_DEPTH" "$DYN_RANGE" \
                "$AUDIO_CODEC" "$AUDIO_BIT" "$AUDIO_CH" "$AUDIO_LANGS" \
                "$SUBTITLES" > "$NFO_PATH"
            log "  WARN: mediainfo échoué → NFO depuis données Radarr"
            log "  NFO : $(wc -c < "$NFO_PATH") chars via $NFO_SOURCE"
        fi
        log "  NFO sauvegardé : $NFO_PATH"

        if [ "$TORRENT_OK" -eq 1 ] && [ -f "${WORK_DIR}/${RELEASE_NAME}.torrent" ]; then
            cp "${WORK_DIR}/${RELEASE_NAME}.torrent" "$TORRENT_PATH"
        fi

        if [ "$TORRENT_OK" -eq 0 ] || [ ! -f "$TORRENT_PATH" ]; then
            log "  ERREUR: création du torrent échouée"
            ERRORS=$((ERRORS+1))
            echo "ERREUR|$TITLE ($YEAR)|Création torrent échouée" >> "$RESULTS_FILE"
            continue
        fi
        log "  ✓ Torrent créé : $TORRENT_PATH"

        # ── Re-vérification fraîche avant upload (invalide le cache) ─────────────
        FRESH_COUNT=$(count_releases_lacale_fresh "$TMDB_ID" "$TITLE")
        if [ "$PASS_MODE" = "unique" ] && [ "$FRESH_COUNT" -gt 0 ]; then
            log "  SKIP: apparu sur La Cale pendant le traitement ($FRESH_COUNT release(s))"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Apparu sur La Cale pendant traitement" >> "$RESULTS_FILE"
            continue
        fi

        # ── Vérification doublon par info_hash (API parse) ────────────────────────
        PARSE_RESULT=$(curl -sf --max-time 30 \
            -A "$BROWSER_UA" \
            -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
            -H "Accept: application/json" \
            -H "Referer: ${LACALE_URL}/upload" \
            -H "Origin: ${LACALE_URL}" \
            --compressed \
            -X POST \
            -F "file=@${TORRENT_PATH};type=application/x-bittorrent" \
            "${LACALE_URL}/api/internal/torrents/parse" 2>/dev/null)
        if echo "$PARSE_RESULT" | grep -qi '"duplicate"[[:space:]]*:[[:space:]]*true\|"exists"[[:space:]]*:[[:space:]]*true\|already exist\|torrentId'; then
            log "  SKIP: torrent déjà présent sur La Cale (info_hash identique)"
            echo "$RELEASE_NAME" >> "$HISTORIQUE_FILE"
            SKIPPED=$((SKIPPED+1))
            echo "SKIP|$TITLE ($YEAR)|Doublon hash détecté via /api/internal/torrents/parse" >> "$RESULTS_FILE"
            continue
        fi

        # ── Délai anti-rate-limit entre uploads ──────────────────────────────────
        [ "$UPLOADED" -gt 0 ] && [ "${UPLOAD_DELAY:-3}" -gt 0 ] && sleep "$UPLOAD_DELAY"

        # ── Mapping des termIds (Caractéristiques de la release) ─────────────────
        TERM_IDS=""

        # Helper: ajouter un term
        add_term() { TERM_IDS="${TERM_IDS:+${TERM_IDS},}$1"; }


        # --- Genres (depuis Radarr/TMDB) ---
        echo "$GENRES" | tr ',/' '\n' | while read -r G; do
            G=$(echo "$G" | sed 's/^ *//;s/ *$//')
            case "$G" in
                Action)           echo "term_561bfb1bc6aa4eb236a0096055df56d3" ;;
                Animation)        echo "term_104b4c4889059907b69469199e91e650" ;;
                Adventure|Aventure) echo "term_53318115f9881cba4ea3c5d5fbcbdd7a" ;;
                Biography|Biopic) echo "term_fc1f45b5830a6c43ac1e04c15de20fd6" ;;
                Comedy|Comédie)   echo "term_2565c6c823f8770fd7bcaaf8825676e1" ;;
                Documentary|Documentaire) echo "term_5c93004f538b8ff2d0384371e52f6926" ;;
                Drama|Drame)      echo "term_86aac9f2daee035fd7fdbec3c01ec49c" ;;
                Family|Familial)  echo "term_15736578e8038ed0adb120204921a6e3" ;;
                Fantasy|Fantastique) echo "term_2c74d8bf4a34c8b3f1f41e66aebd5ec9" ;;
                History|Historique) echo "term_6b60cdc761f4ea38e98a035868a73692" ;;
                Horror|Horreur)   echo "term_6ec3481f6e45a178a3246e09a3be844b" ;;
                Music|Musical)    echo "term_983454715ab3dbc095012bf20dc27ba7" ;;
                "Crime"|"Policier / Thriller"|Thriller|Crime) echo "term_6dbb7e22f0aae37746d710ea3e23ce03" ;;
                Romance)          echo "term_fb1342ef0b14b7384a3e450335e3fdc2" ;;
                "Science Fiction"|"Science-fiction"|Sci-Fi) echo "term_845f0e31f46f4cfdf305681732759559" ;;
                Sport|Sports)     echo "term_c6d861d65b8d6191e24d48fd18347581" ;;
                War|Guerre)       echo "term_ffcb1f78a535d21a627116bb84b9fdb3" ;;
                Western)          echo "term_6ba0e4717a668f400cd2526debb7d0fc" ;;
                Suspense)         echo "term_788f7971971cfa7d4f7ff3028b17dcda" ;;
                "TV Movie"|Téléfilm) echo "term_30d959f14ad88fc00700173a23c386d8" ;;
            esac
        done > "${WORK_DIR}/genre_terms.txt"
        while IFS= read -r T; do [ -n "$T" ] && add_term "$T"; done < "${WORK_DIR}/genre_terms.txt"

        # --- Qualité / Résolution ---
        case "$RESOLUTION" in
            2160p) add_term "term_947df6343911cdf2c9e477cf4bddfc56" ;;
            1080p) add_term "term_e7dd3707cd20c0cfccd272334eba5bbf" ;;
            720p)  add_term "term_4437c0c05981fa692427eb0d92a25a34" ;;
            *)     add_term "term_6ade2712b8348f39b892c00119915454" ;;  # SD
        esac

        # --- Codec vidéo ---
        case "$CODEC" in
            x265) add_term "term_27dc36ee2c6fad6b87d71ed27e4b8266" ;;
            x264) add_term "term_9289368e710fa0c350a4c64f36fb03b5" ;;
            AV1)  add_term "term_e2806600360399f7597c9d582325d1ea" ;;
        esac

        # --- Caractéristiques vidéo ---
        case "$HDR_TAG" in
            *HDR10+*) add_term "term_3458ddfaf530675b6566cf48cda76001" ;;
            *HDR*)    add_term "term_1e6061fe0dd0f6ce8027b1bce83b6b7d" ;;
        esac
        case "$HDR_TAG" in *DV*) add_term "term_51d58202387e82525468fc738da02246" ;; esac
        [ "$VIDEO_DEPTH" = "10" ] && add_term "term_ca34690b0fb2717154811a343bbfe05a"

        # --- Source / Type (ET quai obligatoire) ─────────────────────────────────
        # IMPORTANT: Le site exige EXACTEMENT UN term du groupe "quais".
        case "$SOURCE" in
            "COMPLETE.UHD.BLURAY"|"COMPLETE.BLURAY")
                add_term "term_6251bf6918d6193d846e871b8b1c2f58"
                [ "$QUAI_BLURAY" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_BLURAY" || \
                  log "  WARN: ID quai BluRay inconnu — upload pourrait échouer (400)"
                ;;
            "BluRay.REMUX"|"DVD.REMUX"|"REMUX")
                add_term "term_fdb58f8f752de86716d0312fcfecbc71"
                add_term "term_6251bf6918d6193d846e871b8b1c2f58"
                [ "$QUAI_REMUX"  != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_REMUX"  || \
                { log "  WARN: ID quai REMUX inconnu — fallback BluRay"; add_term "$QUAI_BLURAY"; }
                ;;
            "BluRay")
                add_term "term_6251bf6918d6193d846e871b8b1c2f58"
                [ "$QUAI_BLURAY" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_BLURAY" || \
                  log "  WARN: ID quai BluRay inconnu — upload pourrait échouer (400)"
                ;;
            "WEB-DL"|"WEB"|"HDLight"|"4KLight"|"mHD")
                add_term "term_8d7cfc3d0e1178ae2925ef270235b8d3"
                [ "$QUAI_WEB"    != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_WEB"    || \
                  log "  WARN: ID quai WEB-DL inconnu — upload pourrait échouer (400)"
                ;;
            "WEBRip")
                add_term "term_2ad87475841ea5d8111d089e5f6f2108"
                [ "$QUAI_WEBRIP" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_WEBRIP" || \
                { log "  WARN: ID quai WEBRip inconnu — fallback WEB-DL";
                  [ "$QUAI_WEB" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_WEB"; }
                ;;
            "DVDRip")
                add_term "term_7321eb03c51abdd81902fcff4cd26171"
                [ "$QUAI_DVDRIP" != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_DVDRIP" || \
                  log "  WARN: ID quai DVDRip inconnu — upload pourrait échouer (400)"
                ;;
            "HDTV")
                add_term "term_b3cd9652a11c4bd9cdcbb7597ab8c39b"
                [ "$QUAI_HDTV"   != "UNKNOWN_RUN_DISCOVERY" ] && add_term "$QUAI_HDTV"   || \
                  log "  WARN: ID quai HDTV inconnu — upload pourrait échouer (400)"
                ;;
        esac

        # --- Codec audio ---
        AUDIO_UP=$(echo "$AUDIO_CODEC" | tr '[:lower:]' '[:upper:]')
        case "$AUDIO_UP" in
            *TRUEHD*ATMOS*|*ATMOS*TRUEHD*) add_term "term_a2cf45267addea22635047c4d69465a0" ;;
            *TRUEHD*)    add_term "term_99a276df7596f2eb0902463e95111b76" ;;
            *EAC3*ATMOS*|*ATMOS*EAC3*) add_term "term_4671d371281904dcc885ddc92e92136d" ;;
            *EAC3*|*E-AC3*) add_term "term_8945be80314068e014c773f9d4cd7eb2" ;;
            *AC3*|*DD*)  add_term "term_e72a6bc1a89ca8c39f7a7fac21b95ef8" ;;
            *DTS:X*|*DTSX*) add_term "term_b3c9a9660e1c6ab6910859254fd592e1" ;;
            *DTSHDMA*|*DTSHD*MA*) add_term "term_49617ee39348e811452a2a4b7f5c0c64" ;;
            *DTSHD*|*DTS-HD*) add_term "term_934dcc048eaa8b4ef48548427735a797" ;;
            *DTS*)       add_term "term_d908f74951dee053ddada1bc0a8206db" ;;
            *AAC*)       add_term "term_b7ce0315952660c99a4ef7099b9154cb" ;;
            *FLAC*)      add_term "term_d857503fbf92ed967f81742146619c40" ;;
            *OPUS*)      add_term "term_b7ce0315952660c99a4ef7099b9154cb" ;;
            *MP3*)       add_term "term_0e2cdd8fd9f0031e7ffdbdb9255b8a31" ;;
        esac
        echo "$FNAME_UP" | grep -q 'ATMOS' && add_term "term_4671d371281904dcc885ddc92e92136d"

        # --- Langues audio ---
        case "$LANG_TAG" in
            MULTi*VFF|MULTi*VF2)
                add_term "term_fd7d017b825ebf12ce579dacea342e9d"  # MULTI
                add_term "term_bf31bb0a956b133988c2514f62eb1535"  # VFF
                ;;
            MULTi*VFQ)
                add_term "term_fd7d017b825ebf12ce579dacea342e9d"  # MULTI
                add_term "term_5fe7a76209bfc33e981ac5a2ca5a2e40"  # VFQ
                add_term "term_c87b5416341e6516baac12aa01fc5bc9"  # English
                ;;
            MULTi)
                add_term "term_fd7d017b825ebf12ce579dacea342e9d"  # MULTI
                add_term "term_bf918c3858a7dfe3b44ca70232f50272"  # French
                add_term "term_c87b5416341e6516baac12aa01fc5bc9"  # English
                ;;
            TRUEFRENCH|VFF)
                add_term "term_bf31bb0a956b133988c2514f62eb1535"  # VFF
                ;;
            FRENCH)
                add_term "term_bf918c3858a7dfe3b44ca70232f50272"  # French
                ;;
            VOSTFR)
                add_term "term_c87b5416341e6516baac12aa01fc5bc9"  # English (VO)
                add_term "term_5557a0dc2dff9923f8665c96246e2964"  # VOSTFR marker
                ;;
            VOF)
                add_term "term_bf918c3858a7dfe3b44ca70232f50272"  # French
                ;;
        esac

        # --- Sous-titres ---
        if [ -n "$SUBTITLES" ]; then
            echo "$SUBTITLES" | grep -qi 'fre\|fra\|fr\b' && add_term "term_9ef8bba2b9cd0d6c167f97b64c216d91"
            echo "$SUBTITLES" | grep -qi 'eng\|en\b'       && add_term "term_c0468b06760040c3a9a0674cd7eb224f"
        fi

        # --- Langues parlées (champ séparé) ---
        case "$LANG_TAG" in
            MULTi*)
                add_term "term_9cf21ecaa17940f8ea4f3b2d44627876"  # Français
                add_term "term_de9f4583ec916d7778e08783574796a5"  # Anglais
                ;;
            FRENCH|TRUEFRENCH|VFF|VOF)
                add_term "term_9cf21ecaa17940f8ea4f3b2d44627876"  # Français
                ;;
            VOSTFR)
                add_term "term_de9f4583ec916d7778e08783574796a5"  # Anglais (VO)
                ;;
        esac

        # --- Extension ---
        FILE_EXT=$(echo "$FILENAME" | grep -oE '\.[^.]+$' | tr '[:upper:]' '[:lower:]')
        case "$FILE_EXT" in
            .mkv) add_term "term_513ee8e7d062c6868b092c9a4267da8a" ;;
            .mp4) add_term "term_069f4f60531ce23f9f2bfe4ce834d660" ;;
            .avi) add_term "term_79db12fca0a1e537f6185f7aee22b8d7" ;;
        esac

        log "  TermIds : ${TERM_IDS:-<aucun>}"


        # Construire les arguments -F termIds[] pour curl
        TERM_CURL_ARGS=""
        if [ -n "$TERM_IDS" ]; then
            OLD_IFS="$IFS"; IFS=','
            for TID in $TERM_IDS; do
                [ -n "$TID" ] && TERM_CURL_ARGS="$TERM_CURL_ARGS -F termIds[]=$TID"
            done
            IFS="$OLD_IFS"
        fi

        # ── Vérification seed : fichier physique accessible par qBittorrent ─────────
        log "  Vérification seed qBittorrent..."
        SEED_OK=0

        # Chemin vu par qBittorrent (sans le préfixe NAS)
        QB_FILE_PATH=$(echo "$NAS_FILE_PATH" | sed "s|^${NAS_PATH_PREFIX}||")

        # Vérifier via l'API qBittorrent si le fichier est accessible
        QB_COOKIE_PRE="${WORK_DIR}/qb_pre_cookie.txt"
        QB_LOGIN_PRE=$(curl -sf --max-time 10 \
            -c "$QB_COOKIE_PRE" -X POST \
            "${QB_URL}/api/v2/auth/login" \
            -d "username=${QB_USER}&password=${QB_PASS}" 2>/dev/null)

        if echo "$QB_LOGIN_PRE" | grep -qi 'Ok'; then
            # Vérifier si le fichier existe déjà dans un torrent qBittorrent en seed
            _QB_ALL=$(curl -sf --max-time 10 \
                -b "$QB_COOKIE_PRE" \
                "${QB_URL}/api/v2/torrents/info" 2>/dev/null)
            _ALREADY_SEEDING=$(echo "$_QB_ALL" | python -c "
    import json,sys
    data=json.loads(sys.stdin.read())
    fname='$(echo "$FILENAME" | sed "s/'/'\''/g")'
    for t in data:
        n = t.get('name','')
        state = t.get('state','')
        if (n == fname or n == fname.rsplit('.',1)[0]) and any(s in state for s in ['UP','seeding','uploading']):
            print('already_seeding')
            break
    " 2>/dev/null)

            if [ "$_ALREADY_SEEDING" = "already_seeding" ]; then
                log "  ✓ Fichier déjà en seed dans qBittorrent"
                SEED_OK=1
            else
                # Vérifier simplement que le fichier physique est accessible
                QB_CHECK=$(curl -sf --max-time 10 \
                    -b "$QB_COOKIE_PRE" \
                    "${QB_URL}/api/v2/app/version" 2>/dev/null)
                if [ -n "$QB_CHECK" ] && [ -f "$NAS_FILE_PATH" ]; then
                    log "  ✓ Fichier accessible — seed possible après upload"
                    SEED_OK=1
                else
                    log "  ✗ Fichier inaccessible : $NAS_FILE_PATH"
                fi
            fi
        else
            log "  ✗ Connexion qBittorrent échouée"
        fi

        if [ "$SEED_OK" -eq 0 ]; then
            log "  ✗ ERREUR: La cargaison n'est pas scellée !"
            ERRORS=$((ERRORS+1))
            echo "ERREUR|$TITLE ($YEAR)|La cargaison n'est pas scellée !" >> "$RESULTS_FILE"
            continue
        fi

        # ── Upload sur La Cale via /api/internal/torrents/upload (API REST Next.js) ───────
        log "  Upload sur La Cale via API REST /api/internal/torrents/upload..."

        # Pas de CSRF token (app Next.js full REST, sessions via cookies httpOnly)
        # isAnonymous: "false" ou "true" (string)
        # IMPORTANT: les champs multilignes (nfoText, description) doivent être passés
        # via fichiers temporaires avec la syntaxe curl -F "champ=<fichier"
        # (évite la corruption des sauts de ligne quand bash expand la variable)
        NFO_TEXT_FILE="${WORK_DIR}/nfotext_field.txt"
        DESCRIPTION_FILE="${WORK_DIR}/description_field.txt"
        printf '%s' "" > "$NFO_TEXT_FILE"
        printf '%s' "" > "$DESCRIPTION_FILE"
        [ -f "$NFO_PATH" ] && cat "$NFO_PATH" > "$NFO_TEXT_FILE"
        generate_bbcode \
            "$TITLE" "$YEAR" "$OVERVIEW" "$COVER_URL" \
            "$QUALITY_NAME" "$VIDEO_CODEC" "$AUDIO_CODEC" "$AUDIO_LANGS" \
            "$FILE_SIZE" "$RATING" "$GENRES" "$CAST_JSON" \
            "$SUBTITLES" "$DYN_RANGE" "$DYN_TYPE" \
            > "$DESCRIPTION_FILE"

        CURL_DEBUG="${WORK_DIR}/curl_upload_debug.txt"

        UPLOAD_RESPONSE=$(curl -si --max-time 120 \
            --trace-ascii "$CURL_DEBUG" \
            -A "$BROWSER_UA" \
            -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
            -H "Accept: application/json" \
            -H "Accept-Language: fr-FR,fr;q=0.9,en;q=0.8" \
            -H "Referer: ${LACALE_URL}/upload" \
            -H "Origin: ${LACALE_URL}" \
            --compressed \
            -X POST \
            -F "title=${RELEASE_NAME}" \
            -F "categoryId=${CATEGORY_ID}" \
            -F "isAnonymous=false" \
            -F "file=@${TORRENT_PATH};type=application/x-bittorrent" \
            -F "nfoText=<${NFO_TEXT_FILE}" \
            -F "nfoFile=@${NFO_PATH};type=text/plain" \
            -F "description=<${DESCRIPTION_FILE}" \
            ${TMDB_ID:+-F "tmdbId=${TMDB_ID}" -F "tmdbType=MOVIE"} \
            ${TERM_CURL_ARGS} \
            "${LACALE_URL}/api/internal/torrents/upload" 2>/dev/null)

        HTTP_UPLOAD=$(echo "$UPLOAD_RESPONSE" | grep -oE '^HTTP/[0-9.]+ [0-9]+' | tail -1 | grep -oE '[0-9]+$')
        # Séparer headers et body
        UPLOAD_HEADERS=$(echo "$UPLOAD_RESPONSE" | sed -n '1,/^\r\{0,1\}$/p')
        UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE" | sed -n '/^\r\{0,1\}$/,$ p' | tail -n +2)
        log "  HTTP upload: ${HTTP_UPLOAD:-?}"
        log "  Headers réponse: $(echo "$UPLOAD_HEADERS" | grep -iE 'content-type|x-|cf-' | tr '\n' ' ')"
        # Log du body complet pour diagnostic (limité à 800 chars)
        log "  Body upload: $(echo "$UPLOAD_BODY" | head -c 800)"
        # Copier le debug curl dans les logs permanents
        [ -f "$CURL_DEBUG" ] && cp "$CURL_DEBUG" "${LOGS_DIR}/curl_upload_debug_${LOG_DATE}.txt" && \
            log "  Debug curl: ${LOGS_DIR}/curl_upload_debug_${LOG_DATE}.txt"

        # Détection du résultat JSON
        UPLOAD_OK="false"
        TORRENT_SLUG=""
        TORRENT_LINK=""

        # Parsing JSON de la réponse API REST
        if echo "$UPLOAD_BODY" | grep -q '"success"'; then
            UPLOAD_OK=$(echo "$UPLOAD_BODY" | jq -r '.success // false' 2>/dev/null)
            TORRENT_SLUG=$(echo "$UPLOAD_BODY" | jq -r '.slug // ""' 2>/dev/null)
            TORRENT_LINK=$(echo "$UPLOAD_BODY" | jq -r '.link // ""' 2>/dev/null)
        fi

        # Fallback : HTTP 200 avec data.torrentId = succès
        if [ "$UPLOAD_OK" != "true" ] && [ "$HTTP_UPLOAD" = "200" ]; then
            if echo "$UPLOAD_BODY" | grep -q '"torrentId"\|"infoHash"\|"slug"'; then
                UPLOAD_OK="true"
                TORRENT_SLUG=$(echo "$UPLOAD_BODY" | jq -r '.slug // .data.slug // ""' 2>/dev/null)
            fi
        fi

        if [ "$UPLOAD_OK" != "true" ]; then
            ERR_MSG=$(echo "$UPLOAD_BODY" | jq -r '.message // .error // ""' 2>/dev/null)
            [ -z "$ERR_MSG" ] && ERR_MSG=$(echo "$UPLOAD_BODY" | head -c 300)
            LAST_ERROR="$ERR_MSG"
            log "  ERREUR upload (HTTP $HTTP_UPLOAD): $ERR_MSG"
            # 403 Limite de rang / pending → stopper la boucle
            if echo "$ERR_MSG" | grep -qi 'Limite'; then
                log "  ⚓ Limite de pending atteinte — arrêt immédiat (compté comme upload)"
                notify "upload_fail" "La Cale — Limite pending" "$ERR_MSG"
                UPLOADED=$((UPLOADED+1))
                echo "LIMIT|$TITLE ($YEAR)|$ERR_MSG" >> "$RESULTS_FILE"
                break
            fi
            # Aide diagnostic spécifique au groupe "quais"
            if echo "$ERR_MSG" | grep -qi 'quai'; then
                log "  ╔══ DIAGNOSTIC QUAIS ══════════════════════════════════════════════╗"
                log "  ║ Le site exige un termId du groupe obligatoire 'quais'.          ║"
                log "  ║ Les IDs découverts au démarrage : WEB=$QUAI_WEB"
                log "  ║ Pour trouver les bons IDs :                                    ║"
                log "  ║  1. Connectez-vous sur la-cale.space                           ║"
                log "  ║  2. Allez sur /upload, ouvrez DevTools → Network               ║"
                log "  ║  3. Soumettez un upload manuellement                           ║"
                log "  ║  4. Cherchez la requête POST /api/internal/torrents/upload      ║"
                log "  ║  5. Dans le payload, notez les termIds[] du groupe 'quais'     ║"
                log "  ║  6. Mettez à jour les variables QUAI_* hardcodées              ║"
                log "  ╚═══════════════════════════════════════════════════════════════╝"
            fi
            ERRORS=$((ERRORS+1))
            echo "ERREUR|$TITLE ($YEAR)|Upload: $ERR_MSG" >> "$RESULTS_FILE"
            continue
        fi

        log "  ✓ Upload OK"
        [ -n "$TORRENT_SLUG" ] && log "  ✓ Slug : $TORRENT_SLUG"
        [ -n "$TORRENT_LINK" ] && log "  ✓ Lien : $TORRENT_LINK"

        # ── Ajout dans qBittorrent (seed) ─────────────────────────────────────
        log "  Ajout qBittorrent (seed mode)..."
        NAS_SAVE_DIR=$(dirname "$NAS_FILE_PATH" | sed "s|^${NAS_PATH_PREFIX}||" | python -c "import sys,unicodedata; print(unicodedata.normalize('NFC', sys.stdin.read().strip()))")
        QB_COOKIE="${WORK_DIR}/qb_cookie.txt"

        QB_LOGIN=$(curl -sf --max-time 10 \
            -c "$QB_COOKIE" -X POST \
            "${QB_URL}/api/v2/auth/login" \
            -d "username=${QB_USER}&password=${QB_PASS}" 2>/dev/null)

        QB_OK=0
        QB_HASH=""
        if echo "$QB_LOGIN" | grep -qi 'Ok'; then
            QB_ADD=$(curl -sf --max-time 30 \
                -b "$QB_COOKIE" -X POST \
                "${QB_URL}/api/v2/torrents/add" \
                -F "torrents=@${TORRENT_PATH};type=application/x-bittorrent" \
                -F "savepath=${NAS_SAVE_DIR}" \
                -F "skip_checking=true" \
                -F "paused=false" \
                2>/dev/null)
            if echo "$QB_ADD" | grep -qi 'Ok'; then
                QB_OK=1
                # Récupérer le hash du torrent ajouté pour vérification
                log "  ~ Chargement de la cargaison en cours, attendez 30 secondes ~"
                sleep 30
                QB_HASH=$(curl -sf --max-time 10 \
                    -b "$QB_COOKIE" \
                    "${QB_URL}/api/v2/torrents/info" 2>/dev/null | python -c "
    import json,sys
    data=json.loads(sys.stdin.read())
    fname='$(echo "$FILENAME" | sed "s/'/'\''/g")'
    for t in data:
        n = t.get('name','')
        if n == fname or n == fname.rsplit('.',1)[0]:
            print(t.get('hash',''))
            break
    " 2>/dev/null)
                if [ -n "$QB_HASH" ]; then
                    QB_STATE=$(curl -sf --max-time 10 \
                        -b "$QB_COOKIE" \
                        "${QB_URL}/api/v2/torrents/info?hashes=${QB_HASH}" 2>/dev/null | python -c "
    import json,sys
    data=json.loads(sys.stdin.read())
    print(data[0].get('state','') if data else '')
    " 2>/dev/null)
                    log "  État qBittorrent : ${QB_STATE:-inconnu}"

                    # Si en cours de vérification → attendre 30s et re-vérifier
                    if echo "$QB_STATE" | grep -qiE 'checking|metaDL'; then
                        log "  ~ Vérification en cours, attendez 30 secondes ~"
                        sleep 30
                        QB_STATE=$(curl -sf --max-time 10 \
                            -b "$QB_COOKIE" \
                            "${QB_URL}/api/v2/torrents/info?hashes=${QB_HASH}" 2>/dev/null | python -c "
    import json,sys
    data=json.loads(sys.stdin.read())
    print(data[0].get('state','') if data else '')
    " 2>/dev/null)
                        log "  État après attente : ${QB_STATE:-inconnu}"
                    fi

                    # Si missingFiles → forcer recheck
                    if echo "$QB_STATE" | grep -qi 'missingFiles\|error'; then
                        log "  WARN: fichier non trouvé par qBittorrent — recheck forcé..."
                        curl -sf --max-time 10 -b "$QB_COOKIE" -X POST \
                            -d "hashes=${QB_HASH}" \
                            "${QB_URL}/api/v2/torrents/recheck" >/dev/null 2>&1
                        sleep 30
                        QB_STATE=$(curl -sf --max-time 10 \
                            -b "$QB_COOKIE" \
                            "${QB_URL}/api/v2/torrents/info?hashes=${QB_HASH}" 2>/dev/null | python -c "
    import json,sys
    data=json.loads(sys.stdin.read())
    print(data[0].get('state','') if data else '')
    " 2>/dev/null)
                        log "  État après recheck : ${QB_STATE:-inconnu}"
                    fi

                    log "  État final qBittorrent : ${QB_STATE:-inconnu}"
                fi
            fi
        fi

        if [ "$QB_OK" -eq 1 ]; then
            log "  ✓ Torrent ajouté dans qBittorrent (état: ${QB_STATE:-OK})"
        else
            log "  WARN: ajout qBittorrent échoué (upload La Cale OK)"
            log "  qBittorrent login: $QB_LOGIN"
        fi

        # ── Historique ────────────────────────────────────────────────────────
        echo "$RELEASE_NAME" >> "$HISTORIQUE_FILE"
        UPLOADED=$((UPLOADED+1))
        QB_STATUS="OK"; [ "$QB_OK" -eq 0 ] && QB_STATUS="ERREUR"
        echo "OK|$TITLE ($YEAR)|$RELEASE_NAME|${TORRENT_LINK}|qBittorrent=$QB_STATUS|NFO=$NFO_SOURCE" >> "$RESULTS_FILE"
        # Mise à jour cache : ce film est maintenant sur La Cale
        _cache_set "${TMDB_ID:-title:${TITLE}}" "1"
        # Notification upload OK
        notify "upload_ok" "Upload OK — $TITLE ($YEAR)" "$RELEASE_NAME${TORRENT_LINK:+ — $TORRENT_LINK}"

    done < "${WORK_DIR}/movies_with_files.jsonl"
fi

# ─── Rapport final ─────────────────────────────────────────────────────────────
log_section "RAPPORT FINAL"
log "Uploadés : $UPLOADED  |  Skippés : $SKIPPED  |  Erreurs : $ERRORS"
log ""
while IFS='|' read -r STATUS REST; do
    case "$STATUS" in
        OK)     ICON="✓" ;;
        SKIP)   ICON="⏭" ;;
        ERREUR) ICON="✗" ;;
        LIMIT)  ICON="⚓" ;;
        *)      ICON="?" ;;
    esac
    log "  $ICON [$STATUS] $REST"
done < "$RESULTS_FILE"

# Notification résumé (Discord / Telegram)
if [ "$UPLOADED" -gt 0 ] || [ "$ERRORS" -gt 0 ]; then
    notify "summary" \
        "La Cale — ${UPLOADED} uploadé(s), ${ERRORS} erreur(s)" \
        "Uploadés: $UPLOADED | Skippés: $SKIPPED | Erreurs: $ERRORS"
fi

# ─── Envoi mail ───────────────────────────────────────────────────────────────
log_section "Envoi rapport par mail"
STATS_LINE="${UPLOADED} uploadé(s), ${SKIPPED} skip, ${ERRORS} erreur(s)"
send_report "$MAIL_SUBJECT — $(date '+%Y-%m-%d %H:%M') — $STATS_LINE" "$REPORT_FILE"

cp "$REPORT_FILE" "$LOG_FILE" 2>/dev/null || true
log "=== Terminé — Log: $LOG_FILE ==="

# ─── Nettoyage ─────────────────────────────────────────────────────────────────
log ""; log "Nettoyage des fichiers temporaires..."
OLD_COUNT=$(find "${BLACK_FLAG_DIR}/_tmp" -maxdepth 1 -name "lacale_*" -mtime +1 2>/dev/null | wc -l)
rm -rf "$WORK_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ Dossier session supprimé : $WORK_DIR"
find "${BLACK_FLAG_DIR}/_tmp" -maxdepth 1 -name "lacale_*" -mtime +1 -exec rm -rf {} \; 2>/dev/null || true
if [ "$OLD_COUNT" -gt 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ $OLD_COUNT ancien(s) dossier(s) temporaire(s) supprimé(s)"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ Aucun ancien dossier temporaire à nettoyer"
fi
if [ "$UPLOADED" -eq 0 ] && echo "$LAST_ERROR" | grep -q "Limite de 1 torrent"; then
echo '                                                .                             '
echo '   Allez voir si votre cargaison    _._/|_                                   '
echo '          .  a passé le kraken!     (__( (_(                                  '
echo '         /|                   - '"'"'. \'"'"''"'"'-:)8)-.                             '
echo '        ( (_..-..          .'"'"'     '"'"'.'"'"'-(_(-'"'"'                              '
echo '  _~_       '"'"'-.--.. '"'"'.      .'"'"'         '"'"'  )8)                           '
echo ' __(__(__     \      88 \    /            )(8(        \.    .                '
echo '(_((_((_(      8\     88 \.-'"'"'  .-.        )88 :       /\\  _X_ __ .         '
echo '\=-:--:--:--.   8)     88/__) /(e))       88.'"'"'        \#\\(__((_//\   .    '
echo '_,\_o__o__o__/,__(8(_,__,_'"'"'.'"'"'--'"'"' '"'"'--'"'"' _    _88.'"'"'..___,___,\_,,,|/_(Y(/__,__ldb'
echo "            \    '._''--..'-/88 ) 88)(8  \\  \              \w\_   /X/      "
echo "             8\ __.--''_--'( 8  ( 8/   88( )8 )              -' ' __         "
echo "              '8888--''     \ 8  \88   88| 88(                   /_/          "
echo '                            )88  (88   ) ) 88\                  _ '"'"'       '
echo '                           ( 8    )88 ( (   88\                /V             '
echo '                            )8)   (8\'"'"'-8 )-. '"'"'8'"'"'.___  __           '
echo '                            //     \8 '"'"'-//--'"'"'  '"'"'88-8.-'"'"'        '
echo '                           ((     ((   ))                                     '
echo '                            \      \   (    X                                 '
else
echo '             .                         .               +                         '"'"'        '
echo '        .   .                  .        .                                      '"'"'          '
echo '               .  |                  '"'"' '"'"'      '"'"'                  .                        '
echo '                --o--                            +                                        '
echo ' .     .     '"'"'    |       '"'"'   .        '"'"'               .       '"'"'      '"'"'+    '"'"'             '
echo '                           '"'"'                                    +                 '"'"'  '"'"'    '
echo '               o   .    +            .                     .o                   '"'"'         '
echo '                                                                + .                       '
if [ "$UPLOADED" -gt 1 ]; then
    echo '        '"'"'                .        ~ cargaisons en route ~             .        *   o  '
elif [ "$UPLOADED" -eq 1 ]; then
    echo '        '"'"'                .        ~ cargaison en route ~              .        *   o  '
elif [ "$UPLOADED" -eq 0 ] && [ "$ERRORS" -gt 0 ]; then
    echo '        '"'"'                .    ~ le navire est resté à quai ~             .        *   o  '
else
    echo '        '"'"'                .        ~ pas de vent aujourd'"'"'hui ~             .        *   o  '
fi
echo '                         .                                    +          +                '
echo '                          o                +                                              '
echo ' '"'"'                      .                      .                            *             '
echo '                     .                      o          *                                  '
echo '.                    o                                                                    '
echo '                                      o   *     o       .           .    .                '
echo '                                                                                o         '
echo '                          .              .                                                '
echo '               '"'"'                   .                                              .      '"'"' '
echo '         o      .                 '"'"'                     '"'"'                                 '
echo '           .       .                '"'"'                              o            '"'"'          '
fi
