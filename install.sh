#!/usr/bin/env bash
# install.sh — WhoisFreaks NRD Feed for Rspamd + Postfix
#
# Sets up the full integration from scratch on Ubuntu 22.04+:
#   1. Installs Rspamd (official repo) + Postfix
#   2. Stores the WhoisFreaks API key securely
#   3. Copies all config files into place
#   4. Seeds the NRD map (initial download)
#   5. Configures the Postfix milter
#   6. Enables and starts all services
#   7. Installs the daily cron job
#
# Usage:
#   sudo ./install.sh
#
# Optional env variables:
#   WINDOW_DAYS   Rolling window size in days (default: 10)
#   MAIL_DOMAIN   Your mail domain (default: system hostname)

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${BLUE}→${RESET} $*"; }
warn() { echo -e "${YELLOW}!${RESET} $*"; }
die()  { echo -e "${RED}✗ ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}$*${RESET}"; echo "────────────────────────────────────────"; }

# ── Must run as root ───────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  die "Please run as root: sudo ./install.sh"
fi

# ── Must run from repo root ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in fetch/wf-nrd-fetch.sh rspamd/multimap.conf rspamd/worker-proxy.inc \
          postfix/main.cf.snippet cron/wf-nrd-rspamd; do
  [[ -f "$SCRIPT_DIR/$f" ]] || die "Missing file: $f — run install.sh from the repo root."
done

# ── Config ─────────────────────────────────────────────────────────────────────
WINDOW_DAYS="${WINDOW_DAYS:-10}"
MAIL_DOMAIN="${MAIL_DOMAIN:-$(hostname -f)}"
API_KEY_FILE="/etc/whoisfreaks/apikey"

# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}WhoisFreaks NRD Feed — Rspamd + Postfix Installer${RESET}"
echo "════════════════════════════════════════════════════"
echo "  Window:      ${WINDOW_DAYS} days"
echo "  Mail domain: ${MAIL_DOMAIN}"
echo "  Ubuntu:      $(lsb_release -ds 2>/dev/null || uname -r)"
echo ""

# ── Step 1: Dependencies ───────────────────────────────────────────────────────
header "Step 1 — Installing dependencies"

info "Installing prerequisite packages..."
apt-get install -y -qq lsb-release wget gnupg curl > /dev/null
ok "Prerequisites installed"

# ── Step 2: Rspamd official repo ──────────────────────────────────────────────
header "Step 2 — Adding Rspamd official repository"

KEYRING="/usr/share/keyrings/rspamd.gpg"
SOURCES="/etc/apt/sources.list.d/rspamd.list"
CODENAME=$(lsb_release -cs)

if [[ ! -f "$KEYRING" ]]; then
  info "Importing Rspamd GPG key..."
  wget -qO- https://rspamd.com/apt-stable/gpg.key \
    | gpg --dearmor -o "$KEYRING"
  ok "GPG key imported"
else
  ok "GPG key already present"
fi

if [[ ! -f "$SOURCES" ]]; then
  echo "deb [signed-by=${KEYRING}] https://rspamd.com/apt-stable/ ${CODENAME} main" \
    > "$SOURCES"
  info "Updating package index..."
  apt-get update -qq > /dev/null
  ok "Rspamd repository added"
else
  ok "Rspamd repository already configured"
fi

# ── Step 3: Install Rspamd + Postfix ──────────────────────────────────────────
header "Step 3 — Installing Rspamd + Postfix"

info "Installing rspamd..."
apt-get install -y -qq rspamd > /dev/null
ok "Rspamd installed: $(rspamd --version 2>&1 | head -1)"

if dpkg -s postfix &>/dev/null; then
  ok "Postfix already installed"
else
  info "Installing Postfix (Internet Site, domain: ${MAIL_DOMAIN})..."
  debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
  debconf-set-selections <<< "postfix postfix/mailname string ${MAIL_DOMAIN}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix > /dev/null
  ok "Postfix installed"
fi

# ── Step 4: API key ────────────────────────────────────────────────────────────
header "Step 4 — WhoisFreaks API key"

if [[ -f "$API_KEY_FILE" ]] && [[ -s "$API_KEY_FILE" ]]; then
  ok "API key already stored at ${API_KEY_FILE}"
else
  echo ""
  echo -e "  Enter your ${BOLD}WhoisFreaks API key${RESET}:"
  echo -e "  (Get one at https://whoisfreaks.com/)"
  echo ""
  read -rsp "  API key: " WF_API_KEY
  echo ""

  if [[ -z "$WF_API_KEY" ]]; then
    die "API key cannot be empty."
  fi

  mkdir -p /etc/whoisfreaks
  echo "$WF_API_KEY" > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  ok "API key stored at ${API_KEY_FILE} (chmod 600)"
fi

# ── Step 5: Rspamd maps directory ─────────────────────────────────────────────
header "Step 5 — Setting up Rspamd maps directory"

mkdir -p /var/lib/rspamd/maps
chown _rspamd:_rspamd /var/lib/rspamd/maps
ok "Maps directory ready: /var/lib/rspamd/maps"

mkdir -p /var/cache/wf-nrd
ok "Cache directory ready: /var/cache/wf-nrd"

# ── Step 6: Copy config files ─────────────────────────────────────────────────
header "Step 6 — Installing config files"

# Fetch script
cp "$SCRIPT_DIR/fetch/wf-nrd-fetch.sh" /usr/local/bin/wf-nrd-fetch.sh
chmod +x /usr/local/bin/wf-nrd-fetch.sh
ok "Fetch script → /usr/local/bin/wf-nrd-fetch.sh"

# Rspamd multimap rule
if [[ -f /etc/rspamd/local.d/multimap.conf ]]; then
  warn "Backing up existing multimap.conf → multimap.conf.bak"
  cp /etc/rspamd/local.d/multimap.conf /etc/rspamd/local.d/multimap.conf.bak
fi
cp "$SCRIPT_DIR/rspamd/multimap.conf" /etc/rspamd/local.d/multimap.conf
ok "Multimap rule → /etc/rspamd/local.d/multimap.conf"

# Rspamd proxy worker
cp "$SCRIPT_DIR/rspamd/worker-proxy.inc" /etc/rspamd/local.d/worker-proxy.inc
ok "Worker proxy → /etc/rspamd/local.d/worker-proxy.inc"

# ── Step 7: Postfix milter ─────────────────────────────────────────────────────
header "Step 7 — Configuring Postfix milter"

postconf -e 'milter_protocol = 6'
postconf -e 'milter_default_action = accept'
postconf -e 'smtpd_milters = inet:localhost:11332'
postconf -e 'non_smtpd_milters = inet:localhost:11332'
ok "Postfix milter settings applied"

# ── Step 8: Seed the NRD map ──────────────────────────────────────────────────
header "Step 8 — Seeding NRD map (initial download)"

info "Downloading ${WINDOW_DAYS} days of NRD data — this may take 2–4 minutes..."
echo ""
WINDOW_DAYS="$WINDOW_DAYS" /usr/local/bin/wf-nrd-fetch.sh
echo ""
# Ensure Rspamd can read the map file (fetch runs as root, file must be readable by _rspamd)
chown _rspamd:_rspamd /var/lib/rspamd/maps /var/lib/rspamd/maps/nrd_domains.map 2>/dev/null || true
chmod 755 /var/lib/rspamd/maps
chmod 644 /var/lib/rspamd/maps/nrd_domains.map 2>/dev/null || true
DOMAIN_COUNT=$(wc -l < /var/lib/rspamd/maps/nrd_domains.map 2>/dev/null || echo 0)
ok "Map seeded: ${DOMAIN_COUNT} domains"

# ── Step 9: Enable and start services ─────────────────────────────────────────
header "Step 9 — Enabling and starting services"

systemctl enable rspamd --now > /dev/null
systemctl reload rspamd
ok "Rspamd enabled and running"

systemctl reload postfix
ok "Postfix reloaded"

# ── Step 10: Install cron job ──────────────────────────────────────────────────
header "Step 10 — Installing daily cron job"

# Inject the chosen WINDOW_DAYS into the cron file
sed "s/^WINDOW_DAYS=.*/WINDOW_DAYS=${WINDOW_DAYS}/" \
  "$SCRIPT_DIR/cron/wf-nrd-rspamd" \
  > /etc/cron.d/wf-nrd-rspamd
chmod 644 /etc/cron.d/wf-nrd-rspamd
ok "Cron job installed → /etc/cron.d/wf-nrd-rspamd (runs daily at 02:15 UTC)"

# ── Write test helper script ───────────────────────────────────────────────────
cat > /usr/local/bin/wf-nrd-test.sh << 'TESTSCRIPT'
#!/usr/bin/env bash
# wf-nrd-test.sh — verify the WF_NRD_SENDER rule is firing
# Usage: wf-nrd-test.sh [domain]
DOMAIN="${1:-recently-registered.xyz}"
echo "Testing sender domain: ${DOMAIN}"
echo ""
printf "From: test@%s\nTo: user@localhost\nSubject: NRD Test\nDate: %s\nMessage-ID: <nrd-test@localhost>\n\nThis is a test.\n" \
  "$DOMAIN" "$(date -R)" | rspamc
TESTSCRIPT
chmod +x /usr/local/bin/wf-nrd-test.sh
ok "Test helper → /usr/local/bin/wf-nrd-test.sh"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""
echo "  NRD map:    /var/lib/rspamd/maps/nrd_domains.map"
echo "  Domains:    ${DOMAIN_COUNT}"
echo "  Window:     ${WINDOW_DAYS} days"
echo "  Cron:       daily at 02:15 UTC → /var/log/wf-nrd.log"
echo "  Rspamd UI:  http://localhost:11334"
echo ""
echo -e "  ${BOLD}Verify the rule is firing:${RESET}"
echo "  wf-nrd-test.sh recently-registered.xyz"
echo "  wf-nrd-test.sh whoisfreaks.com"
echo "  (look for WF_NRD_SENDER(5.00) in the first, absent in the second)"
echo ""