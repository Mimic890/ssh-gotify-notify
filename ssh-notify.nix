{ config, lib, pkgs, ... }:

let
  cfg = config.services.sshNotify;

  runtimePath = lib.makeBinPath (with pkgs; [
    curl jq coreutils gnugrep gnused gawk findutils systemd procps glibc util-linux
  ]);

  bool = b: if b then "1" else "0";

  # Настройки едут отдельным файлом, а не запекаются в скрипт: так тело
  # скрипта совпадает с ssh-notify.sh один в один и не требует пересборки
  # на каждое изменение опции.
  confFile = pkgs.writeText "ssh-notify.conf" ''
    GOTIFY_URL="${lib.removeSuffix "/" cfg.url}"
    GOTIFY_TOKEN="${cfg.token}"
    GOTIFY_TOKEN_FILE="${cfg.tokenFile}"
    GEO_LOOKUP=${bool cfg.geoLookup}
    REQUIRE_TTY=${bool cfg.requireTty}
    NOTIFY_CLOSE=${bool cfg.notifyClose}
    IGNORE_USERS="${lib.concatStringsSep " " cfg.ignoreUsers}"
    IGNORE_NETS="${lib.concatStringsSep " " cfg.ignoreNets}"
    IGNORE_PAIRS="${lib.concatStringsSep " " cfg.ignorePairs}"
    PRIORITY_OPEN=${toString cfg.priorityOpen}
    PRIORITY_CLOSE=${toString cfg.priorityClose}
    HTTP_TIMEOUT=${toString cfg.httpTimeout}
    GEO_TIMEOUT=${toString cfg.geoTimeout}
    LOG_FILE="${cfg.logFile}"
  '';

  # Тело скрипта вшито буквально (см. tools/sync-embedded.sh), а не через
  # readFile ./ssh-notify.sh: модуль должен ставиться одним файлом, без
  # соседнего .sh рядом — иначе он теряется при копировании в /etc/nixos
  # и, что хуже, молча выпадает из flake-сборки, если не добавлен в git.
  # writeShellScriptBin, а НЕ writeShellApplication: последняя добавляет
  # set -euo pipefail, а скрипт намеренно опирается на ненулевые коды
  # возврата (grep без совпадений, проверки фильтров) и с -e оборвался бы.
  notify = pkgs.writeShellScriptBin "ssh-notify" ''
    export PATH=${runtimePath}:$PATH
    export SSH_NOTIFY_CONF=${confFile}
    # >>> EMBEDDED ssh-notify.sh >>>
    #!/usr/bin/env bash
    # Уведомления о SSH-сессиях в Gotify. Вызывается из pam_exec через обёртку.
    #
    # Это единственный источник правды: ssh-notify.nix читает файл напрямую,
    # install-ssh-notify.sh встраивает его копию (tools/sync-embedded.sh).
    #
    # Ручной запуск для отладки:
    #   PAM_SERVICE=sshd PAM_TYPE=open_session PAM_USER=test \
    #   PAM_RHOST=8.8.8.8 PAM_TTY=pts/0 ssh-notify.sh
    
    CONF="''${SSH_NOTIFY_CONF:-/etc/ssh-notify.conf}"
    STATE_DIR="''${SSH_NOTIFY_STATE:-/run/ssh-notify}"
    
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
    IGNORE_PAIRS=""
    HTTP_TIMEOUT=10
    GEO_TIMEOUT=5
    LOG_FILE=/var/log/ssh-notify.log
    
    # shellcheck source=/dev/null
    if ! . "$CONF" 2>/dev/null; then
      warn "не читается $CONF, уведомление пропущено"
      exit 0
    fi
    
    [ "''${PAM_SERVICE:-}" = "sshd" ] || exit 0
    
    if [ -n "$GOTIFY_TOKEN_FILE" ]; then
      GOTIFY_TOKEN="$(cat "$GOTIFY_TOKEN_FILE" 2>/dev/null)"
    fi
    GOTIFY_URL="''${GOTIFY_URL%/}"
    
    if [ -z "$GOTIFY_URL" ] || [ -z "$GOTIFY_TOKEN" ]; then
      warn "не задан URL или токен в $CONF, уведомление пропущено"
      exit 0
    fi
    
    # Приоритет уходит в JSON как число: пустое или мусорное значение сделало бы
    # тело запроса невалидным, а Gotify ответил бы 400.
    is_num() { case "$1" in '''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
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
    
    [ "$REQUIRE_TTY" = "1" ] && [ -z "''${PAM_TTY:-}" ] && exit 0
    
    if [ -n "$IGNORE_USERS" ] && matches "''${PAM_USER:-}" "$IGNORE_USERS"; then
      exit 0
    fi
    if [ -n "$IGNORE_NETS" ] && matches "''${PAM_RHOST:-}" "$IGNORE_NETS"; then
      exit 0
    fi
    
    # Точечные исключения "пользователь@адрес": тот же пользователь с другого
    # адреса или другой пользователь с того же адреса по-прежнему уведомляют.
    if [ -n "$IGNORE_PAIRS" ]; then
      for pair in $IGNORE_PAIRS; do
        upat="''${pair%%@*}"
        ipat="''${pair#*@}"
        if matches "''${PAM_USER:-}" "$upat" && matches "''${PAM_RHOST:-}" "$ipat"; then
          exit 0
        fi
      done
    fi
    
    # ---------- состояние ----------
    mkdir -p "$STATE_DIR" 2>/dev/null
    chmod 700 "$STATE_DIR" 2>/dev/null
    # Сессии, которые не закрылись штатно (паника, kill -9), оставляют файлы навсегда.
    find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
    
    KEY="$STATE_DIR/''${SSH_SESSION_KEY:-$PPID}"
    
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
      log "$(printf '%s ' "$type"; kv user "''${PAM_USER:-}"; kv rhost "''${PAM_RHOST:-}"; \
             printf '%s' "$extra"; kv delivered "$delivered")"
    
      [ -n "$LOG_FILE" ] || return 0
      ensure_log_file || { warn "не могу писать в $LOG_FILE"; return 0; }
      # flock, чтобы одновременные сессии не перемешали свои блоки.
      {
        flock 9 2>/dev/null || true
        printf '=== %s · %s · %s · %s%s ===\n%s\n\n' \
          "$ts" "$label" "''${PAM_USER:-—}" "''${PAM_RHOST:-—}" "$status" "$message" >&9
      } 9>>"$LOG_FILE"
    }
    
    # ---------- вспомогательное ----------
    short_host() {
      local h
      h=$(hostname -s 2>/dev/null) || h=$(uname -n)
      printf '%s' "''${h%%.*}"
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
      user=$(re_escape "''${PAM_USER:-}")
      host=$(re_escape "''${PAM_RHOST:-}")
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
    
    case "''${PAM_TYPE:-}" in
      open_session)
        date +%s > "$KEY"
    
        GEO=""
        if [ "$GEO_LOOKUP" = "1" ] && is_public_ip "''${PAM_RHOST:-}"; then
          GEO=$(curl -fsS --max-time "$GEO_TIMEOUT" "https://ipinfo.io/$PAM_RHOST/json" 2>/dev/null \
                | jq -r '[.city, .region, .country, .org] | map(select(.)) | join(", ")' 2>/dev/null)
        fi
    
        RDNS=""
        if [ -n "''${PAM_RHOST:-}" ]; then
          RDNS=$(getent hosts "$PAM_RHOST" 2>/dev/null | awk '{print $2}')
        fi
    
        METHOD=$(auth_method)
    
        MESSAGE="Пользователь: ''${PAM_USER:-—}
    IP:           ''${PAM_RHOST:-—}
    rDNS:         ''${RDNS:-—}
    Гео:          ''${GEO:-—}
    Метод:        ''${METHOD:-—}
    TTY:          ''${PAM_TTY:-—}
    Время:        $EVENT_TS
    Uptime:       $(uptime -p 2>/dev/null || echo '—')"
    
        DELIVERED=yes
        send "SSH вход: ''${PAM_USER:-?}@$HOSTNAME_S" "$MESSAGE" "$PRIORITY_OPEN" \
          || { DELIVERED=no; RC=1; }
        record open "$MESSAGE" "$DELIVERED" \
          "$(kv rdns "$RDNS"; kv geo "$GEO"; kv method "$METHOD"; kv tty "''${PAM_TTY:-}")"
        ;;
    
      close_session)
        DUR="неизвестно"
        if [ -f "$KEY" ]; then
          START=$(cat "$KEY"); rm -f "$KEY"
          if is_num "$START"; then
            DUR=$(fmt_duration $(( $(date +%s) - START )))
          fi
        fi
    
        MESSAGE="Пользователь: ''${PAM_USER:-—}
    IP:           ''${PAM_RHOST:-—}
    Длительность: $DUR
    Время:        $EVENT_TS"
    
        # NOTIFY_CLOSE=0 отключает уведомление, а не историю: в лог пишем всё равно.
        if [ "$NOTIFY_CLOSE" = "1" ]; then
          DELIVERED=yes
          send "SSH выход: ''${PAM_USER:-?}@$HOSTNAME_S" "$MESSAGE" "$PRIORITY_CLOSE" \
            || { DELIVERED=no; RC=1; }
        else
          DELIVERED=off
        fi
        record close "$MESSAGE" "$DELIVERED" "$(kv duration "$DUR")"
        ;;
    esac
    
    exit "$RC"
    # <<< EMBEDDED ssh-notify.sh <<<
  '';

  # pam_exec синхронный: без фона недоступный Gotify задержит логин
  # на таймаут curl.
  wrapper = pkgs.writeShellScriptBin "ssh-notify-wrap" ''
    export SSH_SESSION_KEY="$PPID"
    ${pkgs.util-linux}/bin/setsid ${notify}/bin/ssh-notify </dev/null >/dev/null 2>&1 &
    exit 0
  '';

  # Диагностическая команда для NixOS — install-ssh-notify.sh сюда не ставится
  # (система декларативная, устанавливать нечего), но проверить статус,
  # отправить тестовое сообщение и посмотреть историю входов нужно так же
  # удобно, как через ssh-notify на Debian/Ubuntu. Обновляется не сама через
  # сеть, а через nixos-rebuild — команды update здесь нет, см. help.
  ctl = pkgs.writeShellScriptBin "ssh-notify" ''
    export PATH=${runtimePath}:$PATH
    set -u

    VERSION_NIX="модуль NixOS"
    LOG_FILE="${cfg.logFile}"

    usage() {
      cat <<'USAGE'
    ssh-notify — диагностика ssh-notify (настройка через services.sshNotify в NixOS-конфиге)

      ssh-notify           статус и общая информация (без аргументов — то же самое)
      ssh-notify status    текущее состояние
      ssh-notify test      отправить тестовые сообщения о входе и выходе
      ssh-notify logs      история входов и выходов (logs --help — опции)
      ssh-notify help      эта справка

    Обновление — через nixos-rebuild (пересобери конфиг с новым ssh-notify.nix).
    USAGE
    }

    cmd_info() {
      usage
      echo
      cmd_status
    }

    cmd_status() {
      local c_ok='' c_bad='' c_dim='' c_bold='' c_reset=''
      if [ -t 1 ] && [ -z "''${NO_COLOR:-}" ]; then
        c_ok=$'\033[1;32m'; c_bad=$'\033[1;31m'; c_dim=$'\033[2m'
        c_bold=$'\033[1m'; c_reset=$'\033[0m'
      fi
      row() { printf '  %s%s:%s %s\n' "$c_dim" "$1" "$c_reset" "$2"; }
      onoff() { [ "$1" = "1" ] && printf '%sвкл%s' "$c_ok" "$c_reset" || printf '%sвыкл%s' "$c_dim" "$c_reset"; }

      echo "''${c_bold}ssh-notify ($VERSION_NIX)''${c_reset}"
      echo
      row "Скрипт"  "${notify}/bin/ssh-notify"
      row "Обёртка" "${wrapper}/bin/ssh-notify-wrap"
      row "Конфиг"  "${confFile}"
      echo

      local pam_state
      if grep -q 'ssh-notify-wrap' /etc/pam.d/sshd 2>/dev/null; then
        pam_state="''${c_ok}подключено''${c_reset}"
      else
        pam_state="''${c_bad}НЕ подключено''${c_reset}"
      fi
      local usepam_c
      if out=$(sshd -T 2>/dev/null); then
        if printf '%s' "$out" | grep -qi '^usepam yes'; then
          usepam_c="''${c_ok}yes''${c_reset}"
        else
          usepam_c="''${c_bad}no''${c_reset}"
        fi
      else
        usepam_c="''${c_dim}неизвестно''${c_reset}"
      fi
      row "PAM"    "$pam_state    UsePAM $usepam_c"
      row "Сессии" "$(find /run/ssh-notify -maxdepth 1 -type f 2>/dev/null | wc -l) активных"

      local today_users now_users
      today_users=$(last -s today 2>/dev/null | awk '$1!="" && $1!="wtmp" && $1!="reboot"{print $1}' | sort -u | paste -sd' ' -) || true
      now_users=$(who 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' -) || true
      row "Сегодня" "''${today_users:-—}"
      row "Сейчас"  "''${now_users:-—}"

      if [ -n "$LOG_FILE" ]; then
        row "Лог" "$LOG_FILE ($(grep -c '^=== ' "$LOG_FILE" 2>/dev/null || echo 0) записей)"
      else
        row "Лог" "выключен"
      fi
      echo

      row "Gotify"     "${cfg.url}"
      row "Гео"        "$(onoff ${bool cfg.geoLookup})"
      row "Только TTY" "$(onoff ${bool cfg.requireTty})"
      row "О выходе"   "$(onoff ${bool cfg.notifyClose})"
      echo

      if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo "''${c_bold}Последние события''${c_reset}"
        grep '^=== ' "$LOG_FILE" | tail -3 | while IFS= read -r line; do
          local c="$c_reset"
          case "$line" in
            *' · вход · '*)    c="$c_ok" ;;
            *'НЕ ДОСТАВЛЕНО'*) c="$c_bad" ;;
          esac
          printf '  %s%s%s\n' "$c" "$(printf '%s' "$line" | sed 's/^=== //; s/ ===$//')" "$c_reset"
        done
        echo "  ''${c_dim}(полная история: ssh-notify logs)''${c_reset}"
      fi
    }

    cmd_test() {
      PAM_SERVICE=sshd PAM_TYPE=open_session PAM_USER=test PAM_RHOST=8.8.8.8 PAM_TTY=pts/0 \
        ${notify}/bin/ssh-notify \
        || { echo "вход: Gotify не ответил, смотри journalctl -t ssh-notify -n 20" >&2; exit 1; }
      sleep 1
      PAM_SERVICE=sshd PAM_TYPE=close_session PAM_USER=test PAM_RHOST=8.8.8.8 PAM_TTY=pts/0 \
        ${notify}/bin/ssh-notify \
        || { echo "выход: Gotify не ответил" >&2; exit 1; }
      echo "Два тестовых сообщения ушли."
    }

    log_usage() {
      cat <<'USAGE'
    ssh-notify logs [опции] — история входов и выходов

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
          --no-color    без подсветки

    Примеры:
      ssh-notify logs -n 5
      ssh-notify logs -f
      ssh-notify logs -u alice --since today
    USAGE
    }

    # Записи разделены пустой строкой, awk читает их построчно и отдаёт по \n\n.
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
    }

    cmd_log() {
      local n=20 follow=0 f_user="" f_ip="" f_type="" f_failed="" f_grep="" since=""
      local stats=0 color=auto

      while [ $# -gt 0 ]; do
        case "$1" in
          -n|--lines)  n="''${2:-20}"; shift 2 ;;
          -a|--all)    n=0; shift ;;
          -f|--follow) follow=1; shift ;;
          -u|--user)   f_user="''${2:-}"; shift 2 ;;
          -i|--ip)     f_ip="''${2:-}"; shift 2 ;;
          --open)      f_type="вход"; shift ;;
          --close)     f_type="выход"; shift ;;
          --failed)    f_failed=1; shift ;;
          -g|--grep)   f_grep="''${2:-}"; shift 2 ;;
          --since)     since="''${2:-}"; shift 2 ;;
          --stats)     stats=1; shift ;;
          --no-color)  color=never; shift ;;
          -h|--help)   log_usage; return 0 ;;
          *) echo "неизвестная опция для logs: $1 (см. ssh-notify logs --help)" >&2; exit 1 ;;
        esac
      done

      [ -n "$LOG_FILE" ] || { echo "лог в файл выключен (logFile пуст в конфиге)" >&2; exit 1; }
      [ -f "$LOG_FILE" ] || { echo "Записей пока нет: $LOG_FILE не создан."; return 0; }

      local since_norm=""
      if [ -n "$since" ]; then
        case "''${since,,}" in
          today|сегодня)   since_norm=$(date -d 'today 00:00' '+%F %T') ;;
          yesterday|вчера) since_norm=$(date -d 'yesterday 00:00' '+%F %T') ;;
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            since_norm=$(date -d "$since 00:00" '+%F %T' 2>/dev/null) \
              || { echo "не понял дату: $since" >&2; exit 1; } ;;
          *) since_norm=$(date -d "$since" '+%F %T' 2>/dev/null) \
              || { echo "не понял дату: $since" >&2; exit 1; } ;;
        esac
      fi

      [ "$stats" = "1" ] && { log_stats "$LOG_FILE"; return 0; }

      local use_color=0
      case "$color" in
        never) use_color=0 ;;
        *) { [ -t 1 ] && [ -z "''${NO_COLOR:-}" ]; } && use_color=1 ;;
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
          | awk "''${awkargs[@]}" -v last=0 -v stream=1 "$LOG_AWK"
      else
        awk "''${awkargs[@]}" -v "last=$n" -v stream=0 "$LOG_AWK" "$LOG_FILE"
      fi
    }

    CMD="''${1:-info}"
    case "$CMD" in
      info)            cmd_info ;;
      status|--status) cmd_status ;;
      test|--test)     cmd_test ;;
      logs|--logs|log|--log) shift; cmd_log "$@" ;;
      help|--help|-h)  usage ;;
      *) echo "неизвестная команда: $CMD (см. ssh-notify help)" >&2; exit 1 ;;
    esac
  '';
in
{
  options.services.sshNotify = {
    enable = lib.mkEnableOption "уведомления о SSH-сессиях в Gotify";

    url = lib.mkOption {
      type = lib.types.str;
      example = "https://go.example.ru";
      description = "Базовый URL Gotify. Завершающий слэш убирается сам.";
    };

    token = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "AgNGgB5xE.sdkVy1O";
      description = ''
        Application-токен Gotify прямым текстом. Проще всего для быстрой
        настройки, но попадает в /nix/store и в конфиг в открытом виде,
        читаемые любым пользователем системы. Для секрета, которым дорожишь,
        используй `tokenFile` — если задано и то, и другое, побеждает файл.
      '';
    };

    tokenFile = lib.mkOption {
      # Именно str, а не path: literal-путь вида ./token Nix скопировал бы
      # в /nix/store, читаемый любым пользователем системы.
      type = lib.types.str;
      default = "";
      example = "/run/secrets/gotify-ssh-token";
      description = ''
        Путь к файлу с application-токеном Gotify — он читается в момент
        отправки, а не запекается в /nix/store. Передавай путь строкой
        (sops-nix, agenix), а не literal-путь. Имеет приоритет над `token`.
      '';
    };

    geoLookup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Определять город и провайдера через ipinfo.io (1000 запросов в месяц без токена). Приватные адреса не запрашиваются.";
    };

    requireTty = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Слать только для интерактивных сессий — отсекает sftp, scp и rsync.";
    };

    notifyClose = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Слать уведомление о завершении сессии с её длительностью.";
    };

    ignoreUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "backup" "rsync-*" ];
      description = "Не уведомлять об этих пользователях. Элементы — glob-шаблоны.";
    };

    ignoreNets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.*" "192.168.*" "203.0.113.5" ];
      description = "Не уведомлять об этих адресах. Элементы — glob-шаблоны, не CIDR.";
    };

    ignorePairs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "admin@192.168.1.10" "admin@10.0.0.*" ];
      description = ''
        Точечные исключения "пользователь@адрес": не уведомлять только когда
        совпали оба условия. Тот же пользователь с другого адреса, или другой
        пользователь с того же адреса, всё равно уведомит.
      '';
    };

    priorityOpen = lib.mkOption {
      type = lib.types.int;
      default = 7;
      description = "Приоритет уведомления о входе. 8 и выше пробивает «не беспокоить» на Android.";
    };

    priorityClose = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Приоритет уведомления о выходе.";
    };

    httpTimeout = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Таймаут запроса к Gotify, секунды.";
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/ssh-notify.log";
      example = "";
      description = ''
        Файл истории входов и выходов: тот же блок, что уходит в Gotify,
        пишется независимо от успеха доставки. Пустая строка — не вести.
        Ротация настраивается автоматически, пока включён logrotate.
      '';
    };

    geoTimeout = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Таймаут запроса к ipinfo.io, секунды.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.token != "" || cfg.tokenFile != "";
        message = "services.sshNotify: задай token или tokenFile";
      }
    ];

    # В systemPackages кладём только диагностическую команду ctl (bin/ssh-notify).
    # Сам воркер (notify) туда не идёт, хоть и называется так же изнутри store —
    # PAM хватает store-пути, а в PATH он оказался бы только у всех пользователей
    # системы без всякой пользы.
    environment.systemPackages = [ ctl ];

    services.openssh.settings.UsePAM = true;

    services.logrotate.settings.ssh-notify = lib.mkIf (cfg.logFile != "") {
      files = cfg.logFile;
      frequency = "weekly";
      rotate = 8;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
      create = "0640 root adm";
    };

    security.pam.services.sshd.rules.session.ssh-notify = {
      control = "optional";
      modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
      args = [ "quiet" "${wrapper}/bin/ssh-notify-wrap" ];
      order = 20000; # после штатных session-модулей
    };
  };
}
