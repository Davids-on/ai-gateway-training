# Příprava VM účastníků skriptem `prepare.sh`

Podklad pro lektora. Skript [`deploy/prepare.sh`](../deploy/prepare.sh) **předem** provede na VM účastníka všechny přípravy z [části 1, kapitol 4–6](navod.md#4-krok-1-příprava-systému) a stáhne image pro celé školení. Na školení se tak nečeká, až se ~9 GB image stáhne přes sdílenou linku. Samotný stack **nespouští**, to zůstává na účastnících ([část 1, kap. 6.5](navod.md#65-spuštění) a dál).

Souhrn přípravy školení (VM, síť, klíče, checklist) je v [`prehled-skoleni.md`](prehled-skoleni.md).

---

## 1. Co skript dělá

Skript počítá i s **minimalizovanou instalací** Ubuntu Serveru (*Ubuntu Server (minimized)*), kde chybí `curl`, `jq`, `ping`, editor a další běžné nástroje. Všechno, co potřebuje on sám nebo návod, nejdřív doinstaluje:

| Skupina | Balíčky | K čemu |
|---|---|---|
| základní (vždy) | `ca-certificates`, `curl`, `gnupg`, `jq`, `openssl`, `iproute2`, `tzdata` | GPG klíč Dockeru a jeho ověření, testy API, JSON, generování tajemství, `ss`/`ip`, časová pásma |
| nástroje pro řešení problémů (vynechá `--no-extras`) | `iputils-ping`, `bind9-dnsutils`, `less`, `nano`, `git` | `ping`, `dig`/`nslookup`, prohlížení logů, úprava souborů, `git clone` repozitáře |
| Docker | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` | závislosti (`iptables`, …) doplní `apt` sám |

`ifconfig` ani `netstat` (balíček `net-tools`) neinstalujeme. Jsou zastaralé a návod používá jejich náhrady `ip a` a `ss` z `iproute2`. Ostatní nástroje použité v návodu (`psql`, Python) běží uvnitř kontejnerů, na hostu je není potřeba instalovat.

| Krok skriptu | Odpovídá v části 1 | Poznámka |
|---|---|---|
| 0/7 kontrola OS, místa na `/var` (min. 17 GB), RAM | kap. 3 | malé místo = konec s chybou |
| 1/7 `apt upgrade`, balíčky (viz tabulka výše), časové pásmo, porty 3000/4000/443/8443 | kap. 3.3, 4.1–4.3 | upgrade lze vynechat přes `--skip-upgrade`; obsazený port = varování |
| 2/7 Docker Engine + Compose z `download.docker.com` | kap. 5.1–5.3 | instaluje jen při shodě **fingerprintu GPG klíče** |
| 3/7 uživatel do skupiny `docker` | kap. 5.4 | projeví se po novém přihlášení |
| 4/7 `/opt/ai-stack`: `docker-compose.yml` a `config.yaml` **fáze `1-base`**, `.env.example`, `set-env.sh`, `use-stage.sh` | kap. 6.1, 6.3, 6.4 | existující `docker-compose.yml` a `config.yaml` **nikdy nepřepisuje** (stack už může být v pozdější fázi); pomocné skripty aktualizuje a starou verzi zazálohuje (`*.bak-<datum>`) |
| 5/7 `.env`: tajemství, `SERVER_IP`, `WEBUI_URL`, prázdný `OPENWEBUI_LITELLM_KEY`, API klíče | kap. 6.1, 6.2 | existující hodnoty **nikdy nepřepisuje**; `SERVER_IP` zjistí sám; na klíče se zeptá skrytě |
| 6/7 validace compose, stažení image **všech fází** (postgres, litellm, open-webui, caddy) + `alpine:3.24.3`, `caddy validate` | kap. 6.5, 7.3, 8.4; část 2: F0 | 3 pokusy při výpadku sítě |
| 7/7 testovací `docker run`, `docker info` | kap. 5.5 | |

**Co skript záměrně nedělá:**
- nespouští stack (`docker compose up`);
- nevytváří virtual key pro Open WebUI, protože k tomu musí běžet LiteLLM (část 1, kap. 7.1); v `.env` nechá prázdný řádek `OPENWEBUI_LITELLM_KEY=`;
- nepřepíná konfiguraci na fáze části 2, to dělají účastníci v modulech (`./use-stage.sh`);
- nepovyšuje už nainstalovaný Docker (viz kap. 4);
- nerestartuje server, jen upozorní, pokud je restart potřeba.

## 2. Spuštění

Na VM účastníka naklonujte repozitář do domovského adresáře účtu, pod kterým bude účastník pracovat, a jako tento uživatel se sudo spusťte skript **v interaktivním terminálu** (kvůli skrytému zadání klíčů; přes SSH tedy `ssh -t`):

```bash
git clone <URL_REPOZITÁŘE> ~/ai-gateway-training     # na minimalizované instalaci: sudo apt-get install -y git
cd ~/ai-gateway-training/deploy
sudo ./prepare.sh             # nebo: sudo ./prepare.sh --skip-upgrade
```

Cesta `~/ai-gateway-training` je důležitá: návod i skript `use-stage.sh` v části 2 hledají fáze konfigurace v `~/ai-gateway-training/deploy/stages`.

| Parametr | Význam |
|---|---|
| `--skip-upgrade` | bez `apt upgrade` (rychlejší, méně dat) |
| `--no-extras` | bez nástrojů pro řešení problémů (`ping`, `dig`, `less`, `nano`, `git`) |
| `--user JMÉNO` | vlastník `/opt/ai-stack`, pokud ho nejde zjistit ze `sudo` |
| `STACK_DIR=/cesta` (proměnná) | jiný cílový adresář, jen pro testování skriptu: `sudo STACK_DIR=/tmp/test ./prepare.sh` |

Pokud skript běží v terminálu, zeptá se postupně na tři klíče:
```
  OpenRouter API key (sk-or-v1-…), then press Enter.
  The key is not displayed. Empty Enter = fill it in later.
  OpenRouter API key:
  ...
  Anthropic API key (sk-ant-…), then press Enter.
  ...
  PromptGuard API key (pg_…), then press Enter.
```
- **OpenRouter** je potřeba pro část 1. Řídicí znaky (např. ze šipek) znamenají, že se klíč neuloží. Neočekávaný tvar (jiný prefix než `sk-or-v1-` nebo jiná délka než 73 znaků) jen vyvolá varování.
- **Anthropic** a **PromptGuard** jsou volitelné, potřebuje je až část 2. Prázdný Enter je přeskočí. Stack naběhne i bez nich: compose předá prázdný klíč Anthropic a místo prázdného klíče PromptGuard zástupnou hodnotu `not-configured` (LiteLLM by jinak s guardrailem `promptguard` nenastartoval).
- Chybějící klíče doplní účastník později příkazem `./set-env.sh NÁZEV` v `/opt/ai-stack`.

`SERVER_IP` (jde do TLS certifikátu Caddy v modulu F0) a `WEBUI_URL` skript vyplní podle IP adresy rozhraní s výchozí trasou.

**Očekávaný výstup (zkráceno):**
```
==> 0/7 Pre-flight checks
  [OK] Ubuntu 24.04.5 LTS
  [OK] Free space on /var: 39 GB
...
==> 2/7 Docker Engine and Docker Compose (official repository)
  [OK] Docker GPG key verified (9DC858229FC7DD38854AE2D88D81803C0EBFCD88)
  [OK] Docker Client 29.10.0 / Server 29.10.0
...
==> 4/7 Working directory /opt/ai-stack
  [OK] docker-compose.yml installed (stage 1-base)
  [OK] config.yaml installed (stage 1-base)
...
==> 6/7 Validate compose and pull images
  [OK] docker-compose.yml is valid
  Pulling: caddy:2.11.7
  Pulling: postgres:16.15
  Pulling: ghcr.io/berriai/litellm:v1.106.6
  Pulling: ghcr.io/open-webui/open-webui:v0.12.5
  Pulling: alpine:3.24.3
  [OK] All images are available locally:
...
  [OK] Caddyfile is valid (caddy:2.11.7)
...
Preparation complete. The stack is NOT running yet. Next steps (part 1 of the
guide, sections 6.5 and 7):
```

Skript vypisuje hlášky anglicky (`[OK]`, `[WARN]`, `[ERROR]`), stejně jako ostatní skripty v repu. Varování se na konci zopakují v souhrnu `Warnings:`.

Celý výstup se ukládá do `/var/log/ai-stack-prepare.log` (práva 600). API klíč se do logu nedostane, protože `read -s` ho nevypisuje.

### Kontrola po přípravě (na každé VM)

```bash
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}'   # 5 image
ls -la /opt/ai-stack                                               # compose, config, .env (600), set-env.sh, use-stage.sh
cut -d= -f1 /opt/ai-stack/.env | grep -v '^#' | grep .             # jen názvy proměnných
head -1 /opt/ai-stack/config.yaml                                  # ... STAGE 1-base ...
```

### VM klonované ze šablony

`prepare.sh` spusťte **na každém klonu** (aspoň krok s `.env`), jinak budou mít všechny VM stejná tajemství a `SERVER_IP` šablony. Image a repozitář v šabloně být můžou. IP adresa VM se po přípravě nesmí změnit (jde do `SERVER_IP` a později do certifikátu).

## 3. Co dělá účastník po přípravě

Návod ([část 1, kap. 6](navod.md#6-krok-3-litellm-proxy-a-postgresql)) má pro připravenou VM rámečky „VM připravená skriptem“. Ve zkratce:

1. Kapitoly 4 a 5 jen projde a ověří.
2. Kap. 6.1 a 6.2: jen ověření; chybějící klíč OpenRouteru doplní `./set-env.sh OPENROUTER_API_KEY`.
3. Kap. 6.5: `OPENWEBUI_LITELLM_KEY=pending docker compose up -d postgres litellm` (stejně jako při ruční cestě).
4. Kap. 7.1: vytvoří virtual key, ten se rourou zapíše do existujícího řádku (`… | ./set-env.sh OPENWEBUI_LITELLM_KEY`), a kap. 7.3 `docker compose up -d`.

> [!NOTE]
> Open WebUI při prvním startu ještě stáhne z Hugging Face embedding model (~90 MB). Ten se stahuje až do volume běžícího kontejneru, takže ho skript předem nestáhne. `huggingface.co` proto musí být dostupný i na školení.

## 4. Opakované spuštění a server s běžícím stackem

Skript je **idempotentní**. Po přerušení (výpadek sítě při stahování) ho stačí spustit znovu. Na serveru, kde stack už běží, nic nepřepíše ani nerestartuje: hodnoty v `.env` i konfigurační soubory zůstanou, i když je stack v pozdější fázi. Referenční lab: `.env` měl před během i po něm stejný kontrolní součet a kontejnery běžely bez přerušení.

> [!WARNING]
> **Upgrade Dockeru = restart všech kontejnerů.** Při upgradu balíčku `docker-ce` se restartuje démon `dockerd` a s ním všechny kontejnery. Díky `restart: unless-stopped` se samy vrátí, ale LiteLLM a Open WebUI jsou zhruba minutu nedostupné. Přesně to se stalo při prvním testu skriptu v referenčním labu: `apt-get install docker-ce` povýšil 29.9.3 → 29.10.0. Skript proto už nainstalovaný Docker **nepovyšuje**: instaluje s `apt-get install --no-upgrade` a při `apt upgrade` Docker balíčky dočasně podrží (`apt-mark hold`). Docker povyšujte vědomě v servisním okně: `sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.

## 5. Řešení problémů

| Příznak | Příčina / řešení |
|---|---|
| `Run with sudo` / `Cannot determine the regular user` | Skript potřebuje root, ale zároveň musí znát uživatele, kterému patří `/opt/ai-stack`. Spouštějte `sudo ./prepare.sh` z běžného účtu, ne z `sudo -i`. Případně použijte `--user JMÉNO`. |
| `Missing …/stages/1-base/docker-compose.yml` | Skript neběží z adresáře `deploy/` naklonovaného repozitáře (potřebuje i `stages/`, `set-env.sh`, `use-stage.sh`). |
| `Docker GPG key fingerprint mismatch` | Stažený klíč není klíč Dockeru (proxy, MITM, změna klíče). Neinstalujte, ověřte fingerprint v [oficiální dokumentaci](https://docs.docker.com/engine/install/ubuntu/). |
| `Attempt 1/3 failed: docker pull …` | Výpadek sítě nebo rate limit registru. Skript to zkusí znovu, případně ho spusťte celý znovu; už stažené vrstvy se nestahují. |
| `No terminal – OPENROUTER_API_KEY is empty` | Skript běžel bez TTY (např. `ssh server 'sudo ./prepare.sh'`). Klíč doplňte `./set-env.sh OPENROUTER_API_KEY`, nebo spusťte `ssh -t`. |
| `Port 443 is in use` | Na serveru už běží jiný web server (apache2, nginx). Caddy by v modulu F0 nenastartoval: `sudo ss -tlnp 'sport = :443'`, cizí službu zastavte nebo přesuňte. |
| `Caddyfile is not valid` | Chyba v `deploy/stages/5-local-model/Caddyfile` (překlep, chybějící závorka). Řádek s chybou je v hlášce, oprava v repu a znovu spustit skript. |
| `Cannot detect the server IP` | Server nemá výchozí trasu. Doplňte `SERVER_IP` a `WEBUI_URL` v `.env` ručně (`./set-env.sh SERVER_IP <IP>`). |
