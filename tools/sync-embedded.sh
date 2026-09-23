#!/usr/bin/env bash
# Вшивает ssh-notify.sh в install-ssh-notify.sh и в ssh-notify.nix между
# маркерами EMBEDDED. Оба должны ставиться одним файлом (установщик качают
# через curl, .nix-модуль не должен требовать соседний .sh), поэтому копия
# скрипта живёт внутри них и обновляется этой командой.
#
#   ./tools/sync-embedded.sh          обновить
#   ./tools/sync-embedded.sh --check  проверить, что копии совпадают (для CI)
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=ssh-notify.sh
BEGIN='EMBEDDED ssh-notify.sh'
MODE="${1:-}"
fail=0

# ---------- install-ssh-notify.sh: bash heredoc, экранирование не нужно ----------
sync_installer() {
  local dst=install-ssh-notify.sh
  local begin="# >>> $BEGIN >>>" end="# <<< $BEGIN <<<"

  grep -qF "$begin" "$dst" || { echo "нет маркера начала в $dst" >&2; exit 1; }
  grep -qF "$end"   "$dst" || { echo "нет маркера конца в $dst"  >&2; exit 1; }
  # Встраиваемый текст не должен содержать терминатор heredoc установщика.
  if grep -qx 'SCRIPT' "$SRC"; then
    echo "в $SRC есть строка 'SCRIPT' — она оборвёт heredoc установщика" >&2; exit 1
  fi

  local tmp; tmp=$(mktemp)
  # Маркеры лежат СНАРУЖИ heredoc, иначе строка-маркер стала бы первой строкой
  # установленного файла и сдвинула шебанг — скрипт перестал бы запускаться.
  awk -v begin="$begin" -v end="$end" -v src="$SRC" '
    index($0, begin) {
      print
      print "  cat > \"$MAIN\" <<'"'"'SCRIPT'"'"'"
      while ((getline line < src) > 0) print line
      print "SCRIPT"
      skip = 1
      next
    }
    index($0, end) { skip = 0 }
    !skip
  ' "$dst" > "$tmp"

  apply_or_check "$dst" "$tmp"
}

# ---------- ssh-notify.nix: индентированная Nix-строка, нужно экранирование ----------
# ${ — начало антикавычки, '' — экранирующий префикс в самой Nix-строке.
# Оба должны быть заэкранированы префиксом '', иначе Nix попытается их
# вычислить как выражение или как служебную последовательность.
sync_nix() {
  local dst=ssh-notify.nix
  local begin="# >>> $BEGIN >>>" end="# <<< $BEGIN <<<"

  grep -qF "$begin" "$dst" || { echo "нет маркера начала в $dst" >&2; exit 1; }
  grep -qF "$end"   "$dst" || { echo "нет маркера конца в $dst"  >&2; exit 1; }

  local tmp; tmp=$(mktemp)
  awk -v begin="$begin" -v end="$end" -v src="$SRC" '
    index($0, begin) {
      print
      while ((getline line < src) > 0) {
        gsub(/'"'"''"'"'/, "'"'"''"'"''"'"'", line)
        gsub(/\$\{/, "'"'"''"'"'${", line)
        print "    " line
      }
      skip = 1
      next
    }
    index($0, end) { skip = 0 }
    !skip
  ' "$dst" > "$tmp"

  apply_or_check "$dst" "$tmp"
}

apply_or_check() {
  local dst="$1" tmp="$2"
  if [ "$MODE" = "--check" ]; then
    if cmp -s "$tmp" "$dst"; then
      echo "встроенная копия в $dst совпадает с $SRC"
    else
      echo "встроенная копия в $dst устарела, запусти ./tools/sync-embedded.sh" >&2
      diff -u "$dst" "$tmp" | head -40 || true
      fail=1
    fi
    rm -f "$tmp"
  else
    cat "$tmp" > "$dst"; rm -f "$tmp"
    echo "встроено $(wc -l < "$SRC") строк из $SRC в $dst"
  fi
}

sync_installer
sync_nix
exit "$fail"
