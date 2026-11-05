#!/bin/bash
#
# update_cell_conf.sh — смена management-сети (eth0), ILOM, DNS/NTP и таймзоны
# в XML-конфигурациях ячеек Exadata по базе Oracle OneCommand preconf (R3).
#
# Вход:  preconf CSV (по умолчанию preconf.csv) и каталог
#        исходных конфигов (по умолчанию cell_conf/).
# Выход: cell_conf/cell_<hostname>_new.conf — исходные *.conf не изменяются.
#
# Зависимости: только bash + awk (POSIX-совместимый: gawk, mawk, busybox awk).
#
# Запуск без параметров печатает справку и ничего не делает.
# Опция --dry: полный прогон (разбор базы, подмена, самоконтроль), но файлы
# *_new.conf не записываются.
#
# Код возврата: 0 — ошибок нет (пропуск строк dbpp и предупреждения — не ошибки);
#               1 — есть ошибки (валидация CSV, отсутствие тега/блока в конфиге,
#                   непройденный самоконтроль выхода);
#               2 — неверная командная строка (неизвестная опция).

set -u

PROG=$(basename "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

usage() {
  cat <<EOF
Назначение: подмена сетевых полей в cell.conf ячеек по preconf-базе CSV.

Использование:
  $PROG <csv> [conf_dir]        обычный прогон (файлы записываются)
  $PROG -dry [<csv> [conf_dir]] контрольный прогон: всё проверяется,
                                но *_new.conf НЕ записываются
  $PROG --help                  эта справка

Без параметров печатается эта справка и ничего не выполняется.

Опции:
  -dry, --dry   не записывать результат; по каждой строке дополнительно
                сообщается, был бы файл создан или отличается от
                уже существующего

Аргументы:
  csv        база preconf (по умолчанию: $SCRIPT_DIR/preconf.csv)
  conf_dir   каталог исходных конфигов cell_<hostname>.conf
             (по умолчанию: $SCRIPT_DIR/cell_conf)

Выход: conf_dir/cell_<hostname>_new.conf (исходники *.conf только читаются).

Код возврата: 0 — ошибок нет; 1 — были ошибки; 2 — неверная командная строка.
EOF
}

DRY=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -dry|--dry) DRY=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*)
      echo "ERROR: неизвестная опция: $1" >&2
      echo "Справка: $PROG --help" >&2
      exit 2
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# запуск без параметров — только справка
if [ ${#ARGS[@]} -eq 0 ] && [ "$DRY" -eq 0 ]; then
  usage
  exit 0
fi

CSV=${ARGS[0]:-$SCRIPT_DIR/preconf.csv}
CONF_DIR=${ARGS[1]:-$SCRIPT_DIR/cell_conf}

if [ ! -f "$CSV" ]; then
  echo "ERROR: не найден CSV: $CSV" >&2
  exit 1
fi
if [ ! -d "$CONF_DIR" ]; then
  echo "ERROR: не найден каталог конфигов: $CONF_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pass 1: выборка и валидация строк базы.
#
# Формат preconf OneCommand: заголовок (строка 11) описывает только первые 17
# колонок, а строки данных содержат 28 полей (ячейка) / 34 (БД-сервер). Поля
# ILOM-блока заголовком не покрыты, поэтому сопоставление ПОЗИЦИОННОЕ:
#
#   1 hostname | 3 node type | 8 ip | 9 netmask | 10 gateway | 15 nameservers |
#  16 ntps | 17 timezone | 18 маркер "ilom:" | 20 ilom ip | 21 ilom netmask |
#  22 ilom gateway | 23 ilom nameservers | 24 enabled | 25 ilom ntp1 | 26 ilom ntp2
#
# Результат — машиночитаемые строки с маркером в первом поле:
#   ROW/SKIP/ERR/WARN
# ---------------------------------------------------------------------------
AWK_EXTRACT='
function is_ipv4(s,   n,a,i) {
  if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
  n = split(s, a, ".")
  if (n != 4) return 0
  for (i = 1; i <= 4; i++)
    if (length(a[i]) > 3 || a[i] + 0 > 255) return 0
  return 1
}
# список адресов через пробел -> массив out, возвращает число адресов
function plist(s, out,   m, i, k) {
  gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
  if (s == "") return 0
  m = split(s, out, " "); k = 0
  for (i = 1; i <= m; i++) if (out[i] != "") out[++k] = out[i]
  return k
}
function join_comma(out, m,   i, s) {
  s = ""
  for (i = 1; i <= m; i++) s = s (i > 1 ? "," : "") out[i]
  return s
}
function bad_ip(who, v) {
  print "ERR\t" cur "\t" who "=\"" v "\" — не IPv4 (строка " NR ")"
  bad = 1; okrow = 0
}
BEGIN {
  FS = ","
  # множество смежных (корректных) масок /0../32 — для предупреждений
  for (p = 0; p <= 32; p++) {
    s = ""
    for (i = 1; i <= 4; i++) {
      b = p - (i - 1) * 8
      o = (b >= 8) ? 255 : ((b <= 0) ? 0 : 256 - 2 ^ (8 - b))
      s = s (i > 1 ? "." : "") o
    }
    validmask[s] = 1
  }
}
{ sub(/\r$/, "") }                                # допускаем CRLF
/^[ \t]*$/ { next }                               # файл "двухстрочный" — пусто
/^#/ { next }                                     # комментарии формата
$1 == "hostname" { next }                         # строка заголовка
$1 == "Cell" { next }                             # сигнатура формата
$1 == "" { next }                                 # терминатор из одних запятых
{
  if ($3 != "cell" && $3 != "dbpp") next          # прочие строки preconf
  cur = ($1 == "" ? "строка " NR : $1)
  if ($3 == "dbpp") {
    print "SKIP\t" $1 "\tnode type=dbpp (не ячейка, cell.conf не обрабатывается)"
    next
  }
  if (NF < 28) {
    print "ERR\t" $1 "\tстрока " NR ": обрезана, полей " NF " (нужно >= 28)"
    bad = 1; nrow++
    next
  }
  if ($18 != "ilom:") {
    print "ERR\t" $1 "\tстрока " NR ": сдвиг полей, поле 18 = \"" $18 "\" вместо \"ilom:\""
    bad = 1; nrow++
    next
  }
  nrow++; okrow = 1
  if (!is_ipv4($8))  bad_ip("ip(eth0)", $8)
  if (!is_ipv4($9))  bad_ip("netmask(eth0)", $9)
  if (!is_ipv4($10)) bad_ip("gateway(eth0)", $10)
  if (!is_ipv4($20)) bad_ip("ilom ip", $20)
  if (!is_ipv4($21)) bad_ip("ilom netmask", $21)
  if (!is_ipv4($22)) bad_ip("ilom gateway", $22)
  if ($17 == "" || $17 ~ /[ \t]/) {
    print "ERR\t" cur "\ttimezone=\"" $17 "\" — пусто или с пробелом (строка " NR ")"
    bad = 1; okrow = 0
  }
  nd = plist($15, D); nn = plist($16, N); ni = plist($23, DI)
  if (nd == 0) { print "ERR\t" cur "\tnameservers пуст (строка " NR ")"; bad = 1; okrow = 0 }
  if (nn == 0) { print "ERR\t" cur "\tntps пуст (строка " NR ")"; bad = 1; okrow = 0 }
  if (ni == 0) { print "ERR\t" cur "\tilom nameservers пуст (строка " NR ")"; bad = 1; okrow = 0 }
  if (!okrow) next
  for (i = 1; i <= nd; i++) if (!is_ipv4(D[i])) bad_ip("nameservers[" i "]", D[i])
  for (i = 1; i <= nn; i++) if (!is_ipv4(N[i])) bad_ip("ntps[" i "]", N[i])
  for (i = 1; i <= ni; i++) if (!is_ipv4(DI[i])) bad_ip("ilom nameservers[" i "]", DI[i])
  if (!okrow) next
  i1 = $25; i2 = ($26 != "" ? $26 : $25)
  if (!is_ipv4(i1)) bad_ip("ilom ntp1", i1)
  if (!is_ipv4(i2)) bad_ip("ilom ntp2", i2)
  if (!okrow) next
  if (!($9 in validmask))
    print "WARN\t" $1 ": netmask(eth0) " $9 " — несмежная маска, пишется как в CSV"
  if (!($21 in validmask))
    print "WARN\t" $1 ": ilom netmask " $21 " — несмежная маска, пишется как в CSV"
  if (nd == 1) print "WARN\t" $1 ": nameservers — 1 адрес, второй тег получает тот же"
  if (nn == 1) print "WARN\t" $1 ": ntps — 1 адрес, второй тег получает тот же"
  if ($26 == "") print "WARN\t" $1 ": ilom ntp2 пуст, берётся ilom ntp1"
  print "ROW\t" $1 "\t" $8 "\t" $9 "\t" $10 "\t" D[1] "\t" (nd >= 2 ? D[2] : D[1]) \
        "\t" N[1] "\t" (nn >= 2 ? N[2] : N[1]) "\t" $17 \
        "\t" $20 "\t" $21 "\t" $22 "\t" join_comma(DI, ni) "\t" i1 "\t" i2
}
END {
  if (nrow == 0) { print "ERR\t-\tв базе нет ни одной строки ячейки (node type=cell)"; bad = 1 }
  exit (bad ? 1 : 0)
}
'

# ---------------------------------------------------------------------------
# Pass 2: подмена значений в одном конфиге за один проход.
#
# Блоки <Interfaces> буферизуются до </Interfaces>: теги в конфиге отсортированы
# по алфавиту, поэтому <IP_address> стоит раньше <Name>eth0</Name> и по блоку
# нужно сначала посмотреть целиком. Подмена внутри блока с <Name>eth0</Name> —
# иначе задело бы адреса приватных re0/re1.
# ---------------------------------------------------------------------------
AWK_SUBST='
function setv(line, tag, val,   open, cl, s, t, e) {
  open = "<" tag ">"; cl = "</" tag ">"
  s = index(line, open); if (s == 0) return line
  t = substr(line, s + length(open))
  e = index(t, cl); if (e == 0) return line
  return substr(line, 1, s + length(open) - 1) val cl substr(t, e + length(cl))
}
# Окончание строки (CRLF или LF) запоминается в глобальной EOL и возвращается при
# печати: подмена меняет только значения тегов, формат переводов строк сохраняется.
function chopeol(s) {
  EOL = ""
  if (sub(/\r$/, "", s)) EOL = "\r"
  return s
}
function flushblk(   i, iseth) {
  iseth = 0
  for (i = 1; i <= nblk; i++) if (blk[i] ~ /<Name>eth0<\/Name>/) iseth = 1
  if (iseth) {
    neth++
    for (i = 1; i <= nblk; i++) {
      if      (blk[i] ~ /^[ \t]*<Gateway>/)    blk[i] = setv(blk[i], "Gateway", EGW)
      else if (blk[i] ~ /^[ \t]*<IP_address>/) blk[i] = setv(blk[i], "IP_address", EIP)
      else if (blk[i] ~ /^[ \t]*<Netmask>/)    blk[i] = setv(blk[i], "Netmask", ENM)
    }
  }
  for (i = 1; i <= nblk; i++) { sub(/\r$/, "", blk[i]); print blk[i] EOL }
  inblk = 0; nblk = 0
}
BEGIN { nerr = 0 }
{
  line = chopeol($0)
  if (inblk) {
    blk[++nblk] = line EOL
    if (line ~ /^[ \t]*<\/Interfaces>/) flushblk()
    next
  }
  if (line ~ /^[ \t]*<Interfaces>/) { inblk = 1; nblk = 1; blk[1] = line EOL; next }
  if (line ~ /^[ \t]*<ilom>/)  { inilom = 1; print line EOL; next }
  if (line ~ /^[ \t]*<\/ilom>/) { inilom = 0; print line EOL; next }
  if (inilom) {
    if      (line ~ /^[ \t]*<ILOM_Gateway>/)             line = setv(line, "ILOM_Gateway", IGW)
    else if (line ~ /^[ \t]*<ILOM_IP_address>/)          line = setv(line, "ILOM_IP_address", IIP)
    else if (line ~ /^[ \t]*<ILOM_Nameserver>/)          line = setv(line, "ILOM_Nameserver", INS)
    else if (line ~ /^[ \t]*<ILOM_Netmask>/)             line = setv(line, "ILOM_Netmask", INM)
    else if (line ~ /^[ \t]*<ILOM_First_NTP_server>/)    line = setv(line, "ILOM_First_NTP_server", INTP1)
    else if (line ~ /^[ \t]*<ILOM_Second_NTP_server>/)   line = setv(line, "ILOM_Second_NTP_server", INTP2)
    else if (line ~ /^[ \t]*<ILOM_Timezone>/)            line = setv(line, "ILOM_Timezone", TZ)
    print line EOL; next
  }
  if (line ~ /^[ \t]*<Nameservers>/) {
    nns++
    if (nns <= 2) line = setv(line, "Nameservers", (nns == 1 ? NS1 : NS2))
    else print "WARN: <Nameservers> #" nns " — третий и далее оставлен без изменений" > "/dev/stderr"
    print line EOL; next
  }
  if (line ~ /^[ \t]*<Ntp_servers>/) {
    nntp++
    if (nntp <= 2) line = setv(line, "Ntp_servers", (nntp == 1 ? NTP1 : NTP2))
    else print "WARN: <Ntp_servers> #" nntp " — третий и далее оставлен без изменений" > "/dev/stderr"
    print line EOL; next
  }
  if (line ~ /^[ \t]*<Timezone>/) { line = setv(line, "Timezone", TZ); print line EOL; next }
  print line EOL
}
END {
  if (inblk)    { print "ERROR: незакрытый <Interfaces>" > "/dev/stderr"; nerr++ }
  if (neth != 1) { print "ERROR: блоков <Interfaces> с <Name>eth0</Name> найдено " neth+0", ожидался 1" > "/dev/stderr"; nerr++ }
  if (nns != 2)  { print "ERROR: тегов <Nameservers> найдено " nns+0", ожидалось 2" > "/dev/stderr"; nerr++ }
  if (nntp != 2) { print "ERROR: тегов <Ntp_servers> найдено " nntp+0", ожидалось 2" > "/dev/stderr"; nerr++ }
  if (inilom)    { print "ERROR: незакрытый <ilom>" > "/dev/stderr"; nerr++ }
  exit (nerr ? 1 : 0)
}
'

# Проверка результата: в выходном файле ровно такая строка с этим тегом/значением.
# CR в конце строки отбрасывается: исходник может быть в формате CRLF.
# Аргументы: файл, тег, ожидаемое значение.
check_tag() {
  awk -v t="$2" -v v="$3" '
    BEGIN { want = "<" t ">" v "</" t ">" }
    { l = $0; sub(/\r$/, "", l); sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l); if (l == want) { f = 1; exit 0 } }
    END { exit (f ? 0 : 1) }
  ' "$1"
}

nproc=0; nskip=0; nerr=0; nwarn=0

# Временный файл текущей строки: при прерывании (Ctrl-C, kill) он удаляется,
# чтобы в cell_conf/ не оставалось *.tmp.<pid> в полузаписанном виде.
CUR_TMP=""
cleanup() {
  [ -n "$CUR_TMP" ] && rm -f -- "$CUR_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Первый проход по базе: ошибки awk (exit!=0) не прерывают обработку —
# валидные строки отрабатывают, ошибки копятся в nerr.
base=$(awk "$AWK_EXTRACT" "$CSV")
extract_rc=$?

# read без завершающего \n отбрасывает последнюю строку — хвост подхватываем
# условием "|| [ -n ... ]". Значения из awk не содержат \t; чтобы лишний
# разделитель не «съедал» поля молча, читаем 16-е поле: непустое — формат бит.
while IFS=$'\t' read -r kind f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 extra || [ -n "${kind:-}" ]; do
  [ -n "${kind:-}" ] || continue
  if [ -n "${extra:-}" ]; then
    echo "ERROR ${f1:-строка}: битый формат строки разбора (лишнее поле \"$extra\")" >&2
    nerr=$((nerr + 1))
    continue
  fi
  case "$kind" in
    WARN)
      echo "WARN  $f1${f2:+ $f2}"
      nwarn=$((nwarn + 1))
      ;;
    SKIP)
      echo "SKIP  $f1: $f2"
      nskip=$((nskip + 1))
      ;;
    ERR)
      echo "ERROR $f1: $f2" >&2
      nerr=$((nerr + 1))
      ;;
    ROW)
      host=$f1; eip=$f2; enm=$f3; egw=$f4
      ns1=$f5; ns2=$f6; ntp1=$f7; ntp2=$f8; tz=$f9
      iip=$f10; inm=$f11; igw=$f12; ins=$f13; intp1=$f14; intp2=$f15
      src="$CONF_DIR/cell_${host}.conf"
      dst="$CONF_DIR/cell_${host}_new.conf"
      if [ ! -f "$src" ]; then
        echo "SKIP  $host: нет исходника $src"
        nskip=$((nskip + 1))
        continue
      fi
      tmp="$dst.tmp.$$"
      CUR_TMP=$tmp
      # 2a: подмена (пишется во временный файл, готовый — перемещается атомарно)
      msgs=$(awk -v EGW="$egw" -v EIP="$eip" -v ENM="$enm" \
                  -v NS1="$ns1" -v NS2="$ns2" -v NTP1="$ntp1" -v NTP2="$ntp2" \
                  -v TZ="$tz" \
                  -v IGW="$igw" -v IIP="$iip" -v INM="$inm" -v INS="$ins" \
                  -v INTP1="$intp1" -v INTP2="$intp2" \
                  "$AWK_SUBST" "$src" 2>&1 >"$tmp")
      rc=$?
      if [ -n "$msgs" ]; then
        while IFS= read -r m; do
          case "$m" in
            ERROR*) echo "ERROR $host: ${m#ERROR: }" >&2; nerr=$((nerr + 1)) ;;
            WARN*)  echo "WARN  $host: ${m#WARN: }" >&2; nwarn=$((nwarn + 1)) ;;
            *)      echo "$m" >&2 ;;
          esac
        done <<<"$msgs"
      fi
      if [ $rc -ne 0 ] || [ ! -s "$tmp" ]; then
        echo "ERROR $host: подмена не выполнена, $dst не записан" >&2
        rm -f "$tmp"; CUR_TMP=""
        [ $rc -eq 0 ] && nerr=$((nerr + 1))
        continue
      fi
      # 2b: структурная целостность — число строк и интерфейсов сохранены.
      # Строки считает awk (NR), а не wc -l: wc -l не видит последнюю строку,
      # если файл не оканчивается \n, и сравнение src/tmp расходилось бы.
      l_src=$(awk 'END{print NR}' "$src"); l_dst=$(awk 'END{print NR}' "$tmp")
      i_src=$(grep -c '<IP_address>' "$src"); i_dst=$(grep -c '<IP_address>' "$tmp")
      if [ "$l_src" != "$l_dst" ] || [ "$i_src" != "$i_dst" ]; then
        echo "ERROR $host: изменилась структура (${l_src}->${l_dst} строк, IP_address ${i_src}->${i_dst})" >&2
        rm -f "$tmp"; CUR_TMP=""; nerr=$((nerr + 1)); continue
      fi
      # 2c: самоконтроль — все подстановки присутствуют в результате
      miss=""
      for spec in "Gateway:$egw" "IP_address:$eip" "Netmask:$enm" \
                  "Nameservers:$ns1" "Nameservers:$ns2" \
                  "Ntp_servers:$ntp1" "Ntp_servers:$ntp2" "Timezone:$tz" \
                  "ILOM_Gateway:$igw" "ILOM_IP_address:$iip" "ILOM_Netmask:$inm" \
                  "ILOM_Nameserver:$ins" "ILOM_First_NTP_server:$intp1" \
                  "ILOM_Second_NTP_server:$intp2" "ILOM_Timezone:$tz"; do
        tag=${spec%%:*}; val=${spec#*:}
        check_tag "$tmp" "$tag" "$val" || miss="$miss $tag"
      done
      if [ -n "$miss" ]; then
        echo "ERROR $host: в результате нет подмен:$miss" >&2
        rm -f "$tmp"; nerr=$((nerr + 1)); continue
      fi
      # dry: проверяем и убираем временный файл, результат не публикуем
      if [ "$DRY" -eq 1 ]; then
        if [ ! -f "$dst" ]; then
          note="будет создан"
        elif cmp -s "$tmp" "$dst"; then
          note="совпадает с существующим"
        else
          note="ОТЛИЧАЕТСЯ от существующего"
        fi
        rm -f "$tmp"; CUR_TMP=""
        echo "DRY   $host -> $dst ($note)"
      else
        mv -f "$tmp" "$dst"; CUR_TMP=""
        echo "OK    $host -> $dst"
      fi
      nproc=$((nproc + 1))
      echo "        eth0: $eip / $enm / gw $egw   dns: $ns1 $ns2   ntp: $ntp1 $ntp2"
      echo "        ilom: $iip / $inm / gw $igw   dns: $ins   ntp: $intp1 $intp2   tz: $tz"
      ;;
  esac
done <<<"$base"

# страховка: awk сообщил о невалидной базе, но ни одна ERR-строка не посчитана
if [ "$extract_rc" -ne 0 ] && [ "$nerr" -eq 0 ]; then
  echo "ERROR: база $CSV распознана с ошибками" >&2
  nerr=$((nerr + 1))
fi

if [ "$DRY" -eq 1 ]; then
  echo "Режим -dry: ничего не записывалось."
  echo "Итого: проверено $nproc, пропущено $nskip, предупреждений $nwarn, ошибок $nerr"
else
  echo "Итого: обработано $nproc, пропущено $nskip, предупреждений $nwarn, ошибок $nerr"
fi
exit $((nerr > 0 ? 1 : 0))
