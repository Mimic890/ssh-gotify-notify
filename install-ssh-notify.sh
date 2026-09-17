#!/usr/bin/env bash
# Управление уведомлениями о SSH-сессиях в Gotify.
#
#   ssh-notify-ctl install     установка или перенастройка
#   ssh-notify-ctl test        отправить тестовые сообщения
#   ssh-notify-ctl status      показать состояние
#   ssh-notify-ctl logs        история входов и выходов (logs --help — опции)
#   ssh-notify-ctl uninstall   удалить подчистую
#   ssh-notify-ctl help        эта справка
#
# Debian, Ubuntu, Arch, Fedora, openSUSE, Alpine.
# На NixOS ставить не нужно: импортируй ssh-notify.nix как модуль.

set -euo pipefail

VERSION=2.0

CTL=/usr/local/bin/ssh-notify-ctl
MAIN=/usr/local/bin/ssh-notify
WRAP=/usr/local/bin/ssh-notify-wrap
CONF=/etc/ssh-notify.conf
PAMFILE=/etc/pam.d/sshd
STATE=/run/ssh-notify
LOGROTATE=/etc/logrotate.d/ssh-notify
PAMLINE="session optional pam_exec.so quiet $WRAP"

# Пути из версий до 2.0 — нужны, чтобы uninstall подчищал и старые установки.
LEGACY=(/usr/local/bin/ssh-notify.sh /usr/local/bin/ssh-notify-wrap.sh)

die() { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo "  $*"; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

# Скрипт могут запустить как `curl ... | bash`, тогда stdin занят самим
# скриптом и read прочитал бы его текст вместо ответа пользователя.
ask() {
  local prompt="$1" silent="${2:-}" reply=""
  # Проверять -r /dev/tty нельзя: без управляющего терминала узел на месте
  # и права позволяют, но open() возвращает ENXIO. Пробуем открыть на самом деле.
  if { : < /dev/tty; } 2>/dev/null; then
    if [ "$silent" = "silent" ]; then
      read -rsp "$prompt" reply < /dev/tty || reply=""
      echo >&2
    else
      read -rp "$prompt" reply < /dev/tty || reply=""
    fi
  elif [ "$silent" = "silent" ]; then
    read -rsp "$prompt" reply || reply=""
    echo >&2
  else
    read -rp "$prompt" reply || reply=""
  fi
  printf '%s' "$reply"
}

# ---------- определение системы ----------
PM=""
detect_pm() {
  [ -n "$PM" ] && return 0
  local c
  for c in apt-get pacman dnf yum zypper apk; do
    if command -v "$c" >/dev/null 2>&1; then PM="$c"; return 0; fi
  done
  return 1
}

install_pkgs() {
  detect_pm || die "не нашёл пакетный менеджер, поставь curl и jq вручную"
  echo "Ставлю через $PM: $*"
  case "$PM" in
    apt-get) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    pacman)  pacman -Sy --needed --noconfirm "$@" ;;
    dnf)     dnf install -y -q "$@" ;;
    yum)     yum install -y -q "$@" ;;
    zypper)  zypper --non-interactive --quiet install "$@" ;;
    apk)     apk add --no-cache "$@" ;;
  esac
}

# Debian зовёт юнит ssh, почти все остальные — sshd.
reload_sshd() {
  local u
  for u in sshd ssh; do
    if command -v systemctl >/dev/null 2>&1 && systemctl reload "$u" 2>/dev/null; then
      info "перезагрузил $u"; return 0
    fi
    if command -v rc-service >/dev/null 2>&1 && rc-service "$u" reload 2>/dev/null; then
      info "перезагрузил $u"; return 0
    fi
  done
  echo "  ВНИМАНИЕ: не смог перезапустить sshd, сделай это сам" >&2
  return 0
}

# yes / no / unknown — последнее означает, что sshd -T вообще не отработал.
usepam_state() {
  local out
  if out=$(sshd -T 2>/dev/null); then
    if printf '%s' "$out" | grep -qi '^usepam yes'; then echo yes; else echo no; fi
  else
    echo unknown
  fi
}

# ---------- установка файлов ----------
write_main() {
  # >>> EMBEDDED ssh-notify.sh >>>
  cat > "$MAIN" <<'SCRIPT'
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
SCRIPT
  # <<< EMBEDDED ssh-notify.sh <<<
  chown root:root "$MAIN"; chmod 700 "$MAIN"

  # pam_exec синхронный: без фона недоступный Gotify задержит логин
  # на таймаут curl. Обёртка возвращает управление мгновенно.
  cat > "$WRAP" <<SCRIPT
#!/bin/sh
export SSH_SESSION_KEY="\$PPID"
setsid $MAIN </dev/null >/dev/null 2>&1 &
exit 0
SCRIPT
  chown root:root "$WRAP"; chmod 700 "$WRAP"
}

# Кладём сам скрипт в PATH, чтобы сервисом можно было управлять
# командой ssh-notify-ctl, не помня, куда скачан установщик.
install_self() {
  local src
  src=$(readlink -f "$0" 2>/dev/null || echo "$0")
  [ -f "$src" ] || return 0
  [ "$src" = "$CTL" ] && return 0
  install -m 755 -o root -g root "$src" "$CTL"
  info "команда установлена: $CTL"
}

selftest() {
  local rc=0
  PAM_SERVICE=sshd PAM_TYPE=open_session PAM_USER=install-test \
    PAM_RHOST=8.8.8.8 PAM_TTY=pts/0 SSH_SESSION_KEY=selftest "$MAIN" || rc=$?
  PAM_SERVICE=sshd PAM_TYPE=close_session PAM_USER=install-test \
    PAM_RHOST=8.8.8.8 SSH_SESSION_KEY=selftest "$MAIN" >/dev/null 2>&1 || true
  return $rc
}

# ---------- подкоманды ----------
cmd_status() {
  echo "ssh-notify-ctl $VERSION"
  echo "Команда:   $([ -x "$CTL" ] && echo "$CTL" || echo 'не в PATH')"
  echo "Скрипт:    $([ -x "$MAIN" ] && echo "$MAIN" || echo 'нет')"
  echo "Обёртка:   $([ -x "$WRAP" ] && echo "$WRAP" || echo 'нет')"
  echo "Конфиг:    $([ -f "$CONF" ] && echo "$CONF" || echo 'нет')"
  echo -n "PAM:       "
  grep -q 'ssh-notify-wrap' "$PAMFILE" 2>/dev/null \
    && echo "подключено в $PAMFILE" || echo "НЕ подключено"
  echo "UsePAM:    $(usepam_state)"
  echo "Сессии:    $(find "$STATE" -maxdepth 1 -type f 2>/dev/null | wc -l) активных"
  local lf=""
  [ -f "$CONF" ] && lf=$(. "$CONF" 2>/dev/null; printf '%s' "${LOG_FILE:-}")
  if [ -n "$lf" ]; then
    echo "Лог:       $lf ($(grep -c '^=== ' "$lf" 2>/dev/null || echo 0) записей)"
  else
    echo "Лог:       выключен"
  fi
  if [ -f "$CONF" ]; then
    echo "--- настройки (без токена) ---"
    grep -v '^GOTIFY_TOKEN=' "$CONF" | grep -v '^\s*$' || true
  fi
  echo "--- журнал ---"
  journalctl -t ssh-notify -n 10 --no-pager 2>/dev/null \
    || echo "journalctl недоступен, смотри /var/log/auth.log"
}

cmd_test() {
  [ -x "$MAIN" ] || die "не установлено, сначала: ssh-notify-ctl install"
  selftest || die "Gotify не ответил. Подробности: journalctl -t ssh-notify -n 20"
  echo "Два тестовых сообщения ушли."
}

# Без ротации файл растёт вечно. Ставим правило, только если logrotate есть.
setup_logrotate() {
  local target="$1"
  if [ -z "$target" ]; then rm -f "$LOGROTATE"; return 0; fi
  [ -d /etc/logrotate.d ] || { info "logrotate не найден, ротацию настрой сам"; return 0; }
  cat > "$LOGROTATE" <<EOF
$target {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
  chmod 644 "$LOGROTATE"
  info "ротация настроена: $LOGROTATE"
}

# ---------- просмотр лога ----------
log_usage() {
  cat <<'USAGE'
ssh-notify-ctl logs [опции] — история входов и выходов

  -n N, --lines N   последние N записей (по умолчанию 20)
  -a, --all         все записи
  -f, --follow      следить в реальном времени
  -u, --user ПОДСТР фильтр по пользователю
  -i, --ip ПОДСТР   фильтр по адресу
      --open        только входы
      --close       только выходы
      --failed      только недоставленные в Gotify
  -g, --grep ТЕКСТ  поиск по всему тексту записи
      --since КОГДА записи новее: "2026-09-17", "today", "-2 hours"
      --stats       сводка вместо записей
      --path        показать путь к файлу лога
      --no-color    без подсветки

Примеры:
  ssh-notify-ctl logs -n 5
  ssh-notify-ctl logs -f
  ssh-notify-ctl logs -u alice --since today
  ssh-notify-ctl logs --failed -a
USAGE
}

# Записи разделены пустой строкой, поэтому awk читает их в режиме абзацев.
# Заголовок: === ДАТА · ТИП · ПОЛЬЗОВАТЕЛЬ · АДРЕС[ · СТАТУС] ===
LOG_AWK='
function colorize(r,   parts, k, cnt2, head, c, out) {
  if (color != "1") return r
  cnt2 = split(r, parts, "\n")
  head = parts[1]
  c = c_close
  if (index(head, " \xc2\xb7 \xd0\xb2\xd1\x85\xd0\xbe\xd0\xb4 \xc2\xb7 ") > 0) c = c_open
  if (index(head, "\xd0\x9d\xd0\x95 \xd0\x94\xd0\x9e\xd0\xa1\xd0\xa2\xd0\x90\xd0\x92\xd0\x9b\xd0\x95\xd0\x9d\xd0\x9e") > 0) c = c_fail
  out = c head reset
  for (k = 2; k <= cnt2; k++) out = out "\n" parts[k]
  return out
}
function want(r,   parts, h, fld, cnt, ts, type, user, ip, st) {
  split(r, parts, "\n")
  h = parts[1]
  if (h !~ /^=== .* ===$/) return 0
  sub(/^=== /, "", h); sub(/ ===$/, "", h)
  cnt = split(h, fld, " \xc2\xb7 ")
  ts = fld[1]; type = fld[2]; user = fld[3]; ip = fld[4]
  st = (cnt >= 5 ? fld[5] : "")
  if (f_type   != "" && type != f_type) return 0
  if (f_user   != "" && index(tolower(user), tolower(f_user)) == 0) return 0
  if (f_ip     != "" && index(tolower(ip),   tolower(f_ip))   == 0) return 0
  if (f_failed == "1" && index(st, "\xd0\x9d\xd0\x95 \xd0\x94\xd0\x9e\xd0\xa1\xd0\xa2\xd0\x90\xd0\x92\xd0\x9b\xd0\x95\xd0\x9d\xd0\x9e") == 0) return 0
  if (f_grep   != "" && index(tolower(r), tolower(f_grep)) == 0) return 0
  if (f_since  != "" && substr(ts, 1, 19) < f_since) return 0
  return 1
}
function flush_rec(r) {
  if (r == "" || !want(r)) return
  # В режиме слежения печатаем сразу: ждать следующую запись, чтобы отдать
  # текущую, значит показывать вход только после выхода.
  if (stream == "1") { print colorize(r); print ""; fflush(); return }
  rec[++n] = r
}
BEGIN { buf = ""; n = 0 }
/^$/ { flush_rec(buf); buf = ""; next }
{ buf = (buf == "" ? $0 : buf "\n" $0) }
END {
  flush_rec(buf)
  if (stream == "1") exit
  start = (last > 0 && n > last) ? n - last + 1 : 1
  for (i = start; i <= n; i++) { print colorize(rec[i]); print "" }
}'

cmd_log() {
  local n=20 follow=0 f_user="" f_ip="" f_type="" f_failed="" f_grep="" since=""
  local stats=0 showpath=0 color=auto

  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--lines)  n="${2:-20}"; shift 2 ;;
      -a|--all)    n=0; shift ;;
      -f|--follow) follow=1; shift ;;
      -u|--user)   f_user="${2:-}"; shift 2 ;;
      -i|--ip)     f_ip="${2:-}"; shift 2 ;;
      --open)      f_type="вход"; shift ;;
      --close)     f_type="выход"; shift ;;
      --failed)    f_failed=1; shift ;;
      -g|--grep)   f_grep="${2:-}"; shift 2 ;;
      --since)     since="${2:-}"; shift 2 ;;
      --stats)     stats=1; shift ;;
      --path)      showpath=1; shift ;;
      --no-color)  color=never; shift ;;
      -h|--help)   log_usage; return 0 ;;
      *) die "неизвестная опция для logs: $1 (см. ssh-notify-ctl logs --help)" ;;
    esac
  done

  local LOG_FILE=/var/log/ssh-notify.log
  # shellcheck source=/dev/null
  [ -f "$CONF" ] && . "$CONF"

  [ "$showpath" = "1" ] && { echo "$LOG_FILE"; return 0; }
  [ -n "$LOG_FILE" ] || die "лог в файл выключен (LOG_FILE пуст в $CONF)"
  [ -f "$LOG_FILE" ] || { echo "Записей пока нет: $LOG_FILE не создан."; return 0; }

  # --since принимает всё, что понимает date; сравнение потом лексикографическое.
  local since_norm=""
  if [ -n "$since" ]; then
    # date -d today возвращает текущее время, а не полночь: голые даты
    # и слова вроде "today" пользователь имеет в виду от начала суток.
    case "${since,,}" in
      today|сегодня)   since_norm=$(date -d 'today 00:00' '+%F %T') ;;
      yesterday|вчера) since_norm=$(date -d 'yesterday 00:00' '+%F %T') ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        since_norm=$(date -d "$since 00:00" '+%F %T' 2>/dev/null) \
          || die "не понял дату: $since" ;;
      *) since_norm=$(date -d "$since" '+%F %T' 2>/dev/null) \
          || die "не понял дату: $since" ;;
    esac
  fi

  [ "$stats" = "1" ] && { log_stats "$LOG_FILE"; return 0; }

  local use_color=0
  case "$color" in
    never) use_color=0 ;;
    *) { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } && use_color=1 ;;
  esac

  local -a awkargs=(
    -v "f_user=$f_user" -v "f_ip=$f_ip" -v "f_type=$f_type"
    -v "f_failed=$f_failed" -v "f_grep=$f_grep" -v "f_since=$since_norm"
    -v "color=$use_color"
    -v 'c_open=\033[1;32m' -v 'c_close=\033[1;34m'
    -v 'c_fail=\033[1;31m' -v 'reset=\033[0m'
  )

  if [ "$follow" = "1" ]; then
    echo "Слежу за $LOG_FILE, Ctrl-C чтобы выйти." >&2
    tail -n 200 -f "$LOG_FILE" \
      | awk "${awkargs[@]}" -v last=0 -v stream=1 "$LOG_AWK"
  else
    awk "${awkargs[@]}" -v "last=$n" -v stream=0 "$LOG_AWK" "$LOG_FILE"
  fi
}

log_stats() {
  local f="$1" total opens closes failed
  total=$(grep -c '^=== .* ===$' "$f" || true)
  opens=$(grep -c ' · вход · '  "$f" || true)
  closes=$(grep -c ' · выход · ' "$f" || true)
  failed=$(grep -c 'НЕ ДОСТАВЛЕНО' "$f" || true)
  echo "Файл:          $f ($(du -h "$f" | cut -f1))"
  echo "Записей:       $total  (входов $opens, выходов $closes)"
  echo "Не доставлено: $failed"
  echo "Первая:        $(grep -m1 '^=== ' "$f" | sed 's/^=== //; s/ ===$//' || true)"
  echo "Последняя:     $(grep '^=== ' "$f" | tail -1 | sed 's/^=== //; s/ ===$//' || true)"
  echo
  echo "Чаще всего заходили:"
  grep ' · вход · ' "$f" | awk -F' · ' '{print $3}' | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "  %-20s %s\n", $2, $1}'
  echo "Чаще всего с адресов:"
  grep ' · вход · ' "$f" | awk -F' · ' '{print $4}' | sed 's/ ===$//' \
    | sort | uniq -c | sort -rn | head -5 | awk '{printf "  %-20s %s\n", $2, $1}'
}

cmd_uninstall() {
  local yes="${1:-}" answer logfile=""
  # Путь к логу читаем до того, как удалим конфиг, иначе потеряем его.
  [ -f "$CONF" ] && logfile=$(. "$CONF" 2>/dev/null; printf '%s' "${LOG_FILE:-}")
  echo "Удаляю ssh-notify."
  if grep -q 'ssh-notify-wrap' "$PAMFILE" 2>/dev/null; then
    cp "$PAMFILE" "$PAMFILE.ssh-notify-bak"
    sed -i '/ssh-notify-wrap/d' "$PAMFILE"
    info "строка убрана из $PAMFILE"
  fi
  rm -f "$MAIN" "$WRAP" "${LEGACY[@]}"
  rm -rf "$STATE"
  info "скрипты и состояние удалены"

  if [ -f "$CONF" ]; then
    if [ "$yes" = "--yes" ]; then
      answer=y
    else
      answer=$(ask "Удалить $CONF (в нём токен)? [Y/n]: ")
    fi
    case "${answer,,}" in
      n|no|н|нет) info "конфиг оставлен: $CONF" ;;
      *) rm -f "$CONF"; info "конфиг удалён" ;;
    esac
  fi

  rm -f "$LOGROTATE"
  if [ -n "$logfile" ] && [ -e "$logfile" ]; then
    if [ "$yes" = "--yes" ]; then
      answer=y
    else
      answer=$(ask "Удалить историю входов $logfile? [y/N]: ")
    fi
    case "${answer,,}" in
      y|yes|д|да) rm -f "$logfile" "$logfile".[0-9]* "$logfile".*.gz; info "история удалена" ;;
      *) info "история оставлена: $logfile" ;;
    esac
  fi

  # Бэкапы PAM, сделанные этим скриптом. Чужие не трогаем.
  rm -f "$PAMFILE".bak.[0-9]* "$PAMFILE.ssh-notify-bak"
  info "бэкапы PAM убраны"

  if [ -x "$CTL" ]; then
    info "команда $CTL удалится последней"
    rm -f "$CTL"
  fi
  echo "Готово. UsePAM и sshd_config не трогал."
}

cmd_install() {
  [ -e /etc/NIXOS ] && die "это NixOS: импортируй ssh-notify.nix как модуль, установка не нужна"
  [ -f "$PAMFILE" ] || die "нет $PAMFILE — PAM для sshd не настроен, дальше идти опасно"
  detect_pm || echo "ВНИМАНИЕ: пакетный менеджер не опознан, curl и jq должны быть уже установлены" >&2

  # ---------- параметры ----------
  GOTIFY_URL=""; GOTIFY_TOKEN=""
  GEO_LOOKUP=1; REQUIRE_TTY=0; NOTIFY_CLOSE=1
  IGNORE_USERS=""; IGNORE_NETS=""
  LOG_FILE=/var/log/ssh-notify.log
  if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
    echo "Найден $CONF (URL: ${GOTIFY_URL:-—}). Enter — оставить текущее значение."
  fi

  local in_url in_token in_geo in_tty in_close in_iu in_in in_log
  in_url=$(ask "URL Gotify [${GOTIFY_URL:-https://gotify.example.com}]: ")
  # Токен не эхоится: установка часто идёт в сессии, которая пишется в скроллбэк.
  in_token=$(ask "Application-токен [${GOTIFY_TOKEN:+сохранён, Enter — оставить}]: " silent)
  in_geo=$(ask   "Определять гео через ipinfo.io? [$([ "$GEO_LOOKUP" = 1 ] && echo 'Y/n' || echo 'y/N')]: ")
  in_tty=$(ask   "Только интерактивные сессии, без sftp/rsync? [$([ "$REQUIRE_TTY" = 1 ] && echo 'Y/n' || echo 'y/N')]: ")
  in_close=$(ask "Уведомлять о выходе? [$([ "$NOTIFY_CLOSE" = 1 ] && echo 'Y/n' || echo 'y/N')]: ")
  echo "Списки-исключения: шаблоны через пробел, например 'backup rsync-*' и '10.* 192.168.*'."
  in_iu=$(ask "Игнорировать пользователей [${IGNORE_USERS:-нет}]: ")
  in_in=$(ask "Игнорировать адреса [${IGNORE_NETS:-нет}]: ")
  in_log=$(ask "Файл лога, 'нет' чтобы выключить [${LOG_FILE:-нет}]: ")

  GOTIFY_URL="${in_url:-$GOTIFY_URL}"
  GOTIFY_TOKEN="${in_token:-$GOTIFY_TOKEN}"
  GOTIFY_URL="${GOTIFY_URL%/}"
  [ -n "$GOTIFY_URL" ]   || die "URL не задан"
  [ -n "$GOTIFY_TOKEN" ] || die "токен не задан"

  yesno() { case "${1,,}" in y|yes|д|да) echo 1 ;; n|no|н|нет) echo 0 ;; *) echo "$2" ;; esac; }
  GEO_LOOKUP=$(yesno "$in_geo" "$GEO_LOOKUP")
  REQUIRE_TTY=$(yesno "$in_tty" "$REQUIRE_TTY")
  NOTIFY_CLOSE=$(yesno "$in_close" "$NOTIFY_CLOSE")
  IGNORE_USERS="${in_iu:-$IGNORE_USERS}"
  IGNORE_NETS="${in_in:-$IGNORE_NETS}"
  LOG_FILE="${in_log:-$LOG_FILE}"
  case "${LOG_FILE,,}" in нет|no|none|off|-) LOG_FILE="" ;; esac

  # ---------- зависимости ----------
  local missing=()
  local b
  for b in curl jq; do command -v "$b" >/dev/null 2>&1 || missing+=("$b"); done
  [ ${#missing[@]} -gt 0 ] && install_pkgs "${missing[@]}"
  for b in curl jq; do command -v "$b" >/dev/null 2>&1 || die "$b так и не установился"; done

  # ---------- конфиг ----------
  umask 077
  cat > "$CONF" <<EOF
# Настройки уведомлений о SSH-сессиях. Правится вручную,
# перезапуск не нужен — скрипт читает файл на каждый вход.
GOTIFY_URL="$GOTIFY_URL"
GOTIFY_TOKEN="$GOTIFY_TOKEN"

# Гео через ipinfo.io: 1000 запросов в месяц без токена.
GEO_LOOKUP=$GEO_LOOKUP
# 1 — слать только для интерактивных сессий (отсекает sftp, scp, rsync).
REQUIRE_TTY=$REQUIRE_TTY
# 0 — не слать уведомление о выходе.
NOTIFY_CLOSE=$NOTIFY_CLOSE

# Списки исключений: glob-шаблоны через пробел, не CIDR.
IGNORE_USERS="$IGNORE_USERS"
IGNORE_NETS="$IGNORE_NETS"

# Приоритет Gotify: 8 и выше пробивает «не беспокоить» на Android.
PRIORITY_OPEN=${PRIORITY_OPEN:-7}
PRIORITY_CLOSE=${PRIORITY_CLOSE:-3}

# Таймауты в секундах.
HTTP_TIMEOUT=${HTTP_TIMEOUT:-10}
GEO_TIMEOUT=${GEO_TIMEOUT:-5}

# Файл истории входов и выходов, пусто — не вести.
# Смотреть: ssh-notify-ctl logs
LOG_FILE="$LOG_FILE"
EOF
  chown root:root "$CONF"; chmod 600 "$CONF"
  umask 022

  write_main
  install_self
  setup_logrotate "$LOG_FILE"
  rm -f "${LEGACY[@]}"

  # ---------- проверка доставки до правки PAM ----------
  echo "Тестирую отправку..."
  selftest || die "Gotify не ответил. Проверь URL и токен в $CONF, PAM не трогал.
Подробности: journalctl -t ssh-notify -n 20"
  echo "Два тестовых сообщения ушли."

  # ---------- UsePAM ----------
  case "$(usepam_state)" in
    yes) : ;;
    unknown)
      # sshd -T падает и по причинам, не связанным с нашей правкой: нет
      # хост-ключей, sshd не установлен. Трогать конфиг вслепую опаснее,
      # чем не трогать — почти везде UsePAM включён по умолчанию.
      echo "ВНИМАНИЕ: не смог проверить UsePAM (sshd -T не отработал)." >&2
      echo "         Убедись сам, что в sshd_config стоит UsePAM yes." >&2
      ;;
    no)
      echo "UsePAM выключен, включаю."
      local backup targets
      backup=$(mktemp -d /tmp/ssh-notify-sshd-backup.XXXXXX)
      targets=$(grep -rli '^\s*UsePAM' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || true)
      if [ -n "$targets" ]; then
        echo "$targets" | while read -r f; do cp -a "$f" "$backup/$(echo "$f" | tr / _)"; done
        echo "$targets" | xargs -r sed -i 's/^\s*UsePAM.*/UsePAM yes/'
      else
        cp -a /etc/ssh/sshd_config "$backup/_etc_ssh_sshd_config"
        echo 'UsePAM yes' >> /etc/ssh/sshd_config
      fi
      if sshd -t 2>"$backup/err"; then
        rm -rf "$backup"
        reload_sshd
      else
        # Откатываем свою правку, прежде чем ругаться.
        local b orig
        for b in "$backup"/_*; do
          [ -e "$b" ] || continue
          orig=$(basename "$b" | tr _ /)
          cp -a "$b" "$orig"
        done
        echo "sshd -t не прошёл, правку UsePAM откатил. Вывод sshd:" >&2
        cat "$backup/err" >&2
        rm -rf "$backup"
        die "включи UsePAM yes вручную и запусти ${0##*/} install ещё раз"
      fi
      ;;
  esac

  # ---------- PAM ----------
  if grep -q 'ssh-notify-wrap' "$PAMFILE"; then
    # Путь к обёртке мог смениться при обновлении со старой версии.
    sed -i "\|ssh-notify-wrap|c\\$PAMLINE" "$PAMFILE"
    info "строка в $PAMFILE обновлена"
  else
    cp "$PAMFILE" "$PAMFILE.bak.$(date +%s)"
    echo "$PAMLINE" >> "$PAMFILE"
    info "строка добавлена в $PAMFILE (бэкап рядом)"
  fi

  cat <<MSG

Готово.

НЕ ЗАКРЫВАЙ эту сессию. Зайди по SSH из другого терминала —
должно прийти уведомление о входе, на exit — о выходе.

  ssh-notify-ctl status      состояние
  ssh-notify-ctl test        проверить отправку
  ssh-notify-ctl logs        история входов и выходов
  ssh-notify-ctl uninstall   удалить

Если что-то не пришло:  journalctl -t ssh-notify -n 20

Если вход сломался, в этой сессии:
  sudo sed -i '/ssh-notify-wrap/d' $PAMFILE
MSG
}

# ---------- разбор аргументов ----------
CMD="${1:-install}"

# Имя команды проверяем до root: за опечатку просить sudo невежливо.
case "$CMD" in
  help|--help|-h)    usage; exit 0 ;;
  version|--version) echo "ssh-notify-ctl $VERSION"; exit 0 ;;
  logs|--logs|log|--log)
    # Справка по logs — тоже без root.
    case "${2:-}" in -h|--help) log_usage; exit 0 ;; esac
    ;;
  install|--install|test|--test|status|--status|uninstall|--uninstall|remove|purge) : ;;
  *) die "неизвестная команда: $CMD (см. ${0##*/} help)" ;;
esac

[ "$(id -u)" -eq 0 ] || die "нужен root: sudo ${0##*/} $CMD"

case "$CMD" in
  install|--install)                  cmd_install ;;
  test|--test)                        cmd_test ;;
  status|--status)                    cmd_status ;;
  logs|--logs|log|--log)              shift; cmd_log "$@" ;;
  uninstall|--uninstall|remove|purge) cmd_uninstall "${2:-}" ;;
esac
