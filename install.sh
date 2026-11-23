#!/usr/bin/env bash
# Degeris DSUI installer
# Release: v1.0.0 | Asset: dsui-1.0.0.zip
set -Eeuo pipefail
IFS=$'\n\t'

readonly BRAND='Degeris'
readonly REPO='Degeris/dsui'
readonly RELEASE_TAG='v1.0.0'
readonly DISTRIBUTION_VERSION='1.0.0'
readonly ASSET_NAME='dsui-1.0.0.zip'
readonly INSTALL_DIR='/usr/local/dsui'
readonly BACKUP_ROOT='/var/backups/dsui'
readonly LOG_FILE='/var/log/dsui-installer.log'
readonly DEFAULT_USER='admin'
readonly DEFAULT_PASS='admin'
readonly DEFAULT_PORT='8000'
readonly DEFAULT_WEB_PATH='dashboard/'
INSTALL_MUTATED=0
SERVICE_STOPPED=0
DB_EXISTING=0
DB_TYPE='sqlite'
DB_DSN=''
IS_NEW_INSTALL=1
PANEL_SCHEME='http'
PANEL_HOST=''
PANEL_PORT='8000'
PANEL_WEB_PATH='dashboard/'
PANEL_REVERSE_PROXY=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
OS_ID=''; OS_VERSION=''; ARCH=''; ENV_FILE=''; SERVICE_MANAGER=''; BACKUP_DIR=''; STAGE_DIR=''; TMP_DIR=''

log()  { printf '%b[%s]%b %s\n' "$BLUE" INFO "$RESET" "$*" | tee -a "$LOG_FILE"; }
ok()   { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" | tee -a "$LOG_FILE"; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$INSTALL_MUTATED" == 1 ]]; then
      warn 'Installation failed after filesystem changes; attempting rollback...'
      if [[ "$SERVICE_MANAGER" == openrc ]]; then rc-service dsui stop >/dev/null 2>&1 || true
      elif [[ "$SERVICE_MANAGER" == systemd ]]; then systemctl stop dsui >/dev/null 2>&1 || true; fi
      rm -rf "$INSTALL_DIR" || true
      if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/usr-local-dsui" ]]; then cp -a "$BACKUP_DIR/usr-local-dsui" "$INSTALL_DIR" || true; fi
      if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/etc-dsui" ]]; then rm -rf /etc/dsui; cp -a "$BACKUP_DIR/etc-dsui" /etc/dsui || true
      else rm -rf /etc/dsui || true; fi
      if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/service-env" ]]; then cp -a "$BACKUP_DIR/service-env" "$ENV_FILE" || true
      else rm -f "$ENV_FILE" || true; fi
      if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/dsui.service" ]]; then cp -a "$BACKUP_DIR/dsui.service" /etc/systemd/system/dsui.service || true
      elif [[ "$SERVICE_MANAGER" == systemd ]]; then rm -f /etc/systemd/system/dsui.service || true; fi
      if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/dsui.rc" ]]; then cp -a "$BACKUP_DIR/dsui.rc" /etc/init.d/dsui || true
      elif [[ "$SERVICE_MANAGER" == openrc ]]; then rm -f /etc/init.d/dsui || true; fi
      if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/usr-bin-dsui" ]]; then cp -a "$BACKUP_DIR/usr-bin-dsui" /usr/bin/dsui || true
      else rm -f /usr/bin/dsui || true; fi
      if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/usr-local-dsui" ]]; then
        if [[ "$SERVICE_MANAGER" == openrc ]]; then rc-service dsui start >/dev/null 2>&1 || true
        else systemctl daemon-reload >/dev/null 2>&1 || true; systemctl start dsui >/dev/null 2>&1 || true; fi
      fi
      warn "Rollback attempt finished. Backup retained at ${BACKUP_DIR:-not-created}."
    elif [[ "$SERVICE_STOPPED" == 1 ]]; then
      if [[ "$SERVICE_MANAGER" == openrc ]]; then rc-service dsui start >/dev/null 2>&1 || true
      else systemctl start dsui >/dev/null 2>&1 || true; fi
    fi
  fi
  [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
}

on_error() {
  local rc=$?
  trap - ERR
  printf '%b[ERROR]%b Installation failed at line %s (exit %s). Log: %s\n' "$RED" "$RESET" "${BASH_LINENO[0]:-unknown}" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}
trap on_error ERR

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this installer as root.'; }

 detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH='amd64' ;;
    aarch64|arm64) ARCH='arm64' ;;
    armv7l|armv7*) ARCH='armv7' ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  log "Detected architecture: $(uname -m) -> ${ARCH}"
}

load_os() {
  [[ -r /etc/os-release ]] || die '/etc/os-release not found; cannot identify this Linux distribution.'
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  case "$OS_ID" in
    alpine) SERVICE_MANAGER='openrc'; ENV_FILE='/etc/conf.d/dsui' ;;
    ubuntu|debian|linuxmint|pop|raspbian|armbian) SERVICE_MANAGER='systemd'; ENV_FILE='/etc/default/dsui' ;;
    arch|manjaro|endeavouros) SERVICE_MANAGER='systemd'; ENV_FILE='/etc/conf.d/dsui' ;;
    fedora|rhel|centos|rocky|almalinux|ol|amzn|virtuozzo) SERVICE_MANAGER='systemd'; ENV_FILE='/etc/sysconfig/dsui' ;;
    opensuse*|sles) SERVICE_MANAGER='systemd'; ENV_FILE='/etc/sysconfig/dsui' ;;
    *)
      if command -v systemctl >/dev/null 2>&1; then SERVICE_MANAGER='systemd'; ENV_FILE='/etc/default/dsui'
      elif command -v rc-service >/dev/null 2>&1; then SERVICE_MANAGER='openrc'; ENV_FILE='/etc/conf.d/dsui'
      else die "Unsupported init system for distribution '${OS_ID}'."; fi
      warn "Distribution '${OS_ID}' is not in the tested list; continuing with detected init system."
      ;;
  esac
  log "OS: ${PRETTY_NAME:-$OS_ID} | init: ${SERVICE_MANAGER} | env: ${ENV_FILE}"
}

install_packages() {
  log 'Installing required system utilities...'
  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop|raspbian|armbian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y curl ca-certificates unzip tar gzip openssl socat cron iproute2 procps
      ;;
    fedora|rhel|centos|rocky|almalinux|ol|amzn|virtuozzo)
      if command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates unzip tar gzip openssl socat cronie iproute procps-ng
      else yum install -y curl ca-certificates unzip tar gzip openssl socat cronie iproute procps-ng; fi
      ;;
    arch|manjaro|endeavouros)
      pacman -Sy --noconfirm curl ca-certificates unzip tar gzip openssl socat cronie iproute2 procps-ng
      ;;
    opensuse*|sles)
      zypper --non-interactive refresh
      zypper --non-interactive install -y curl ca-certificates unzip tar gzip openssl socat cron iproute2 procps
      ;;
    alpine)
      apk update
      apk add --no-cache bash curl ca-certificates unzip tar gzip openssl socat dcron iproute2 procps coreutils
      ;;
    *) die "Cannot install dependencies automatically on ${OS_ID}." ;;
  esac
  command -v curl >/dev/null && command -v unzip >/dev/null && command -v sha256sum >/dev/null || die 'Required utilities are still missing after package installation.'
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -H -ltn "sport = :${p}" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then netstat -lnt 2>/dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  else return 1; fi
}

prompt_value() {
  local prompt="$1" default="$2" value=''
  if [[ -t 0 ]]; then
    read -r -p "${prompt} [${default}]: " value || true
    printf '%s' "${value:-$default}"
  else
    printf '%s' "$default"
  fi
}

select_database() {
  local choice='1' existing_type=''
  if [[ -d "$INSTALL_DIR" ]]; then
    existing_type="$(grep -E '^DSUI_DB_TYPE=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    if [[ "$existing_type" == postgres ]]; then
      DB_TYPE='postgres'
      DB_EXISTING=1
      DB_DSN="$(grep -E '^DSUI_DB_DSN=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
      [[ -n "$DB_DSN" ]] || die 'Existing installation is configured for PostgreSQL but DSUI_DB_DSN is missing; refusing to overwrite the database configuration.'
      log 'Existing PostgreSQL configuration detected; preserving its DSN and database.'
      return 0
    fi
    DB_TYPE='sqlite'
    DB_EXISTING=1
    log 'Existing SQLite installation detected; preserving its database.'
    return 0
  fi
  if [[ -t 0 ]]; then
    echo
    echo 'Database selection:'
    echo '  1) SQLite (default; no separate database server)'
    echo '  2) PostgreSQL (install local server and create a dedicated DSUI database)'
    read -r -p 'Choose [1-2] (default 1): ' choice || true
  fi
  case "${choice:-1}" in
    1) DB_TYPE='sqlite' ;;
    2) DB_TYPE='postgres' ;;
    *) die 'Invalid database selection.' ;;
  esac
}

random_string() { openssl rand -hex "${1:-16}" | cut -c1-"${1:-16}"; }

run_as_postgres() {
  if command -v runuser >/dev/null 2>&1; then runuser -u postgres -- "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo -u postgres "$@"
  else su -s /bin/sh postgres -c "$(printf '%q ' "$@")"; fi
}

pg_service_start() {
  if [[ "$SERVICE_MANAGER" == openrc ]]; then
    rc-update add postgresql default >/dev/null 2>&1 || true
    rc-service postgresql start
  else
    systemctl enable --now postgresql || {
      # Debian can use a versioned cluster unit while postgresql.service is a meta-unit.
      command -v pg_lsclusters >/dev/null 2>&1 && pg_lsclusters
      systemctl start postgresql
    }
  fi
}

install_postgres() {
  local pg_user pg_pass pg_db='dsui' pg_host='127.0.0.1' pg_port='5432' enc i
  log 'Installing PostgreSQL server and client tools...'
  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop|raspbian|armbian)
      apt-get update
      apt-get install -y postgresql postgresql-client
      ;;
    fedora|rhel|centos|rocky|almalinux|ol|amzn|virtuozzo)
      if command -v dnf >/dev/null 2>&1; then dnf install -y postgresql-server postgresql
      else yum install -y postgresql-server postgresql; fi
      if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]] && command -v postgresql-setup >/dev/null 2>&1; then postgresql-setup --initdb; fi
      ;;
    arch|manjaro|endeavouros)
      pacman -Sy --noconfirm postgresql
      if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then install -d -o postgres -g postgres -m 700 /var/lib/postgres/data; run_as_postgres initdb -D /var/lib/postgres/data; fi
      ;;
    opensuse*|sles)
      zypper --non-interactive install -y postgresql-server postgresql
      if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data; su - postgres -c 'initdb -D /var/lib/pgsql/data'; fi
      ;;
    alpine)
      apk add --no-cache postgresql postgresql-client
      [[ -f /var/lib/postgresql/data/PG_VERSION ]] || /etc/init.d/postgresql setup
      ;;
    *) die "Automatic PostgreSQL installation is not supported on ${OS_ID}." ;;
  esac
  pg_service_start
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run_as_postgres psql -tAc 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  run_as_postgres psql -tAc 'SELECT 1' >/dev/null 2>&1 || die 'PostgreSQL did not become ready.'

  pg_user="dsui_$(random_string 8)"
  pg_pass="$(random_string 32)"
  run_as_postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"${pg_user}\" LOGIN PASSWORD '${pg_pass}';" || die 'Could not create PostgreSQL role.'
  run_as_postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" || die 'Could not create PostgreSQL database.'
  # DSUI connects over TCP; add a narrowly scoped password-auth rule when pg_hba.conf is available.
  local hba
  hba="$(run_as_postgres psql -tAc 'SHOW hba_file' 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$hba" && -f "$hba" ]] && ! grep -Eq "^[[:space:]]*host[[:space:]]+${pg_db}[[:space:]]+${pg_user}[[:space:]]+127\\.0\\.0\\.1/32" "$hba"; then
    cp -a "$hba" "${hba}.dsui-backup.$(date +%s)"
    { printf 'host %s %s 127.0.0.1/32 scram-sha-256\n' "$pg_db" "$pg_user"; cat "$hba"; } > "${hba}.dsui.tmp"
    cat "${hba}.dsui.tmp" > "$hba"; rm -f "${hba}.dsui.tmp"
    if [[ "$SERVICE_MANAGER" == openrc ]]; then rc-service postgresql reload || rc-service postgresql restart
    else systemctl reload postgresql 2>/dev/null || systemctl restart postgresql; fi
  fi
  # random_string emits hexadecimal credentials, so no URL escaping is needed.
  DB_DSN="postgres://${pg_user}:${pg_pass}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
  ok 'PostgreSQL database and dedicated account created.'
}

write_db_env() {
  install -d -m 755 "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  sed -i '/^DSUI_DB_TYPE=/d; /^DSUI_DB_DSN=/d' "$ENV_FILE"
  if [[ "$DB_TYPE" == postgres ]]; then
    printf 'DSUI_DB_TYPE=postgres\nDSUI_DB_DSN=%s\n' "$DB_DSN" >> "$ENV_FILE"
  else
    # Remove only the DSUI database overrides; other service environment values survive.
    :
  fi
}

fetch_release() {
  local url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
  local zip="$TMP_DIR/$ASSET_NAME" code digest=''
  log "Downloading ${ASSET_NAME} from ${REPO} (${RELEASE_TAG})..."
  curl -fL --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 1800 "$url" -o "$zip" || die 'Release download failed. Confirm the tag and asset name in GitHub Releases.'
  [[ -s "$zip" ]] || die 'Downloaded release archive is empty.'
  unzip -tq "$zip" >/dev/null || die 'The downloaded ZIP archive is corrupt.'

  # Prefer the immutable SHA-256 digest exposed by GitHub Releases API.
  if command -v python3 >/dev/null 2>&1; then
    digest="$(curl -fsSL --retry 2 "https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); a=next((x for x in d.get("assets",[]) if x.get("name")==sys.argv[1]),{}); print((a.get("digest") or "").removeprefix("sha256:"))' "$ASSET_NAME" 2>/dev/null || true)"
  fi
  if [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]]; then
    local actual; actual="$(sha256sum "$zip" | awk '{print $1}')"
    [[ "${actual,,}" == "${digest,,}" ]] || die "Release asset SHA256 mismatch (expected ${digest}, got ${actual})."
    ok "GitHub asset digest verified: ${actual}"
  else
    code="$(curl -sSL --retry 2 -o "$zip.sha256" -w '%{http_code}' "${url}.sha256" || true)"
    if [[ "$code" == 200 ]]; then
      local expected actual
      expected="$(awk 'NR==1 {print $1}' "$zip.sha256")"; actual="$(sha256sum "$zip" | awk '{print $1}')"
      [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "${expected,,}" == "${actual,,}" ]] || die 'Release sidecar SHA256 verification failed.'
      ok "Release sidecar SHA256 verified: ${actual}"
    else
      warn 'GitHub did not provide an asset digest or .sha256 sidecar; will validate the archive manifest and every listed file before installation.'
    fi
  fi
  mkdir -p "$STAGE_DIR"
  unzip -q "$zip" -d "$STAGE_DIR"
  [[ -d "$STAGE_DIR/dsui" ]] || die 'Release ZIP must contain a top-level dsui/ directory.'
  [[ -s "$STAGE_DIR/dsui/dsui.sh" && -s "$STAGE_DIR/dsui/RELEASE_VERSION" ]] || die 'Release is missing dsui.sh or RELEASE_VERSION.'
  local actual_version binary_version manifest_version
  actual_version="$(tr -d '\r\n ' < "$STAGE_DIR/dsui/RELEASE_VERSION")"
  binary_version="$(chmod +x "$STAGE_DIR/dsui/dsui"; "$STAGE_DIR/dsui/dsui" -v 2>/dev/null | tr -d '\r\n ' || true)"
  manifest_version="$(awk -F= '$1=="VERSION" {print $2; exit}' "$STAGE_DIR/dsui/RELEASE_MANIFEST" 2>/dev/null | tr -d '\r\n ' || true)"
  [[ -n "$actual_version" && -n "$binary_version" && "$actual_version" == "$binary_version" ]] || die "DSUI version metadata does not match the executable (RELEASE_VERSION=${actual_version:-missing}, binary=${binary_version:-unreadable})."
  [[ -z "$manifest_version" || "$manifest_version" == "$binary_version" ]] || die "RELEASE_MANIFEST version (${manifest_version}) does not match DSUI binary (${binary_version})."
  log "GitHub distribution release: ${DISTRIBUTION_VERSION}; embedded DSUI engine version: ${binary_version}."
  if [[ -s "$STAGE_DIR/dsui/SHA256SUMS" ]]; then
    (cd "$STAGE_DIR/dsui" && sha256sum -c SHA256SUMS --quiet) || die 'One or more files in the release failed SHA256SUMS validation.'
    ok 'Internal SHA256SUMS validation passed.'
  else
    die 'Release archive does not contain SHA256SUMS.'
  fi
}

verify_elf_arch() {
  local binary="$1" expected="$2" actual
  [[ -s "$binary" ]] || die "Required binary is missing: ${binary}"
  actual="$(od -An -t u2 -j 18 -N 2 "$binary" 2>/dev/null | tr -d '[:space:]')"
  [[ "$actual" == "$expected" ]] || die "Wrong ELF architecture for $(basename "$binary"): expected e_machine ${expected}, got ${actual:-unreadable}."
}

select_arch_payload() {
  local root="$STAGE_DIR/dsui" archdir='' xray_arch='' mtg_arch='' elf_machine=''
  case "$ARCH" in
    amd64) archdir='amd64'; xray_arch='amd64'; mtg_arch='amd64'; elf_machine='62' ;;
    arm64) archdir='arm64'; xray_arch='arm64'; mtg_arch='arm64'; elf_machine='183' ;;
    armv7) archdir='armv7'; xray_arch='arm32'; mtg_arch='arm'; elf_machine='40' ;;
  esac
  # Single-asset multi-architecture layout: dsui/arch/<goarch>/{dsui,bin/...}
  if [[ -s "$root/arch/$archdir/dsui" ]]; then
    install -m 755 "$root/arch/$archdir/dsui" "$root/dsui"
    local xray_source="$root/arch/$archdir/bin/xray-linux-${xray_arch}"
    [[ -s "$xray_source" ]] || xray_source="$root/arch/$archdir/bin/xray-linux-${archdir}"
    [[ -s "$xray_source" ]] || die "Xray binary missing for ${ARCH} in the single-asset release."
    install -m 755 "$xray_source" "$root/bin/xray-linux-${xray_arch}"
    local mtg_source="$root/arch/$archdir/bin/mtg-linux-${mtg_arch}"
    [[ -s "$mtg_source" ]] || mtg_source="$root/arch/$archdir/bin/mtg-linux-${archdir}"
    [[ -s "$mtg_source" ]] || die "MTG binary missing for ${ARCH} in the single-asset release."
    install -m 755 "$mtg_source" "$root/bin/mtg-linux-${mtg_arch}"
  else
    # Backward-compatible flat layout: the currently supplied source package is AMD64 only.
    [[ "$ARCH" == amd64 ]] || die "This Release ZIP has no ${ARCH} payload. Add dsui/arch/${archdir}/dsui and matching Xray/MTG binaries to the same ZIP."
    [[ -s "$root/dsui" && -s "$root/bin/xray-linux-amd64" && -s "$root/bin/mtg-linux-amd64" ]] || die 'AMD64 panel, Xray or MTG binary is missing from the release.'
  fi
  chmod 755 "$root/dsui" "$root/dsui.sh" "$root/bin/xray-linux-${xray_arch}" "$root/bin/mtg-linux-${mtg_arch}"
  verify_elf_arch "$root/bin/xray-linux-${xray_arch}" "$elf_machine"
  verify_elf_arch "$root/bin/mtg-linux-${mtg_arch}" "$elf_machine"
  ok "Selected ${ARCH} payload automatically and verified Xray/MTG ELF architecture."
}

make_backup() {
  if [[ -d "$INSTALL_DIR" || -d /etc/dsui || -f "$ENV_FILE" || -f /etc/systemd/system/dsui.service || -f /etc/init.d/dsui || -f /usr/bin/dsui ]]; then
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$BACKUP_DIR"
    [[ ! -d "$INSTALL_DIR" ]] || cp -a "$INSTALL_DIR" "$BACKUP_DIR/usr-local-dsui"
    [[ ! -d /etc/dsui ]] || cp -a /etc/dsui "$BACKUP_DIR/etc-dsui"
    [[ ! -f "$ENV_FILE" ]] || cp -a "$ENV_FILE" "$BACKUP_DIR/service-env"
    [[ ! -f /etc/systemd/system/dsui.service ]] || cp -a /etc/systemd/system/dsui.service "$BACKUP_DIR/dsui.service"
    [[ ! -f /etc/init.d/dsui ]] || cp -a /etc/init.d/dsui "$BACKUP_DIR/dsui.rc"
    [[ ! -f /usr/bin/dsui ]] || cp -a /usr/bin/dsui "$BACKUP_DIR/usr-bin-dsui"
    ok "Existing installation backed up to ${BACKUP_DIR}"
  fi
}

preserve_custom_files() {
  local old="$BACKUP_DIR/usr-local-dsui"
  [[ -d "$old" ]] || return 0
  # Preserve admin-created files in bin/ when the new release does not ship them.
  if [[ -d "$old/bin" ]]; then
    while IFS= read -r -d '' f; do
      local rel="${f#"$old/bin/"}"
      case "$rel" in config.json|mtproto|mtproto/*|tuic|tuic/*|tuic-server|tuic-server-*) continue ;; esac
      if [[ ! -e "$INSTALL_DIR/bin/$rel" ]]; then mkdir -p "$INSTALL_DIR/bin/$(dirname "$rel")"; cp -a "$f" "$INSTALL_DIR/bin/$rel"; fi
    done < <(find "$old/bin" -type f -print0)
  fi
  # Keep custom subscription templates and any existing template files not shipped in the release.
  if [[ -d "$old/sub_templates/custom" ]]; then
    mkdir -p "$INSTALL_DIR/sub_templates/custom"
    cp -an "$old/sub_templates/custom/." "$INSTALL_DIR/sub_templates/custom/" 2>/dev/null || true
  fi
}

install_service() {
  if [[ "$SERVICE_MANAGER" == openrc ]]; then
    [[ -s "$INSTALL_DIR/dsui.rc" ]] || die 'dsui.rc is missing from the release.'
    install -m 755 "$INSTALL_DIR/dsui.rc" /etc/init.d/dsui
    rc-update add dsui default >/dev/null 2>&1 || true
  else
    local unit
    case "$OS_ID" in
      ubuntu|debian|linuxmint|pop|raspbian|armbian) unit="$INSTALL_DIR/dsui.service.debian" ;;
      arch|manjaro|endeavouros) unit="$INSTALL_DIR/dsui.service.arch" ;;
      *) unit="$INSTALL_DIR/dsui.service.rhel" ;;
    esac
    [[ -s "$unit" ]] || die "Required service file not found: ${unit}"
    install -m 644 "$unit" /etc/systemd/system/dsui.service
    systemctl daemon-reload
    systemctl enable dsui
  fi
}

configure_panel() {
  local existed='false'
  [[ -d "$BACKUP_DIR/usr-local-dsui" ]] && existed='true'
  if [[ "$existed" == false ]]; then
    log 'Applying requested default panel credentials and network settings...'
    "$INSTALL_DIR/dsui" setting -username "$DEFAULT_USER" -password "$DEFAULT_PASS" -port "$DEFAULT_PORT" -webBasePath "$DEFAULT_WEB_PATH" >/dev/null
  else
    log 'Existing installation detected: preserving its panel login, port, web path, database and configuration.'
  fi
  local settings
  settings="$("$INSTALL_DIR/dsui" setting -show true 2>/dev/null)" || die 'Could not read DSUI settings after configuration.'
  PANEL_PORT="$(printf '%s\n' "$settings" | awk -F': ' '/port:/ {print $2; exit}' | tr -d '[:space:]')"
  PANEL_WEB_PATH="$(printf '%s\n' "$settings" | awk -F': ' '/webBasePath:/ {print $2; exit}' | tr -d '[:space:]')"
  [[ -n "$PANEL_PORT" ]] || PANEL_PORT="$DEFAULT_PORT"
  [[ -n "$PANEL_WEB_PATH" ]] || PANEL_WEB_PATH="$DEFAULT_WEB_PATH"
  local cert_settings cert_path
  cert_settings="$("$INSTALL_DIR/dsui" setting -getCert true 2>/dev/null || true)"
  cert_path="$(printf '%s\n' "$cert_settings" | awk -F': ' '/cert:/ {print $2; exit}' | tr -d '[:space:]')"
  [[ -z "$cert_path" ]] || PANEL_SCHEME='https'
}

start_service() {
  if [[ "$SERVICE_MANAGER" == openrc ]]; then
    rc-service dsui restart || rc-service dsui start
    rc-service dsui status
  else
    systemctl restart dsui || systemctl start dsui
    systemctl --no-pager --full status dsui || true
    systemctl is-active --quiet dsui || die 'DSUI service failed to start. Inspect: journalctl -u dsui -n 100 --no-pager'
  fi
}


acme_listen_flag() {
  if ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; then printf '%s' ''; else printf '%s' '--listen-v6'; fi
}

restart_dsui_service() {
  if [[ "$SERVICE_MANAGER" == openrc ]]; then rc-service dsui restart; else systemctl restart dsui; fi
}

configure_ssl() {
  [[ -t 0 ]] || { log 'Non-interactive mode: leaving SSL unchanged; SSL tools remain available in the DSUI management menu.'; return 0; }
  local choice domain cert key email cert_dir acme="$HOME/.acme.sh/acme.sh"
  echo
  echo 'SSL setup:'
  echo '  1) Let’s Encrypt certificate for a domain (HTTP-01; port 80 must be reachable)'
  echo '  2) Use an existing custom certificate and private key'
  echo '  3) Reverse-proxy mode (bind DSUI to 127.0.0.1; configure TLS in your proxy)'
  echo '  4) Skip for now (IP and Cloudflare DNS SSL remain available in DSUI menu options 20/21)'
  read -r -p 'Choose [1-4] (default 4): ' choice || true
  case "${choice:-4}" in
    1)
      read -r -p 'Domain name: ' domain || true
      [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || { warn 'Invalid domain; SSL setup skipped.'; return 0; }
      port_in_use 80 && { warn 'Port 80 is already occupied; stop the web server or use DSUI SSL menu later.'; return 0; }
      if [[ ! -x "$acme" ]]; then
        log 'Installing acme.sh...'
        curl -fsSL https://get.acme.sh | sh
      fi
      [[ -x "$acme" ]] || { warn 'acme.sh installation failed; SSL setup skipped.'; return 0; }
      "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
      log "Requesting certificate for ${domain}..."
      # shellcheck disable=SC2046
      "$acme" --issue -d "$domain" --standalone --httpport 80 $(acme_listen_flag) || { warn 'Certificate issuance failed; panel remains available over HTTP.'; return 0; }
      cert_dir="/root/cert/${domain}"
      install -d -m 700 "$cert_dir"
      local reload_cmd='systemctl restart dsui'
      [[ "$SERVICE_MANAGER" != openrc ]] || reload_cmd='rc-service dsui restart'
      "$acme" --install-cert -d "$domain" --key-file "${cert_dir}/privkey.pem" --fullchain-file "${cert_dir}/fullchain.pem" --reloadcmd "$reload_cmd" || { warn 'Could not install the certificate files; SSL setup skipped.'; return 0; }
      "$INSTALL_DIR/dsui" setting -webCert "${cert_dir}/fullchain.pem" -webCertKey "${cert_dir}/privkey.pem" || { warn 'DSUI rejected certificate paths.'; return 0; }
      restart_dsui_service
      PANEL_SCHEME='https'; PANEL_HOST="$domain"
      ok "Domain SSL configured for ${domain}."
      ;;
    2)
      read -r -p 'Fullchain/certificate file path: ' cert || true
      read -r -p 'Private key file path: ' key || true
      [[ -s "$cert" && -s "$key" ]] || { warn 'Certificate or key file not found; SSL setup skipped.'; return 0; }
      "$INSTALL_DIR/dsui" setting -webCert "$cert" -webCertKey "$key" || { warn 'DSUI rejected the certificate paths.'; return 0; }
      restart_dsui_service
      PANEL_SCHEME='https'
      ok 'Custom SSL certificate configured.'
      ;;
    3)
      "$INSTALL_DIR/dsui" setting -listenIP 127.0.0.1 || die 'Could not set DSUI listen IP for reverse-proxy mode.'
      restart_dsui_service
      PANEL_REVERSE_PROXY=1
      ok 'DSUI is now bound to 127.0.0.1; configure TLS and proxying in Nginx/Caddy/Apache.'
      ;;
    4|'') log 'SSL setup skipped. Use /usr/bin/dsui menu options 20/21 for domain, IP and Cloudflare certificate management.' ;;
    *) warn 'Invalid SSL selection; SSL setup skipped.' ;;
  esac
}

print_summary() {
  local ip; ip="${PANEL_HOST:-$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
  [[ -n "$ip" ]] || ip='<SERVER-IP>'
  echo
  printf '%b%s DSUI distribution %s installation completed.%b\n' "$GREEN" "$BRAND" "$DISTRIBUTION_VERSION" "$RESET"
  printf 'Embedded DSUI engine: %s\n' "$("$INSTALL_DIR/dsui" -v 2>/dev/null || echo unknown)"
  echo "Install directory : ${INSTALL_DIR}"
  echo "Architecture      : ${ARCH}"
  echo "Database          : ${DB_TYPE}"
  echo "Panel port        : ${PANEL_PORT}"
  echo "Web base path     : ${PANEL_WEB_PATH}"
  if [[ "$IS_NEW_INSTALL" == 1 ]]; then
    echo "Default username  : ${DEFAULT_USER}"
    echo "Default password  : ${DEFAULT_PASS}"
  else
    echo 'Panel credentials : preserved from previous installation'
  fi
  if [[ "$PANEL_REVERSE_PROXY" == 1 ]]; then
    echo 'Panel URL         : configure your reverse-proxy hostname; DSUI listens on 127.0.0.1'
  else
    echo "Panel URL         : ${PANEL_SCHEME}://${ip}:${PANEL_PORT}/${PANEL_WEB_PATH#/}"
  fi
  echo "SSL management    : /usr/bin/dsui (menu options 20 and 21)"
  [[ -z "$BACKUP_DIR" ]] || echo "Backup            : ${BACKUP_DIR}"
  echo
  [[ "$IS_NEW_INSTALL" != 1 ]] || warn 'Change the default admin/admin password immediately after the first login.'
  echo 'Management menu: /usr/bin/dsui'
  echo 'Service logs    : journalctl -u dsui -f (systemd) or /var/log/dsui'
  echo
}

main() {
  umask 022
  install -d -m 755 /var/log /var/log/dsui
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  need_root
  load_os
  detect_arch
  TMP_DIR="$(mktemp -d /tmp/degeris-dsui.XXXXXX)"
  STAGE_DIR="$TMP_DIR/extracted"
  install_packages
  fetch_release
  select_arch_payload

  local is_new='true'
  [[ -d "$INSTALL_DIR" ]] && is_new='false'
  [[ "$is_new" == true ]] && IS_NEW_INSTALL=1 || IS_NEW_INSTALL=0
  if [[ "$is_new" == true ]] && port_in_use "$DEFAULT_PORT"; then
    die "Default panel port ${DEFAULT_PORT} is already in use. Stop the conflicting service or change the default in install.sh."
  fi
  select_database
  if [[ "$DB_TYPE" == postgres && "$DB_EXISTING" == 0 ]]; then install_postgres; fi

  if [[ "$is_new" == false ]]; then
    if [[ "$SERVICE_MANAGER" == openrc ]]; then rc-service dsui stop >/dev/null 2>&1 || true
    else systemctl stop dsui >/dev/null 2>&1 || true; fi
    SERVICE_STOPPED=1
  fi
  make_backup

  INSTALL_MUTATED=1
  if [[ -d "$INSTALL_DIR" ]]; then rm -rf "$INSTALL_DIR"; fi
  mkdir -p "$(dirname "$INSTALL_DIR")"
  cp -a "$STAGE_DIR/dsui" "$INSTALL_DIR"
  preserve_custom_files
  chmod 755 "$INSTALL_DIR/dsui" "$INSTALL_DIR/dsui.sh"
  chmod 755 "$INSTALL_DIR/bin"/* 2>/dev/null || true

  # Correct the management script's installer/update source to this repository.
  sed -i -e 's#https://raw.githubusercontent.com/Degeris/Degeris/main/install.sh#https://raw.githubusercontent.com/Degeris/dsui/main/install.sh#g' -e '/^update_menu() {/,/^}/ s#https://raw.githubusercontent.com/Degeris/dsui/main/install.sh#https://raw.githubusercontent.com/Degeris/dsui/main/dsui.sh#g' -e 's/Degerist/Degeris/g' "$INSTALL_DIR/dsui.sh"
sed -i '/^update_dev() {/,/^}/c\
update_dev() {\
    LOGE "Development-channel installation is disabled in this pinned-release installer. Use the stable Update option instead."\
    if [[ $# == 0 ]]; then before_show_menu; fi\
    return 1\
}' "$INSTALL_DIR/dsui.sh"
sed -i 's/Update to Dev Channel (latest commit)/Dev Channel (disabled for pinned Release)/' "$INSTALL_DIR/dsui.sh"
  install -m 755 "$INSTALL_DIR/dsui.sh" /usr/bin/dsui
  install -d -m 755 /etc/dsui /var/log/dsui
  write_db_env
  install_service
  configure_panel
  start_service
  SERVICE_STOPPED=0
  INSTALL_MUTATED=0
  configure_ssl

  SERVICE_STOPPED=0
  INSTALL_MUTATED=0
  print_summary
}

main "$@"
