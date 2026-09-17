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
    GOTIFY_TOKEN_FILE="${cfg.tokenFile}"
    GEO_LOOKUP=${bool cfg.geoLookup}
    REQUIRE_TTY=${bool cfg.requireTty}
    NOTIFY_CLOSE=${bool cfg.notifyClose}
    IGNORE_USERS="${lib.concatStringsSep " " cfg.ignoreUsers}"
    IGNORE_NETS="${lib.concatStringsSep " " cfg.ignoreNets}"
    PRIORITY_OPEN=${toString cfg.priorityOpen}
    PRIORITY_CLOSE=${toString cfg.priorityClose}
    HTTP_TIMEOUT=${toString cfg.httpTimeout}
    GEO_TIMEOUT=${toString cfg.geoTimeout}
    LOG_FILE="${cfg.logFile}"
  '';

  # readFile вместо инлайна: в Nix-строке пришлось бы экранировать каждое
  # интерполяцию, а любая ошибка отступа сломала бы heredoc внутри скрипта.
  # writeShellScriptBin, а НЕ writeShellApplication: последняя добавляет
  # set -euo pipefail, а скрипт намеренно опирается на ненулевые коды
  # возврата (grep без совпадений, проверки фильтров) и с -e оборвался бы.
  notify = pkgs.writeShellScriptBin "ssh-notify" ''
    export PATH=${runtimePath}:$PATH
    export SSH_NOTIFY_CONF=${confFile}
    ${builtins.readFile ./ssh-notify.sh}
  '';

  # pam_exec синхронный: без фона недоступный Gotify задержит логин
  # на таймаут curl.
  wrapper = pkgs.writeShellScriptBin "ssh-notify-wrap" ''
    export SSH_SESSION_KEY="$PPID"
    ${pkgs.util-linux}/bin/setsid ${notify}/bin/ssh-notify </dev/null >/dev/null 2>&1 &
    exit 0
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

    tokenFile = lib.mkOption {
      # Именно str, а не path: literal-путь вида ./token Nix скопировал бы
      # в /nix/store, читаемый любым пользователем системы.
      type = lib.types.str;
      example = "/run/secrets/gotify-ssh-token";
      description = ''
        Путь к файлу с application-токеном Gotify — он читается в момент
        отправки. Передавай путь строкой (sops-nix, agenix), а не literal-путь.
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
    # В systemPackages не кладём: PAM хватает store-пути, а так ssh-notify
    # оказался бы в PATH у всех пользователей системы.
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
