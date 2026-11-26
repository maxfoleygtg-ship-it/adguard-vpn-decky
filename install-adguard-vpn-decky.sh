#!/usr/bin/env bash
# =============================================================================
#  AdGuard VPN + плагин Decky — автоустановка одной командой
#  для Bazzite и SteamOS (Steam Deck).
#
#  Запуск (от обычного пользователя, БЕЗ sudo):
#      bash ~/Downloads/install-adguard-vpn-decky.sh [путь/к/adguard-vpn-X.Y.Z.zip] [флаги]
#
#  Флаги:
#      --system=bazzite|steamos   не показывать меню выбора системы
#      --no-sudoers               не создавать правило sudo без пароля
#      --no-decky                 не устанавливать Decky Loader (и не трогать его)
#      --test                     в конце сделать пробное подключение без вопроса
#      --no-test                  не предлагать пробное подключение
#      --uninstall                удалить плагин, правило sudoers и AdGuard VPN CLI
#      --dry-run                  только показать, что будет сделано (ничего не меняет)
#      -h, --help                 эта справка
#
#  Журнал: ~/adguard-vpn-install.log
#  Скрипт можно запускать повторно: уже сделанные шаги пропускаются.
# =============================================================================
set -euo pipefail

PLUGIN_VERSION="1.1.1"
# Публичная ссылка на ZIP плагина (когда появится). Пока пусто — ZIP ищется локально.
PLUGIN_ZIP_URL="${PLUGIN_ZIP_URL:-}"   # [ССЫЛКА НА ZIP]

ADGUARD_INSTALLER_URL="https://raw.githubusercontent.com/AdguardTeam/AdGuardVPNCLI/HEAD/scripts/release/install.sh"
ADGUARD_RELEASES="https://github.com/AdguardTeam/AdGuardVPNCLI/releases"
DECKY_INSTALLER_URL="https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh"

# Переопределения только для тестов (на реальной системе не задавайте)
ETC="${AGV_ETC:-/etc}"
OS_RELEASE="${AGV_OS_RELEASE:-/etc/os-release}"
OPT_CLI="${AGV_OPT_CLI:-/opt/adguardvpn_cli/adguardvpn-cli}"

LOG="${HOME}/adguard-vpn-install.log"
PLUGINS_DIR="${HOME}/homebrew/plugins"
PLUGIN_DIR="${PLUGINS_DIR}/adguard-vpn"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSTEM=""; DO_SUDOERS=1; DO_DECKY=1; DO_TEST="ask"; UNINSTALL=0; DRY=0; ZIP_ARG=""
for a in "$@"; do
  case "$a" in
    --system=*)   SYSTEM="${a#--system=}" ;;
    --no-sudoers) DO_SUDOERS=0 ;;
    --no-decky)   DO_DECKY=0 ;;
    --test)       DO_TEST="yes" ;;
    --no-test)    DO_TEST="no" ;;
    --uninstall)  UNINSTALL=1 ;;
    --dry-run)    DRY=1 ;;
    -h|--help)    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "Неизвестный флаг: $a (см. --help)" >&2; exit 2 ;;
    *)            ZIP_ARG="$a" ;;
  esac
done
case "$SYSTEM" in ""|bazzite|steamos) ;; *) echo "--system: нужно bazzite или steamos" >&2; exit 2 ;; esac

# ---------- оформление ----------
if [ -t 1 ]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; DIM=$'\e[2m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""; DIM=""
fi
STEP=0; STEP_NAME=""
step() { STEP=$((STEP + 1)); STEP_NAME="$1"; printf '\n%s%s[%d] %s%s\n' "$B" "$C" "$STEP" "$1" "$N"; }
ok()   { printf '  %s✔ %s%s\n' "$G" "$*" "$N"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  %s⚠ %s%s\n' "$Y" "$*" "$N"; }
die()  { printf '\n%s✖ Ошибка на шаге «%s»: %s%s\n' "$R" "$STEP_NAME" "$*" "$N" >&2
         printf '  Подробности: %s\n' "$LOG" >&2; exit 1; }
# run: команда, которая что-то меняет (в --dry-run только печатается)
run()  { if [ "$DRY" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$Y" "$N" "$*"; else "$@"; fi; }
# ask "вопрос" "y|n" — ответ по умолчанию по Enter
ask() {
  local q="$1" def="$2" hint ans=""
  if [ "$def" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '  %s %s ' "$q" "$hint"
  read -r ans || ans=""
  ans="${ans:-$def}"
  case "$ans" in [yYдД]*) return 0 ;; *) return 1 ;; esac
}

# ---------- сеть: медленная, но рабочая — не повод сдаваться ----------
# Для маленьких файлов (скрипты, API): ждём соединения 15 сек., всё вместе — до 5 мин., 3 повтора.
CURL_SMALL=(-fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 5 --retry-connrefused)
# Для больших файлов (архив CLI, плагин): до 15 мин., 3 повтора.
CURL_BIG=(-fSL --connect-timeout 15 --max-time 900 --retry 3 --retry-delay 5 --retry-connrefused)
# Доступен ли сайт: только заголовки (HEAD), любой HTTP-ответ = «доступен». 3 попытки.
reachable() {
  local code i
  for i in 1 2 3; do
    code="$(curl -sS -o /dev/null -I -w '%{http_code}' --connect-timeout 10 --max-time 30 "$1" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != 000 ]; then return 0; fi
    [ "$i" = 3 ] || sleep 2
  done
  return 1
}

# ---------- пароль только в терминале ----------
# Некоторые системы задают SUDO_ASKPASS (окно с паролем посреди экрана). Наш sudo спрашивает
# в терминале; для ujust (он вызывает `sudo -A`) подставляем свой askpass, который тоже
# спрашивает в терминале — см. make_tty_askpass.
unset SUDO_ASKPASS
make_tty_askpass() {   # $1 = путь
  cat >"$1" <<'ASK'
#!/bin/sh
# askpass для sudo -A: спросить пароль в этом же терминале, а не окном
exec </dev/tty
printf '%s' "${1:-Пароль: }" >/dev/tty
stty -echo 2>/dev/null
IFS= read -r pw
stty echo 2>/dev/null
printf '\n' >/dev/tty
printf '%s\n' "$pw"
ASK
  chmod 700 "$1"
}

# ---------- журнал ----------
touch "$LOG" 2>/dev/null || LOG="/tmp/adguard-vpn-install-$USER.log"
exec > >(tee -a "$LOG") 2>&1
printf '\n===== %s  %s %s =====\n' "$(date '+%F %T')" "$0" "$*" >>"$LOG"

TMP="$(mktemp -d)"
KEEPALIVE=""
cleanup() {
  if [ -n "$KEEPALIVE" ]; then pkill -P "$KEEPALIVE" 2>/dev/null || true; kill "$KEEPALIVE" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'die "прервано"' INT TERM

# Интерактивная команда прямо в терминал (минуя журнал), чтобы ссылки и запросы были видны сразу
tty_run() {
  if { : >/dev/tty; } 2>/dev/null; then "$@" </dev/tty >/dev/tty 2>&1; else "$@"; fi
}
find_cli() {
  if command -v adguardvpn-cli >/dev/null 2>&1; then command -v adguardvpn-cli
  elif [ -x "$OPT_CLI" ]; then echo "$OPT_CLI"
  elif [ -x "$HOME/.local/bin/adguardvpn-cli" ]; then echo "$HOME/.local/bin/adguardvpn-cli"
  else return 1; fi
}
# Команда CLI без вопросов (stdin = /dev/null) и с ограничением по времени: на медленной сети
# adguardvpn-cli перед каждой командой связывается с серверами AdGuard (30–40 сек. — нормально).
cli_q() { timeout 150 "$CLI" "$@" </dev/null 2>&1; }
sudoers_name() { if [ "$SYSTEM" = steamos ]; then echo "zz-adguardvpn"; else echo "90-adguardvpn"; fi; }
decky_installed() {
  [ -f "$ETC/systemd/system/plugin_loader.service" ] || systemctl list-unit-files plugin_loader.service 2>/dev/null | grep -q plugin_loader
}
restart_decky() {
  if decky_installed || [ "$DRY" = 1 ]; then
    run sudo systemctl restart plugin_loader && ok "Decky перезапущен (plugin_loader)"
  else
    warn "служба plugin_loader не найдена — Decky не установлен?"
  fi
}
fetch_adguard_installer() {   # $1 = куда сохранить
  if curl "${CURL_SMALL[@]}" "$ADGUARD_INSTALLER_URL" -o "$1" 2>/dev/null; then
    info "Установщик AdGuard скачан с raw.githubusercontent.com"
  elif curl "${CURL_SMALL[@]}" "$ADGUARD_RELEASES/latest/download/install.sh" -o "$1"; then
    warn "raw.githubusercontent.com недоступен — установщик взят со страницы релизов GitHub"
  else
    return 1
  fi
  head -n1 "$1" | grep -q '^#!' || return 1
}

# =============================================================================
printf '%s%sAdGuard VPN + Decky — автоустановка (плагин %s)%s\n' "$B" "$G" "$PLUGIN_VERSION" "$N"
[ "$DRY" = 1 ] && warn "РЕЖИМ ПРОВЕРКИ (--dry-run): ничего не меняется"

# ---------- 1. система ----------
step "Проверка системы"
[ "$(id -u)" -ne 0 ] || die "не запускайте через sudo и не от root. Просто: bash $0"
[ "$(uname -m)" = x86_64 ] || die "нужен процессор x86_64, а у вас $(uname -m)"
OS_ID=""; OS_NAME="неизвестно"
if [ -r "$OS_RELEASE" ]; then
  # shellcheck source=/dev/null
  OS_ID="$(. "$OS_RELEASE"; echo "${ID:-}")"
  # shellcheck source=/dev/null
  OS_NAME="$(. "$OS_RELEASE"; echo "${PRETTY_NAME:-${NAME:-?}}")"
fi
case "$OS_ID" in bazzite) DETECTED=bazzite; DEF=1 ;; steamos) DETECTED=steamos; DEF=2 ;; *) DETECTED=""; DEF=1 ;; esac
info "Обнаружено: $OS_NAME"
if [ -z "$SYSTEM" ]; then
  printf '\n  Выберите систему:\n    1) Bazzite\n    2) SteamOS (Steam Deck)\n'
  printf '  Номер [%s, Enter — согласиться]: ' "$DEF"
  read -r choice || choice=""
  case "${choice:-$DEF}" in 1) SYSTEM=bazzite ;; 2) SYSTEM=steamos ;; *) die "нужно ввести 1 или 2" ;; esac
fi
ok "Система: $SYSTEM"
if [ -n "$DETECTED" ] && [ "$DETECTED" != "$SYSTEM" ]; then
  warn "вы выбрали $SYSTEM, а похоже на $DETECTED"
  ask "Продолжить всё равно?" n || die "отменено"
elif [ -z "$DETECTED" ]; then
  warn "это не похоже ни на Bazzite, ни на SteamOS ($OS_NAME)"
  ask "Продолжить на свой риск?" n || die "отменено"
fi
for t in curl python3 sudo tar sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "нет программы «$t»"
done
ok "Пользователь: $USER, домашняя папка: $HOME"
info "Проверяю интернет (github.com, raw.githubusercontent.com)… на медленной сети до 1–2 минут"
if reachable https://github.com; then
  ok "Интернет есть (github.com отвечает)"
  reachable https://raw.githubusercontent.com || warn "raw.githubusercontent.com не отвечает — установщик AdGuard возьму со страницы релизов GitHub"
elif reachable https://raw.githubusercontent.com; then
  warn "github.com не отвечает, но raw.githubusercontent.com доступен — пробую продолжить"
else
  warn "github.com и raw.githubusercontent.com не ответили за 3 попытки."
  info "Если интернет просто медленный — можно продолжить: скачивание ждёт дольше и повторяется."
  ask "Продолжить всё равно?" y || die "отменено. Проверьте интернет и запустите скрипт снова."
fi

# ---------- 2. пароль ----------
step "Пароль администратора (sudo)"
if [ "$SYSTEM" = steamos ]; then
  PW_STATE="$(passwd -S "$USER" 2>/dev/null | awk '{print $2}' || true)"
  if [ "$PW_STATE" = NP ] || [ "$PW_STATE" = L ]; then
    warn "у пользователя $USER нет пароля — на SteamOS так по умолчанию."
    info "Сейчас нужно один раз придумать пароль (он понадобится для sudo)."
    info "Его дважды попросят ввести; символы при вводе не видны — это нормально."
    if [ "$DRY" = 1 ]; then run passwd
    else tty_run passwd || die "пароль не задан (команда passwd)"; fi
    ok "Пароль задан"
  fi
fi
info "Введите пароль вашего пользователя один раз (символы не видны — это нормально)."
if [ "$DRY" = 1 ]; then run sudo -v
else
  sudo -v || die "неверный пароль или sudo недоступен"
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 30; done ) >/dev/null 2>&1 </dev/null &
  KEEPALIVE=$!
fi
ok "Права администратора получены"

# =============================================================================
#  УДАЛЕНИЕ
# =============================================================================
if [ "$UNINSTALL" = 1 ]; then
  step "Удаление плагина AdGuard VPN"
  if CLI="$(find_cli)"; then run "$CLI" disconnect >/dev/null 2>&1 || true; fi
  removed=0
  for d in "$PLUGINS_DIR"/*/; do
    [ -f "${d}plugin.json" ] || continue
    if python3 - "${d}plugin.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])).get("name") in ("AdGuard VPN", "adguard-vpn") else 1)
PY
    then run sudo rm -rf "${d%/}"; ok "удалено: ${d%/}"; removed=1; fi
  done
  [ "$removed" = 1 ] || info "плагин не найден — пропускаю"
  run sudo rm -rf "$HOME/homebrew/settings/adguard-vpn" "$HOME/homebrew/logs/adguard-vpn" "$HOME/homebrew/data/adguard-vpn"
  restart_decky

  step "Удаление правила sudoers"
  for f in "$ETC/sudoers.d/90-adguardvpn" "$ETC/sudoers.d/zz-adguardvpn" "$ETC/atomic-update.conf.d/adguard-vpn.conf"; do
    if sudo test -e "$f"; then run sudo rm -f "$f"; ok "удалено: $f"; fi
  done

  step "Удаление AdGuard VPN CLI"
  if find_cli >/dev/null; then
    fetch_adguard_installer "$TMP/install.sh" || die "не удалось скачать установщик AdGuard для удаления"
    ( cd "$TMP" && run sh "$TMP/install.sh" -v -u -a y ) || die "install.sh -u завершился с ошибкой"
    ok "AdGuard VPN CLI удалён"
  else
    info "AdGuard VPN CLI не установлен — пропускаю"
  fi
  printf '\n%s%sГотово: всё удалено.%s Decky Loader оставлен (удалить: %s).\n' "$B" "$G" "$N" \
    "$( [ "$SYSTEM" = bazzite ] && echo 'ujust setup-decky uninstall' || echo 'установщик с decky.xyz → Uninstall')"
  exit 0
fi

# =============================================================================
#  УСТАНОВКА
# =============================================================================

# ---------- 3. AdGuard VPN CLI ----------
step "AdGuard VPN CLI"
if CLI="$(find_cli)"; then
  ok "уже установлен: $(cli_q --version | head -n1) ($CLI) — пропускаю"
else
  cd "$TMP"
  fetch_adguard_installer "$TMP/install.sh" || die "не удалось скачать официальный установщик AdGuard ни с raw.githubusercontent.com, ни с github.com"
  info "Устанавливаю (ответы на вопросы установщика — автоматически «y»)…"
  if ! run sh "$TMP/install.sh" -v -a y; then
    warn "официальный установщик не смог скачать программу — пробую архив со страницы релизов"
    TAG="$(curl "${CURL_SMALL[@]}" -I -o /dev/null -w '%{url_effective}' "$ADGUARD_RELEASES/latest" | sed 's#.*/tag/##' || true)"
    VER="${TAG#v}"
    case "$TAG" in v[0-9]*) ;; *) die "не удалось узнать последнюю версию на GitHub" ;; esac
    PKG="adguardvpn-cli-${VER}-linux-x86_64.tar.gz"
    curl "${CURL_BIG[@]}" "$ADGUARD_RELEASES/download/$TAG/$PKG" -o "$TMP/$PKG" || die "не удалось скачать $PKG"
    WANT="$(curl "${CURL_SMALL[@]}" "https://api.github.com/repos/AdguardTeam/AdGuardVPNCLI/releases/tags/$TAG" 2>/dev/null \
      | python3 -c 'import json,sys
d=json.load(sys.stdin); n=sys.argv[1]
print(next((a.get("digest","") for a in d.get("assets",[]) if a["name"]==n),"").replace("sha256:",""))' "$PKG" 2>/dev/null || true)"
    HAVE="$(sha256sum "$TMP/$PKG" | cut -d' ' -f1)"
    if [ -n "$WANT" ]; then
      [ "$WANT" = "$HAVE" ] || die "контрольная сумма архива не совпала с GitHub — не устанавливаю"
      ok "SHA256 архива совпадает с GitHub"
    else
      warn "не удалось получить SHA256 с GitHub; SHA256 архива: $HAVE"
    fi
    run sh "$TMP/install.sh" -v -a y -p "$TMP/$PKG" || die "установка из архива не удалась"
  fi
  cd "$HOME"
  hash -r
  if [ "$DRY" = 1 ]; then CLI="adguardvpn-cli"
  else
    CLI="$(find_cli)" || die "после установки команда adguardvpn-cli не найдена"
    ok "установлен: $(cli_q --version | head -n1)"
  fi
fi
# Вопросы первого запуска CLI закрываем сразу и без интерактива: install.sh -a y уже ответил
# на них (post_install -y), а отчёты о сбоях выключаем ради приватности. Делается и для уже
# установленного CLI — повторный запуск безопасен. На медленной сети может занять до минуты.
if [ "$DRY" = 1 ]; then run "$CLI" config set-crash-reporting off
else
  info "Настраиваю adguardvpn-cli (первый запуск; на медленной сети до минуты)…"
  if cli_q config set-crash-reporting off >/dev/null; then info "отправка отчётов о сбоях в AdGuard выключена"
  else warn "не удалось выполнить «adguardvpn-cli config set-crash-reporting off» (не страшно)"; fi
fi

# ---------- 4. sudoers ----------
step "Правило sudo без пароля для AdGuard VPN"
if [ "$DO_SUDOERS" = 0 ]; then
  warn "пропущено (--no-sudoers). Без правила включение VPN из игрового режима может не работать."
else
  SF="$ETC/sudoers.d/$(sudoers_name)"
  RULE="$USER ALL=(ALL) NOPASSWD: ALL"
  if sudo test -f "$SF" && sudo grep -qxF "$RULE" "$SF" 2>/dev/null; then
    ok "правило уже есть: $SF — пропускаю"
  else
    printf '%s\n' "# AdGuard VPN (Decky): adguardvpn-cli вызывает sudo сам, пароль в игровом режиме ввести негде" "$RULE" >"$TMP/rule"
    command -v visudo >/dev/null 2>&1 || [ "$DRY" = 1 ] || die "нет visudo"
    if [ "$DRY" = 1 ]; then run sudo visudo -cf "$TMP/rule"
    else sudo visudo -cf "$TMP/rule" >/dev/null || die "проверка правила (visudo -cf) не прошла — ничего не изменено"; fi
    run sudo install -m 0440 -o root -g root "$TMP/rule" "$SF"
    if [ "$DRY" = 0 ]; then sudo visudo -cf "$SF" >/dev/null || { sudo rm -f "$SF"; die "visudo нашёл ошибку в нашем правиле — правило удалено"; }; fi
    ok "создано: $SF"
  fi
  if [ "$SYSTEM" = steamos ]; then
    KEEP="$ETC/atomic-update.conf.d/adguard-vpn.conf"
    if ! sudo test -f "$KEEP"; then
      run sudo mkdir -p "$ETC/atomic-update.conf.d"
      printf '%s\n' "$SF" >"$TMP/keep"
      run sudo install -m 0644 "$TMP/keep" "$KEEP"
      ok "SteamOS: правило добавлено в список сохраняемых при обновлении ($KEEP)"
    fi
  fi
  warn "Безопасность: теперь любая программа от имени $USER может выполнять команды администратора без пароля."
  info "Для игровой приставки с одним пользователем это обычно. Убрать: bash $0 --uninstall  (или sudo rm $SF)"
  if [ "$DRY" = 0 ]; then
    sudo -k
    if sudo -n true 2>/dev/null; then ok "проверка: sudo без пароля работает"
    else warn "sudo всё ещё просит пароль — возможно, другое правило перекрывает это (см. sudo -l)"; fi
    sudo -v 2>/dev/null || true
  fi
fi

# ---------- 5. Decky Loader ----------
step "Decky Loader"
if [ "$DO_DECKY" = 0 ]; then
  info "пропущено (--no-decky)"
elif decky_installed; then
  ok "уже установлен — пропускаю"
else
  info "Устанавливаю Decky Loader…"
  if [ "$SYSTEM" = bazzite ]; then
    command -v ujust >/dev/null 2>&1 || die "нет команды ujust — это точно Bazzite?"
    make_tty_askpass "$TMP/askpass"
    info "Если ujust спросит пароль — введите его здесь, в терминале (тот же пароль)."
    info "Если всё-таки появится окно с паролем посреди экрана — это ujust; введите туда тот же пароль."
    SUDO_ASKPASS="$TMP/askpass" run ujust setup-decky install || die "ujust setup-decky install завершился с ошибкой"
  else
    curl "${CURL_SMALL[@]}" "$DECKY_INSTALLER_URL" -o "$TMP/decky_install_release.sh" || die "не удалось скачать установщик Decky"
    run sudo bash "$TMP/decky_install_release.sh" || die "установщик Decky завершился с ошибкой"
  fi
  if [ "$DRY" = 0 ]; then decky_installed || die "Decky не появился (нет службы plugin_loader)"; fi
  ok "Decky Loader установлен"
fi

# ---------- 6. плагин ----------
step "Плагин AdGuard VPN"
SRC_DIR=""; ZIP=""
if [ -n "$ZIP_ARG" ]; then
  [ -f "$ZIP_ARG" ] || die "файл не найден: $ZIP_ARG"
  ZIP="$ZIP_ARG"
elif [ -f "$SCRIPT_DIR/plugin.json" ] && [ -f "$SCRIPT_DIR/dist/index.js" ]; then
  SRC_DIR="$SCRIPT_DIR"   # скрипт лежит в распакованной папке плагина
else
  for d in "$SCRIPT_DIR" "$HOME/Downloads" "$HOME/Загрузки"; do
    f="$(find "$d" -maxdepth 1 -name 'adguard-vpn-[0-9]*.zip' 2>/dev/null | sort -V | tail -n1 || true)"
    if [ -n "$f" ]; then ZIP="$f"; break; fi
  done
  if [ -z "$ZIP" ] && [ -n "$PLUGIN_ZIP_URL" ]; then
    info "Скачиваю плагин: $PLUGIN_ZIP_URL"
    curl "${CURL_BIG[@]}" "$PLUGIN_ZIP_URL" -o "$TMP/plugin.zip" || die "не удалось скачать плагин"
    ZIP="$TMP/plugin.zip"
  fi
  [ -n "$ZIP" ] || die "не найден adguard-vpn-$PLUGIN_VERSION.zip. Положите его в «Загрузки» (~/Downloads) или укажите путь: bash $0 /путь/к/adguard-vpn-$PLUGIN_VERSION.zip"
fi
if [ -n "$ZIP" ]; then
  info "Архив плагина: $ZIP"
  python3 - "$ZIP" "$TMP/plugin" <<'PY' || die "архив плагина повреждён или это не тот файл"
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
need = {"adguard-vpn/plugin.json", "adguard-vpn/main.py", "adguard-vpn/dist/index.js"}
missing = need - names
if missing:
    sys.exit("в архиве нет: " + ", ".join(sorted(missing)))
z.extractall(sys.argv[2])
PY
  SRC_DIR="$TMP/plugin/adguard-vpn"
else
  info "Папка плагина: $SRC_DIR"
fi
NEWVER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$SRC_DIR/plugin.json")"
[ -d "$PLUGINS_DIR" ] || run sudo mkdir -p "$PLUGINS_DIR"
# Старые копии плагина (в т.ч. версии ≤1.0.5 с именем adguard-vpn) под любым именем папки
for d in "$PLUGINS_DIR"/*/; do
  [ -f "${d}plugin.json" ] || continue
  [ "${d%/}" = "$PLUGIN_DIR" ] && continue
  if python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("name") in ("AdGuard VPN","adguard-vpn") else 1)' "${d}plugin.json" 2>/dev/null; then
    run sudo rm -rf "${d%/}"; info "удалена старая копия: ${d%/}"
  fi
done
if [ -d "$PLUGIN_DIR" ]; then
  OLDVER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version","?"))' "$PLUGIN_DIR/plugin.json" 2>/dev/null || echo '?')"
  info "заменяю установленную версию $OLDVER на $NEWVER"
  run sudo rm -rf "$PLUGIN_DIR"
fi
run sudo cp -r "$SRC_DIR" "$PLUGIN_DIR"
# Так же, как делает Decky при установке «root»-плагина из ZIP: владелец root, права 755/644
run sudo chown -R root:root "$PLUGIN_DIR"
run sudo chmod -R u=rwX,go=rX "$PLUGIN_DIR"
run sudo chmod 755 "$PLUGIN_DIR/adguard-vpn.sh"
if command -v restorecon >/dev/null 2>&1; then run sudo restorecon -R "$PLUGIN_DIR" >/dev/null 2>&1 || true; fi
ok "плагин $NEWVER скопирован в $PLUGIN_DIR"
info "Режим разработчика в Decky для такой установки не нужен."
restart_decky
if [ "$DRY" = 0 ] && decky_installed; then
  for _ in $(seq 1 20); do [ -d "$HOME/homebrew/logs/adguard-vpn" ] && break; sleep 1; done
  if [ -d "$HOME/homebrew/logs/adguard-vpn" ]; then ok "Decky загрузил плагин"
  else warn "не видно, что Decky загрузил плагин (папки логов нет) — проверьте в игровом режиме"; fi
fi

# ---------- 7. вход в аккаунт ----------
step "Вход в аккаунт AdGuard"
LOGGED_IN=0
if [ "$DRY" = 1 ]; then run "$CLI" license
else
  info "Проверяю вход (на медленной сети до минуты)…"
  LIC="$(cli_q license || true)"
  # «Вошёл» — только если CLI это подтвердил; нет ответа / непонятный ответ → предлагаем войти
  if printf '%s' "$LIC" | grep -qiE 'not logged in|please log in|log in first|login required'; then LOGGED_IN=0
  elif printf '%s' "$LIC" | grep -qiE '@|logged in as|premium|subscription|license'; then LOGGED_IN=1
  else LOGGED_IN=0; warn "adguardvpn-cli не ответил на «license» — не знаю, выполнен ли вход"; fi
  if [ "$LOGGED_IN" = 0 ]; then
    info "Вы ещё не вошли (или проверить не удалось). Сейчас откроется вход AdGuard:"
    info " • нажмите b и Enter — откроется браузер (или откройте показанную ссылку на телефоне);"
    info " • войдите или создайте аккаунт; вернитесь сюда — появится «Successfully logged in»."
    info "Можно и позже: в игровом режиме → «…» → Decky → AdGuard VPN → «Войти в AdGuard» (QR-код)."
    if ask "Войти сейчас?" y; then
      tty_run "$CLI" login || warn "вход не завершён — можно войти позже из плагина"
      LIC="$(cli_q license || true)"
      if printf '%s' "$LIC" | grep -qiE 'not logged in|please log in|log in first'; then LOGGED_IN=0
      elif printf '%s' "$LIC" | grep -qiE '@|logged in as|premium|subscription|license'; then LOGGED_IN=1; fi
    fi
  fi
  if [ "$LOGGED_IN" = 1 ]; then ok "вход выполнен: $(printf '%s' "$LIC" | grep -m1 -iE '@|logged in as' || echo 'да')"
  else warn "вход не выполнен — войдите позже из плагина (QR-код)"; fi
fi

# ---------- 8. пробное подключение ----------
step "Пробное подключение (необязательно)"
want_test=0
case "$DO_TEST" in
  yes) want_test=1 ;;
  no)  ;;
  ask) if [ "$LOGGED_IN" = 1 ] || [ "$DRY" = 1 ]; then ask "Подключиться для проверки (Словакия, если не выйдет — другие) и отключиться?" n && want_test=1; fi ;;
esac
if [ "$want_test" = 1 ]; then
  # По очереди: Словакия → Германия → Швеция → самая быстрая; до первого успеха, до ~90 с на попытку
  TEST_OK=""
  for loc in Slovakia Germany Sweden fastest; do
    if [ "$loc" = fastest ]; then info "пробую: самая быстрая (connect -f)…"; TEST_ARGS=(connect -f -y)
    else info "пробую: $loc…"; TEST_ARGS=(connect -l "$loc" -y); fi
    rc=0
    run timeout -k 10 90 "$CLI" "${TEST_ARGS[@]}" </dev/null || rc=$?
    if [ "$rc" = 0 ]; then TEST_OK="$loc"; break; fi
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then warn "$loc: нет ответа за 90 с"; else warn "$loc: не удалось (код $rc)"; fi
  done
  if [ -n "$TEST_OK" ]; then
    run timeout 60 "$CLI" status </dev/null || true
    run timeout 60 "$CLI" disconnect </dev/null || true
    [ "$TEST_OK" = fastest ] && TEST_OK="самая быстрая"
    ok "тест пройден: подключение работает ($TEST_OK), VPN снова отключён"
  else
    warn "ни одна локация не подключилась (Словакия, Германия, Швеция, самая быстрая). Проверьте сеть и вход; список стран: adguardvpn-cli list-locations"
  fi
else
  info "пропущено"
fi

# ---------- отметка «установка завершена» (её проверяет плагин) ----------
MARKER_DIR="$HOME/homebrew/settings/adguard-vpn"
MARKER="$MARKER_DIR/install-complete"
printf 'version=%s\ndate=%s\nsystem=%s\nuser=%s\nlogged_in=%s\n' \
  "$PLUGIN_VERSION" "$(date '+%F %T %Z')" "$SYSTEM" "$USER" "$LOGGED_IN" >"$TMP/marker"
if [ "$DRY" = 1 ]; then run install -D -m 0644 "$TMP/marker" "$MARKER"
elif install -D -m 0644 "$TMP/marker" "$MARKER" 2>/dev/null || sudo install -D -m 0644 "$TMP/marker" "$MARKER"; then
  info "отметка об успешной установке: $MARKER"
else
  warn "не удалось записать $MARKER (не страшно)"
fi

# ---------- итог ----------
printf '\n%s%s=========== Готово ===========%s\n' "$B" "$G" "$N"
if [ "$DRY" = 1 ]; then CLIVER="(dry-run)"; else CLIVER="$(cli_q --version | head -n1 || true)"; fi
info "✔ AdGuard VPN CLI: $CLIVER"
[ "$DO_SUDOERS" = 1 ] && info "✔ Правило sudo: $ETC/sudoers.d/$(sudoers_name)"
[ "$DO_DECKY" = 1 ] && info "✔ Decky Loader установлен"
info "✔ Плагин AdGuard VPN $NEWVER: $PLUGIN_DIR"
if [ "$LOGGED_IN" = 1 ]; then info "✔ Вход в AdGuard выполнен"
else info "• Вход в AdGuard: сделайте в плагине («Войти в AdGuard», QR-код)"; fi
printf '\n%sЧто дальше:%s\n' "$B" "$N"
info "1. Вернитесь в игровой режим (значок «Return to Gaming Mode» на рабочем столе или перезагрузка)."
info "2. Нажмите кнопку «…» → значок вилки (Decky) → AdGuard VPN."
info "3. Нажмите страну (например, «Словакия») — через несколько секунд статус станет «🟢 Включено»."
info "4. По желанию: «Настройки» → «Подключаться при запуске» и «Переподключать при обрыве»."
if [ "$SYSTEM" = steamos ]; then
  printf '\n%sSteamOS:%s после крупного обновления системы Decky или правило sudo могут пропасть.\n' "$Y" "$N"
  info "Тогда просто запустите этот скрипт ещё раз: bash $0"
fi
info "Журнал установки: $LOG"
printf '\n  %sby MaxFoley · сделано с помощью Grok Bot%s\n' "${DIM:-}" "$N"
