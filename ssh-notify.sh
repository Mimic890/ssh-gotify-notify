#!/usr/bin/env bash
# Уведомления о SSH-сессиях в Gotify. Вызывается из pam_exec через обёртку.
#
# Это единственный источник правды: ssh-notify.nix читает файл напрямую,
# install-ssh-notify.sh встраивает его копию (tools/sync-embedded.sh).
#
# Ручной запуск для отладки:
#   PAM_SERVICE=sshd PAM_TYPE=open_session PAM_USER=test \
#   PAM_RHOST=8.8.8.8 PAM_TTY=pts/0 ssh-notify.sh

CONF="${SSH_NOTIFY_CONF:-/etc/ssh-notify.conf}"
STATE_DIR="${SSH_NOTIFY_STATE:-/run/ssh-notify}"

log() { logger -t ssh-notify -p authpriv.info -- "$*" 2>/dev/null || true; }
warn() { logger -t ssh-notify -p authpriv.warning -- "$*" 2>/dev/null || true; }

# ---------- значения по умолчанию ----------
# Задаются ДО чтения конфига, чтобы старый конфиг без новых ключей не ломал скрипт.
GOTIFY_URL=""
GOTIFY_TOKEN=""
GOTIFY_TOKEN_FILE=""
GEO_LOOKUP=1
REQUIRE_TTY=0
NOTIFY_CLOSE=1
PRIORITY_OPEN=7
PRIORITY_CLOSE=3
IGNORE_USERS=""
IGNORE_NETS=""
HTTP_TIMEOUT=10
GEO_TIMEOUT=5
LOG_FILE=/var/log/ssh-notify.log

# shellcheck source=/dev/null
if ! . "$CONF" 2>/dev/null; then
  warn "не читается $CONF, уведомление пропущено"
  exit 0
fi

[ "${PAM_SERVICE:-}" = "sshd" ] || exit 0

if [ -n "$GOTIFY_TOKEN_FILE" ]; then
  GOTIFY_TOKEN="$(cat "$GOTIFY_TOKEN_FILE" 2>/dev/null)"
fi
GOTIFY_URL="${GOTIFY_URL%/}"

if [ -z "$GOTIFY_URL" ] || [ -z "$GOTIFY_TOKEN" ]; then
  warn "не задан URL или токен в $CONF, уведомление пропущено"
  exit 0
fi

# Приоритет уходит в JSON как число: пустое или мусорное значение сделало бы
# тело запроса невалидным, а Gotify ответил бы 400.
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_num "$PRIORITY_OPEN"  || PRIORITY_OPEN=7
is_num "$PRIORITY_CLOSE" || PRIORITY_CLOSE=3
is_num "$HTTP_TIMEOUT"   || HTTP_TIMEOUT=10
is_num "$GEO_TIMEOUT"    || GEO_TIMEOUT=5

# ---------- фильтры ----------
# Элементы списков — glob-шаблоны: "backup rsync-*", "10.* 192.168.* 203.0.113.5".
matches() {
  local value="$1" pattern
  shift
  for pattern in $*; do
    # shellcheck disable=SC2254
    case "$value" in $pattern) return 0 ;; esac
  done
  return 1
}

[ "$REQUIRE_TTY" = "1" ] && [ -z "${PAM_TTY:-}" ] && exit 0

if [ -n "$IGNORE_USERS" ] && matches "${PAM_USER:-}" "$IGNORE_USERS"; then
  exit 0
fi
if [ -n "$IGNORE_NETS" ] && matches "${PAM_RHOST:-}" "$IGNORE_NETS"; then
  exit 0
fi

# ---------- состояние ----------
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null
# Сессии, которые не закрылись штатно (паника, kill -9), оставляют файлы навсегда.
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

KEY="$STATE_DIR/${SSH_SESSION_KEY:-$PPID}"

# ---------- отправка ----------
send() {
  local title="$1" message="$2" priority="$3" body response status

  body=$(printf '%s' "$message" | jq -Rs \
           --arg t "$title" --argjson p "$priority" \
           '{title: $t, message: ., priority: $p,
             extras: {"client::display": {contentType: "text/plain"}}}') || {
    warn "jq не собрал тело запроса"
    return 1
  }

  response=$(curl -sS -o /dev/null -w '%{http_code}' \
    --max-time "$HTTP_TIMEOUT" --retry 2 --retry-delay 2 \
    -X POST "$GOTIFY_URL/message" \
    -H "X-Gotify-Key: $GOTIFY_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$body" 2>&1)
  status=$?

  if [ "$status" -ne 0 ] || [ "$response" != "200" ]; then
    # Без этой строки любой сбой доставки остаётся полностью невидимым.
    warn "доставка не удалась: curl=$status ответ=$response title=$title"
    return 1
  fi
  return 0
}

# Значение в строку key=value: кавычки только если внутри пробелы.
kv() {
  case "$2" in
    "") printf '%s=— ' "$1" ;;
    *\ *) printf '%s="%s" ' "$1" "$2" ;;
    *) printf '%s=%s ' "$1" "$2" ;;
  esac
}

ensure_log_file() {
  local dir
  dir=$(dirname "$LOG_FILE")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  if [ ! -e "$LOG_FILE" ]; then
    # 640 root:adm — внутри имена пользователей и адреса.
    ( umask 027; : >> "$LOG_FILE" ) 2>/dev/null || return 1
    chgrp adm "$LOG_FILE" 2>/dev/null || true
  fi
  return 0
}

# Запись события. Вызывается ПОСЛЕ отправки, но независимо от её успеха:
# недоступный Gotify не должен стирать событие из истории.
record() {
  local type="$1" message="$2" delivered="$3" extra="$4"
  local label status="" ts="$EVENT_TS"
  case "$type" in open) label="вход" ;; *) label="выход" ;; esac
  case "$delivered" in
    no)  status=" · НЕ ДОСТАВЛЕНО" ;;
    off) status=" · без уведомления" ;;
  esac

  # Одна структурированная строка в syslog: грепается, ротируется journald.
  log "$(printf '%s ' "$type"; kv user "${PAM_USER:-}"; kv rhost "${PAM_RHOST:-}"; \
         printf '%s' "$extra"; kv delivered "$delivered")"

  [ -n "$LOG_FILE" ] || return 0
  ensure_log_file || { warn "не могу писать в $LOG_FILE"; return 0; }
  # flock, чтобы одновременные сессии не перемешали свои блоки.
  {
    flock 9 2>/dev/null || true
    printf '=== %s · %s · %s · %s%s ===\n%s\n\n' \
      "$ts" "$label" "${PAM_USER:-—}" "${PAM_RHOST:-—}" "$status" "$message" >&9
  } 9>>"$LOG_FILE"
}

# ---------- вспомогательное ----------
short_host() {
  local h
  h=$(hostname -s 2>/dev/null) || h=$(uname -n)
  printf '%s' "${h%%.*}"
}

fmt_duration() {
  local s="$1" d h m
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if [ "$d" -gt 0 ]; then
    printf '%dд %02dч %02dм' "$d" "$h" "$m"
  else
    printf '%dч %02dм %02dс' "$h" "$m" "$((s % 60))"
  fi
}

# Запрос к ipinfo имеет смысл только для публичного адреса. При пустом RHOST
# путь вырождается в https://ipinfo.io//json, и API возвращает геоданные
# самого сервера — они выглядели бы как местоположение клиента.
is_public_ip() {
  case "$1" in
    ""|localhost|127.*|10.*|169.254.*|192.168.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
    ::1|[fF][cCdD][0-9a-fA-F][0-9a-fA-F]:*|[fF][eE]8[0-9a-fA-F]:*) return 1 ;;
    *.*|*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# PAM_USER попадает в шаблон grep, поэтому метасимволы надо погасить.
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$\\/]/\\&/g'; }

auth_method() {
  local user host attempt out
  user=$(re_escape "${PAM_USER:-}")
  host=$(re_escape "${PAM_RHOST:-}")
  # Строка "Accepted ..." пишется до pam_open_session, но journald может
  # чуть отставать, поэтому одна повторная попытка.
  for attempt in 1 2; do
    out=$(journalctl -u ssh -u sshd -n 100 --no-pager --since "-2 min" 2>/dev/null \
          | grep -m1 "Accepted .* for $user from $host" \
          | sed 's/.*Accepted \([a-z-]*\) .*/\1/')
    [ -n "$out" ] && { printf '%s' "$out"; return; }
    [ "$attempt" = "1" ] && sleep 1
  done
}

HOSTNAME_S=$(short_host)
# Время берём до геозапроса и отправки: иначе штамп уезжает на секунды,
# а у короткой сессии вход мог бы получить время позже выхода.
EVENT_TS=$(date '+%F %T %Z')
RC=0

case "${PAM_TYPE:-}" in
  open_session)
    date +%s > "$KEY"

    GEO=""
    if [ "$GEO_LOOKUP" = "1" ] && is_public_ip "${PAM_RHOST:-}"; then
      GEO=$(curl -fsS --max-time "$GEO_TIMEOUT" "https://ipinfo.io/$PAM_RHOST/json" 2>/dev/null \
            | jq -r '[.city, .region, .country, .org] | map(select(.)) | join(", ")' 2>/dev/null)
    fi

    RDNS=""
    if [ -n "${PAM_RHOST:-}" ]; then
      RDNS=$(getent hosts "$PAM_RHOST" 2>/dev/null | awk '{print $2}')
    fi

    METHOD=$(auth_method)

    MESSAGE="Пользователь: ${PAM_USER:-—}
IP:           ${PAM_RHOST:-—}
rDNS:         ${RDNS:-—}
Гео:          ${GEO:-—}
Метод:        ${METHOD:-—}
TTY:          ${PAM_TTY:-—}
Время:        $EVENT_TS
Uptime:       $(uptime -p 2>/dev/null || echo '—')"

    DELIVERED=yes
    send "SSH вход: ${PAM_USER:-?}@$HOSTNAME_S" "$MESSAGE" "$PRIORITY_OPEN" \
      || { DELIVERED=no; RC=1; }
    record open "$MESSAGE" "$DELIVERED" \
      "$(kv rdns "$RDNS"; kv geo "$GEO"; kv method "$METHOD"; kv tty "${PAM_TTY:-}")"
    ;;

  close_session)
    DUR="неизвестно"
    if [ -f "$KEY" ]; then
      START=$(cat "$KEY"); rm -f "$KEY"
      if is_num "$START"; then
        DUR=$(fmt_duration $(( $(date +%s) - START )))
      fi
    fi

    MESSAGE="Пользователь: ${PAM_USER:-—}
IP:           ${PAM_RHOST:-—}
Длительность: $DUR
Время:        $EVENT_TS"

    # NOTIFY_CLOSE=0 отключает уведомление, а не историю: в лог пишем всё равно.
    if [ "$NOTIFY_CLOSE" = "1" ]; then
      DELIVERED=yes
      send "SSH выход: ${PAM_USER:-?}@$HOSTNAME_S" "$MESSAGE" "$PRIORITY_CLOSE" \
        || { DELIVERED=no; RC=1; }
    else
      DELIVERED=off
    fi
    record close "$MESSAGE" "$DELIVERED" "$(kv duration "$DUR")"
    ;;
esac

exit "$RC"
