#!/usr/bin/env bash
# Вшивает ssh-notify.sh в install-ssh-notify.sh между маркерами EMBEDDED.
# Установщик должен оставаться однофайловым (его качают через curl),
# поэтому копия скрипта живёт внутри него и обновляется этой командой.
#
#   ./tools/sync-embedded.sh          обновить
#   ./tools/sync-embedded.sh --check  проверить, что копия совпадает (для CI)
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=ssh-notify.sh
DST=install-ssh-notify.sh
BEGIN='# >>> EMBEDDED ssh-notify.sh >>>'
END='# <<< EMBEDDED ssh-notify.sh <<<'

grep -qF "$BEGIN" "$DST" || { echo "нет маркера начала в $DST" >&2; exit 1; }
grep -qF "$END"   "$DST" || { echo "нет маркера конца в $DST"  >&2; exit 1; }
# Встраиваемый текст не должен содержать терминатор heredoc установщика.
if grep -qx 'SCRIPT' "$SRC"; then
  echo "в $SRC есть строка 'SCRIPT' — она оборвёт heredoc установщика" >&2; exit 1
fi

tmp=$(mktemp)
# Маркеры лежат СНАРУЖИ heredoc, иначе строка-маркер стала бы первой строкой
# установленного файла и сдвинула шебанг — скрипт перестал бы запускаться.
awk -v begin="$BEGIN" -v end="$END" -v src="$SRC" '
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
' "$DST" > "$tmp"

if [ "${1:-}" = "--check" ]; then
  if cmp -s "$tmp" "$DST"; then
    echo "встроенная копия совпадает с $SRC"; rm -f "$tmp"
  else
    echo "встроенная копия устарела, запусти ./tools/sync-embedded.sh" >&2
    diff -u "$DST" "$tmp" | head -40 || true; rm -f "$tmp"; exit 1
  fi
else
  cat "$tmp" > "$DST"; rm -f "$tmp"
  echo "встроено $(wc -l < "$SRC") строк из $SRC в $DST"
fi
