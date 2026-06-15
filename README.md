# wf-rspamd-postfix-nrd-feed

> Block emails from newly registered domains in Rspamd + Postfix using the WhoisFreaks NRD feed. A rolling-window domain map, daily auto-refresh via cron, and hot-reload via inotify. No service restarts, no Docker required.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/WhoisFreaks/wf-rspamd-postfix-nrd-feed/blob/main/LICENSE)
[![Rspamd](https://img.shields.io/badge/rspamd-3.x-FF6600.svg)](https://rspamd.com/)
[![Ubuntu](https://img.shields.io/badge/ubuntu-22.04%2B-E95420.svg)](https://ubuntu.com/)

---

## Why

Newly registered domains (NRDs) are disproportionately weaponized for spam, phishing, and business email compromise. Palo Alto Networks' Unit 42 found that [more than 70% of domains registered in the previous 32 days were malicious, suspicious, or not safe for work](https://unit42.paloaltonetworks.com/newly-registered-domains-malicious-abuse-by-bad-actors/), the window before any curated threat feed picks them up.

This repo wires the [WhoisFreaks NRD feed](https://whoisfreaks.com/products/newly-registered-domains.html) into Rspamd as a rolling-window sender-domain blocklist. Emails arriving from a domain registered within your chosen window receive a raised spam score, enough to flag them without outright rejecting legitimate new senders.

## How it works

```
WhoisFreaks NRD API
        │
        ▼
  wf-nrd-fetch.sh          ← runs daily via cron at 02:15 UTC
  (fetches gTLD + ccTLD,
   maintains rolling cache,
   atomic rename → map file)
        │
        ▼
/var/lib/rspamd/maps/
  nrd_domains.map           ← plain domain list, hot-reloaded by Rspamd
        │
        ▼
Rspamd multimap rule        ← WF_NRD_SENDER symbol, +5.0 spam score
        │
        ▼
Postfix milter              ← scoring decision applied at SMTP layer
```

Rspamd monitors the map file via inotify. When the cron job atomically replaces it, Rspamd hot-reloads the new list in the background. No restart, no dropped mail.

## Features

- **Rolling window:** keep 5, 10, or 30 days of NRDs. One env variable.
- **Per-day caching:** only the newest day's files download each night. No redundant API calls.
- **Atomic map updates:** temp file plus rename. Rspamd always reads a complete, consistent snapshot.
- **inotify hot-reload:** map changes are picked up automatically. No `rspamc reload` in cron.
- **API key isolation:** key lives in `/etc/whoisfreaks/apikey` (chmod 600), never in scripts or config.
- **Score mode by default:** raises spam score without hard-rejecting. Switch to reject only after monitoring false positives.
- **Native Ubuntu install:** `apt install rspamd postfix`. No Docker, no containers.

## Prerequisites

- Ubuntu 22.04 or later
- A [WhoisFreaks API key](https://whoisfreaks.com/) with NRD feed access
- `curl`, `bash`, `cron` (all pre-installed on Ubuntu)

## Quick start

### Automated (recommended)

Clone the repo and run the installer. It handles everything:

```bash
git clone https://github.com/WhoisFreaks/wf-rspamd-postfix-nrd-feed.git
cd wf-rspamd-postfix-nrd-feed
sudo ./install.sh
```

The script prompts for your WhoisFreaks API key, installs Rspamd and Postfix, copies all config files, seeds the map, and starts all services. Done in under 5 minutes.

Optional environment variables:

```bash
sudo WINDOW_DAYS=30 MAIL_DOMAIN=mail.example.com ./install.sh
```

---

### Manual (step by step)

If you prefer to install each piece yourself:

#### 1. Install Rspamd and Postfix

```bash
# Add the official Rspamd repository (Ubuntu's built-in package is outdated)
sudo apt install -y lsb-release wget gnupg
wget -qO- https://rspamd.com/apt-stable/gpg.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/rspamd.gpg

echo "deb [signed-by=/usr/share/keyrings/rspamd.gpg] \
https://rspamd.com/apt-stable/ $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/rspamd.list

sudo apt update
sudo apt install -y rspamd postfix

# Create the maps directory
sudo mkdir -p /var/lib/rspamd/maps
sudo chown _rspamd:_rspamd /var/lib/rspamd/maps

sudo systemctl enable rspamd --now
```

During the Postfix install prompt, choose **Internet Site** and enter your mail domain.

#### 2. Store your API key

```bash
sudo mkdir -p /etc/whoisfreaks
echo "YOUR_API_KEY_HERE" | sudo tee /etc/whoisfreaks/apikey > /dev/null
sudo chmod 600 /etc/whoisfreaks/apikey
```

#### 3. Install the fetch script

```bash
sudo cp fetch/wf-nrd-fetch.sh /usr/local/bin/wf-nrd-fetch.sh
sudo chmod +x /usr/local/bin/wf-nrd-fetch.sh
```

#### 4. Run the script once to seed the map

```bash
sudo WINDOW_DAYS=10 /usr/local/bin/wf-nrd-fetch.sh
```

First run downloads all days in your window (2 to 4 minutes). Subsequent daily runs download only the newest files.

Expected output:

```
[wf-nrd] Starting NRD fetch (window: 10 days)
[wf-nrd] Fetching gtld for 2026-06-10...
[wf-nrd] Fetched gtld: 309525 domains
[wf-nrd] Fetching cctld for 2026-06-10...
[wf-nrd] Fetched cctld: 64745 domains
[wf-nrd] Map updated: 3014872 unique domains (10-day window)
[wf-nrd] Done.
```

> The script always fetches **yesterday's** date. WhoisFreaks publishes the previous day's registrations after consolidation. Fetching today's date returns empty or 404.

#### 5. Install the Rspamd multimap rule

```bash
sudo cp rspamd/multimap.conf /etc/rspamd/local.d/multimap.conf
sudo cp rspamd/worker-proxy.inc /etc/rspamd/local.d/worker-proxy.inc
sudo systemctl reload rspamd
```

#### 6. Connect Postfix to Rspamd

```bash
sudo postconf -e 'milter_protocol = 6'
sudo postconf -e 'milter_default_action = accept'
sudo postconf -e 'smtpd_milters = inet:localhost:11332'
sudo postconf -e 'non_smtpd_milters = inet:localhost:11332'
sudo systemctl reload postfix
```

#### 7. Install the cron job

Edit `cron/wf-nrd-rspamd` and set `WINDOW_DAYS` to your preference, then:

```bash
sudo cp cron/wf-nrd-rspamd /etc/cron.d/wf-nrd-rspamd
```

The job runs at 02:15 UTC every day and logs to `/var/log/wf-nrd.log`.

## Configuration

| Variable       | Default                   | Description                 |
| -------------- | ------------------------- | --------------------------- |
| `WINDOW_DAYS`  | `10`                      | Rolling window size in days |
| `API_KEY_FILE` | `/etc/whoisfreaks/apikey` | Path to the API key file    |

**Choosing a window size:**

Map sizes are approximate and track daily registration volume, which varies day to day. The WhoisFreaks feed publishes a large volume of new gTLD and ccTLD domains each day, so window size drives map size directly.

| Window  | Domains (approx.) | Use when                                    |
| ------- | ----------------- | ------------------------------------------- |
| 5 days  | ~1.5M             | Fewest false positives; good starting point |
| 10 days | ~3M               | Balanced default                            |
| 30 days | ~9M               | Maximum coverage; monitor false positives   |

## Verification

Check that the symbol fires on a test message:

```bash
echo "Test" | rspamc -F test@recently-registered.xyz
```

Look for `WF_NRD_SENDER(5.00)` in the output. Then confirm Postfix is connected:

```bash
postconf smtpd_milters          # should show inet:localhost:11332
sudo systemctl status rspamd    # should show active (running)
```

Watch live scoring in the Rspamd log:

```bash
sudo tail -f /var/log/rspamd/rspamd.log
```

The Rspamd web UI is available at `http://localhost:11334`.

## Tuning the score

The default `score = 5.0` raises the spam score without rejecting. Rspamd's default reject threshold is 15.0. Adjust in `rspamd/multimap.conf`:

```
score = 3.0   # Softer. Flag only when combined with other signals
score = 5.0   # Default. Adds spam header on its own
score = 10.0  # Aggressive. Near-reject when combined with one other signal
```

To hard-reject at SMTP time, uncomment the `prefilter + action = "reject"` block in `multimap.conf`, but only after monitoring false positives for at least two weeks.

## Troubleshooting

**`[wf-nrd] ERROR: API key file not found`**. Run step 2 (store the API key) and ensure the path matches `API_KEY_FILE`.

**`WF_NRD_SENDER` symbol not appearing**. Run `rspamadm configtest` to check for config errors. Confirm `/var/lib/rspamd/maps/nrd_domains.map` exists and is readable by `_rspamd`.

**Map not updating after cron**. Check `/var/log/wf-nrd.log` for errors. Verify the cache directory exists: `ls /var/cache/wf-nrd/`.

**Postfix not connecting to Rspamd**. Confirm Rspamd is listening: `ss -tlnp | grep 11332`. Check `milter_default_action` in `postconf -n`.

**High false positive rate**. Reduce `WINDOW_DAYS` to 5, or lower the score to 3.0 so the rule only tips the balance when combined with other signals.

## Repository structure

```
wf-rspamd-postfix-nrd-feed/
├── install.sh                 # Single-command installer
├── fetch/
│   └── wf-nrd-fetch.sh        # NRD feed fetch + map rebuild script
├── rspamd/
│   ├── multimap.conf          # Multimap rule (WF_NRD_SENDER)
│   └── worker-proxy.inc       # Postfix milter proxy worker config
├── postfix/
│   └── main.cf.snippet        # Postfix milter settings
├── cron/
│   └── wf-nrd-rspamd          # Daily cron job
├── .gitignore
└── README.md
```

## License

[MIT](https://github.com/WhoisFreaks/wf-rspamd-postfix-nrd-feed/blob/main/LICENSE)

## Related integrations

This repository is part of a series integrating the WhoisFreaks NRD feed into common security tools:

- [wf-pihole-nrd-feed](https://github.com/WhoisFreaks/wf-pihole-nrd-feed): Pi-hole DNS blocklist
- [wf-adguard-nrd-feed](https://github.com/WhoisFreaks/wf-adguard-nrd-feed): AdGuard Home DNS blocklist
- **wf-rspamd-postfix-nrd-feed** (this repo): Rspamd + Postfix email filter
