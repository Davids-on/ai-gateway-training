# AI gateway v labu: LiteLLM + Open WebUI v Dockeru

Školicí návod. Na čisté VM s Ubuntu Server 24.04 postavíme vlastní **AI gateway** (LiteLLM) a nad ní webové chatovací rozhraní (Open WebUI). Jazykový model nepoběží lokálně. Použijeme bezplatný model přes službu OpenRouter.

> **Konvence:**
> - Příkazy se spouštějí na serveru jako běžný uživatel se sudo.
> - `<IP_SERVERU>` nahraďte IP adresou své VM. V referenčním labu je to `192.0.2.10`.
> - Hodnoty ve tvaru `<NĚCO>` jsou placeholdery. Skutečná tajemství do návodu ani do gitu nikdy nepatří.

**Obsah:**
1. [Úvod](#1-úvod)
2. [Prerekvizity](#2-prerekvizity)
3. [Krok 0: Průzkum výchozího stavu](#3-krok-0-průzkum-výchozího-stavu)
4. [Krok 1: Příprava systému](#4-krok-1-příprava-systému)
5. [Krok 2: Docker Engine a Docker Compose](#5-krok-2-docker-engine-a-docker-compose)
6. [Krok 3: LiteLLM Proxy a PostgreSQL](#6-krok-3-litellm-proxy-a-postgresql)
7. [Krok 4: Open WebUI](#7-krok-4-open-webui)
8. [Krok 5: Provoz](#8-krok-5-provoz)
9. [Bezpečnostní poznámky](#9-bezpečnostní-poznámky)
10. [Další kroky](#10-další-kroky)
11. [Odkazy](#11-odkazy)
12. [Příloha A: Automatická příprava serveru (`prepare.sh`)](#12-příloha-a-automatická-příprava-serveru-preparesh)

Hotové konfigurační soubory jsou v repozitáři v adresáři [`deploy/`](../deploy/). Komentáře v nich jsou anglicky, ukázky v návodu mají pro přehlednost komentáře česky. Všechny příkazy použité při přípravě referenčního labu jsou v [`command-log.md`](command-log.md).

> **Zkratka pro lektora:** Kroky 1–3 (kapitoly 4–6 až po stažení image) umí provést skript [`deploy/prepare.sh`](../deploy/prepare.sh). Hodí se k přípravě VM před školením, aby se ~9 GB image nestahovalo až na místě. Viz [Příloha A](#12-příloha-a-automatická-příprava-serveru-preparesh).

---

## 1. Úvod

### 1.1 Co je LLM

**LLM (Large Language Model)** je jazykový model natrénovaný na obrovském množství textu, který na vstup (*prompt*) generuje textovou odpověď (*completion*). Příklady: GPT (OpenAI), Claude (Anthropic), Gemini (Google), Llama (Meta), Nemotron (NVIDIA).

Aplikace s modelem obvykle komunikují přes **HTTP API**, nejčastěji ve formátu kompatibilním s OpenAI (`POST /v1/chat/completions`). Text se účtuje po **tokenech** (zhruba části slov), zvlášť vstupní a výstupní.

### 1.2 Proč AI gateway

Když ve firmě začne LLM používat víc lidí a aplikací, rychle vznikne chaos: každý má vlastní API klíč, nikdo neví, kolik se utratilo, a výměna poskytovatele znamená úpravu všech aplikací. **AI gateway** je centrální proxy mezi klienty a poskytovateli modelů. Přináší:

| Funkce | Co to znamená v praxi |
|---|---|
| **Centrální správa klíčů** | Klíče k poskytovatelům (OpenAI, Anthropic, OpenRouter…) zná jen gateway. Uživatelé a aplikace dostanou vlastní *virtuální klíče*, které lze kdykoli zneplatnit. |
| **Rate limiting a budgety** | Omezení počtu požadavků či tokenů za minutu a měsíční limit útraty na klíč, uživatele nebo tým. |
| **Logování a audit** | Kdo, kdy, jaký model, kolik tokenů, případně i obsah promptů (pozor na GDPR). |
| **Cost tracking** | Přehled útraty podle klíčů, týmů a modelů. |
| **Přepínání poskytovatelů** | Klienti volají jedno API se stabilním názvem modelu. Za ním lze vyměnit poskytovatele, nastavit fallback nebo load balancing bez zásahu do klientů. |

### 1.3 Co je LiteLLM

[LiteLLM](https://docs.litellm.ai/) je open-source AI gateway (*LiteLLM Proxy Server*). Navenek poskytuje **API kompatibilní s OpenAI** a uvnitř ho překládá na API více než 100 poskytovatelů. S databází PostgreSQL navíc umí virtuální klíče, uživatele, týmy, budgety, spend tracking a webové **Admin UI**.

### 1.4 Co je Open WebUI

[Open WebUI](https://docs.openwebui.com/) je self-hosted webové rozhraní ve stylu ChatGPT. Podporuje uživatele a role, historii konverzací, nahrávání dokumentů (RAG) a další funkce. K modelům se připojuje přes OpenAI-kompatibilní API, v našem případě přes LiteLLM.

### 1.5 Docker a Docker Compose ve zkratce

- **Image** je neměnná šablona aplikace (souborový systém a metadata), například `postgres:16`.
- **Kontejner** je běžící instance image, izolovaný proces s vlastním souborovým systémem a sítí.
- **Volume** je perzistentní úložiště mimo kontejner. Data v něm přežijí smazání i aktualizaci kontejneru.
- **Registry** je úložiště image, například Docker Hub nebo GitHub Container Registry (`ghcr.io`).
- **Docker Compose** popisuje celou aplikaci (víc kontejnerů, sítě, volumes) jedním YAML souborem `docker-compose.yml` a ovládá ji příkazy `docker compose up -d`, `down`, `logs`…

### 1.6 Architektura

```mermaid
flowchart LR
    U["👤 Uživatel<br/>(prohlížeč)"] -->|"HTTP :3000"| OW["Open WebUI<br/>kontejner open-webui:8080"]
    A["🛠️ Admin / aplikace<br/>(curl, skripty)"] -->|"HTTP :4000<br/>/v1, /ui"| LL
    subgraph host["VM Ubuntu 24.04 – Docker, síť ai-net"]
        OW -->|"http://litellm:4000/v1<br/>virtual key"| LL["LiteLLM Proxy<br/>kontejner litellm:4000"]
        LL -->|"SQL :5432<br/>(jen interní síť)"| PG[("PostgreSQL<br/>klíče, spend, logy")]
    end
    LL -->|"HTTPS<br/>API klíč poskytovatele"| OR["☁️ OpenRouter<br/>→ NVIDIA Nemotron 3 Ultra (free)"]
```

Tok požadavku: uživatel napíše dotaz v Open WebUI → Open WebUI ho pošle na LiteLLM a autentizuje se *virtuálním klíčem* → LiteLLM ověří klíč v Postgresu, zavolá OpenRouter se *skutečným* API klíčem a zapíše spotřebu → odpověď se vrátí uživateli.

---

## 2. Prerekvizity

### 2.1 Virtuální stroj

| Položka | Hodnota |
|---|---|
| OS | Ubuntu Server 24.04 LTS (čistá instalace) |
| CPU / RAM / disk | 2 vCPU / 8 GB / 40 GB SSD |
| Přístup | SSH, uživatel s právy `sudo` |
| Síť | přístup na internet (apt repozitáře, `download.docker.com`, `ghcr.io`, Docker Hub, `openrouter.ai`) |

> Model běží v cloudu, takže VM nepotřebuje GPU. Největší nároky má Open WebUI (image kolem 4 GB, za běhu 1–2 GB RAM). Referenční lab běžel i se 4 GB RAM a swapem, ale 8 GB je pohodlnější.

### 2.2 Účet a API klíč na OpenRouter.ai

[OpenRouter](https://openrouter.ai/) je agregátor, který přes jedno API a jeden klíč zpřístupňuje stovky modelů různých poskytovatelů. Část modelů je **zdarma** (v ID mají příponu `:free`). Pro školení je to ideální, protože nikdo nemusí platit.

**Postup:**

1. Otevřete <https://openrouter.ai/> a klikněte na **Sign up** / **Sign in**. Registrovat se lze přes Google, GitHub nebo e-mail. U e-mailu potvrďte ověřovací odkaz.
   [SCREENSHOT: úvodní stránka OpenRouter s tlačítkem Sign in]
2. **Najděte model.** V menu **Models** vyhledejte `Nemotron 3 Ultra` a otevřete variantu **NVIDIA: Nemotron 3 Ultra (free)**. Volné modely najdete i filtrem ceny *Free*. Zkopírujte si **ID modelu**:
   ```
   nvidia/nemotron-3-ultra-550b-a55b:free
   ```
   Přípona `:free` je důležitá. Bez ní se použije placená varianta téhož modelu.
   [SCREENSHOT: stránka modelu NVIDIA: Nemotron 3 Ultra (free) se zvýrazněným ID modelu]
3. **Zkontrolujte nastavení soukromí.** V **Settings → Privacy** (<https://openrouter.ai/settings/privacy>) určujete, které poskytovatele smí OpenRouter použít podle jejich datové politiky. Free endpointy často patří poskytovatelům, kteří si prompty mohou ukládat nebo je použít k trénování. Pokud je máte zakázané a OpenRouter nenajde vhodného poskytovatele, vrátí chybu typu *„No endpoints found matching your data policy“*. V takovém případě je povolte. Důsledek: **do free modelů nepište citlivá ani firemní data.**
   [SCREENSHOT: Settings → Privacy s povolenými free endpointy]
4. **Vytvořte API klíč.** Otevřete **Keys** (<https://openrouter.ai/settings/keys>) → **Create Key**.
   - *Name*: např. `litellm-lab`
   - *Credit limit*: volitelné. U čistě free použití můžete nastavit `0`, aby klíč nemohl nic utratit.
   - Klikněte na **Create** a klíč (začíná `sk-or-v1-…`) si hned zkopírujte. **Zobrazí se jen jednou.** Pokud ho ztratíte, vytvořte nový a starý smažte.
   [SCREENSHOT: dialog Create Key a zobrazený klíč (rozmazaný)]
5. **Limity free modelů** (podle [dokumentace OpenRouter](https://openrouter.ai/docs/api/reference/limits)):
   - 20 požadavků za minutu
   - **50 požadavků za den**, pokud účet nikdy nekoupil kredity
   - 1000 požadavků za den, pokud účet koupil alespoň 10 kreditů (≈ 10 USD)

   Pro školení stačí 50 požadavků denně na studenta. Při zátěžových testech ale počítejte s chybou `429 Too Many Requests`.
6. Klíč si dočasně uložte do správce hesel. Na server ho vložíte v kapitole 6. Nikam jinam ho nepište: ne do chatu, ne do gitu, ne do sdílených dokumentů.

### 2.3 Přehled služeb, portů a adresářů

| Služba | Kontejner | Port na hostu | Port v kontejneru | Účel |
|---|---|---|---|---|
| Open WebUI | `open-webui` | **3000** | 8080 | webové chatovací rozhraní pro uživatele |
| LiteLLM Proxy | `litellm` | **4000** | 4000 | OpenAI-kompatibilní API (`/v1`), Admin UI (`/ui`) |
| PostgreSQL | `postgres` | – (nevystaven) | 5432 | databáze LiteLLM (klíče, spend, logy) |

| Cesta | Obsah |
|---|---|
| `/opt/ai-stack/` | pracovní adresář celého stacku |
| `/opt/ai-stack/docker-compose.yml` | definice služeb |
| `/opt/ai-stack/config.yaml` | konfigurace LiteLLM (modely) |
| `/opt/ai-stack/.env` | **tajemství** (klíče, hesla), práva `600` |
| Docker volume `ai-stack_pgdata` | data PostgreSQL |
| Docker volume `ai-stack_open-webui-data` | data Open WebUI (uživatelé, chaty, nastavení) |

---

## 3. Krok 0: Průzkum výchozího stavu

**Účel:** Než cokoli nainstalujeme, ověříme, že VM odpovídá zadání, má přístup na internet a nekoliduje s ničím, co tam už je (jiný Docker, obsazené porty). Ušetří to hledání chyb později.

### 3.1 Systém a prostředky

```bash
lsb_release -ds; uname -r; nproc; free -h; df -h /
sudo -n true && echo SUDO_OK
timedatectl | head -5
```

**Očekávaný výstup (zkráceně):**
```
Ubuntu 24.04 LTS
6.8.0-xxx-generic
2
Mem:           7.7Gi  ...
/dev/sda2        39G  ...
SUDO_OK
                Time zone: Etc/UTC (UTC, +0000)
```

### 3.2 Kolize: existující Docker / Podman

```bash
dpkg -l | grep -Ei "docker|containerd|runc|podman" || echo none
snap list 2>/dev/null | grep -i docker || echo no-snap-docker
```

**Očekáváno:** `none` a `no-snap-docker`.
Pokud je nainstalovaný `docker.io` z Ubuntu nebo snap `docker`, odstraňte ho před kapitolou 5 (postup je tam uvedený). Dvě instalace Dockeru vedle sebe způsobují nepředvídatelné chyby.

### 3.3 Obsazené porty

```bash
sudo ss -tlnp | grep -E ":(3000|4000|5432)\b" || echo ports-free
```

**Očekáváno:** `ports-free`. Pokud port něco drží, poslední sloupec ukáže proces. Buď ho zastavte, nebo později v compose změňte port na hostu.

### 3.4 Firewall

```bash
sudo ufw status
```

Na čisté instalaci Ubuntu 24.04 bývá výsledek `Status: inactive`.

### 3.5 Přístup na internet

```bash
for u in http://archive.ubuntu.com/ubuntu/ https://download.docker.com/linux/ubuntu/ \
         https://ghcr.io/v2/ https://registry-1.docker.io/v2/ https://openrouter.ai/api/v1/models; do
  printf "%-45s -> " "$u"; curl -s -o /dev/null -m 10 -w "%{http_code}\n" "$u"
done
```

**Očekávaný výstup:**
```
http://archive.ubuntu.com/ubuntu/             -> 200
https://download.docker.com/linux/ubuntu/     -> 200
https://ghcr.io/v2/                           -> 401
https://registry-1.docker.io/v2/              -> 401
https://openrouter.ai/api/v1/models           -> 200
```
`401` u registrů je **v pořádku**. Registry odpovídá a jen požaduje token, který si Docker sám vyžádá.

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| `000` u všech URL | Nefunguje DNS nebo výchozí brána: `resolvectl status`, `ip route`. Ve firemní síti může být nutná HTTP proxy. |
| `000` jen u některých | Blokuje to firewall nebo proxy v síti. Požádejte správce sítě o povolení domén. |
| `sudo: a password is required` | Uživatel nemá sudo bez hesla. Spouštějte `sudo` interaktivně. |

---

## 4. Krok 1: Příprava systému

### 4.1 Aktualizace balíčků

**Účel:** Začínáme z aktuálního, opraveného systému. Bezpečnostní záplaty a novější jádro předejdou chybám, které už jsou dávno opravené.

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
```

- `DEBIAN_FRONTEND=noninteractive` potlačí interaktivní dialogy.
- `--force-confdef --force-confold` zachovají vaše konfigurační soubory, pokud se balíček ptá, zda je přepsat.

**Očekávaný výstup (konec):**
```
... upgraded, ... newly installed, 0 to remove and 3 not upgraded.
```

> Hláška „*N not upgraded*“ je u Ubuntu 24.04 běžná. Jde o **phased updates**: Canonical vydává některé aktualizace postupně jen části strojů. Takové balíčky se doinstalují samy později. Nevynucujte je.

**Restart, pokud je potřeba:**
```bash
ls /var/run/reboot-required && cat /var/run/reboot-required.pkgs
sudo systemctl reboot
```
Pokud soubor `/var/run/reboot-required` existuje (typicky po aktualizaci jádra, `dbus`, `apparmor` nebo `systemd`), restartujte. Po restartu se znovu připojte přes SSH.

### 4.2 Časové pásmo

**Účel:** Logy kontejnerů, záznamy o spotřebě a zálohy budou mít čas, kterému rozumíme. Synchronizovaný čas je navíc nutný pro TLS certifikáty a později pro SSO (Kerberos, OIDC tokeny).

```bash
sudo timedatectl set-timezone Europe/Prague
timedatectl
```

**Očekávaný výstup:**
```
               Local time: Mon 2026-11-16 07:58:30 CET
                Time zone: Europe/Prague (CET, +0100)
System clock synchronized: yes
              NTP service: active
```

> Hned po restartu může chvíli svítit `System clock synchronized: no`. `systemd-timesyncd` potřebuje několik desítek sekund na první kontakt s NTP serverem. Ověřte znovu za minutu.

### 4.3 Základní nástroje

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install curl jq ca-certificates gnupg openssl
```

| Nástroj | K čemu ho potřebujeme |
|---|---|
| `curl` | stažení GPG klíče Dockeru, testování API LiteLLM |
| `jq` | čitelné formátování a filtrování JSON odpovědí |
| `ca-certificates` | ověřování HTTPS certifikátů (apt repozitář Dockeru, OpenRouter) |
| `gnupg` | práce s GPG klíči apt repozitářů |
| `openssl` | generování náhodných tajemství (master key, salt key) |

**Ověření:**
```bash
curl --version | head -1; jq --version; openssl version
```
```
curl 8.5.0 (x86_64-pc-linux-gnu) ...
jq-1.7
OpenSSL 3.0.13 30 Jan 2024 ...
```

### 4.4 Lokální firewall

**Rozhodnutí pro lab:** Lokální firewall (`ufw`) necháváme **vypnutý**. Jde o izolovaný lab a chceme se soustředit na AI stack.

```bash
sudo ufw status          # na čisté instalaci: Status: inactive
sudo ufw disable         # jen pokud je aktivní
```

> ⚠️ **Docker a ufw:** I se zapnutým `ufw` by porty publikované Dockerem (`ports:` v compose) byly z ostatních počítačů **stejně dostupné**. Docker si zapisuje vlastní pravidla do iptables/nftables (chain `DOCKER`) a ta se vyhodnocují dřív než pravidla ufw. Pro produkci proto:
> - publikujte porty jen na konkrétní IP, např. `127.0.0.1:4000:4000`, a ven vystavte pouze reverse proxy;
> - nebo filtrujte v chainu `DOCKER-USER`, případně na síťovém firewallu před serverem.
>
> Viz [Docker docs – Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| `Could not get lock /var/lib/dpkg/lock-frontend` | Na pozadí běží `unattended-upgrades` (typicky po prvním startu VM). Počkejte, až doběhne: `ps aux \| grep -i apt`. Zámky nemažte ručně. |
| `apt-get update` hlásí `Temporary failure resolving` | Nefunguje DNS: `resolvectl status`. |
| `System clock synchronized: no` i po několika minutách | NTP (UDP 123) je blokované. Nastavte interní NTP server (např. DC) v `/etc/systemd/timesyncd.conf` → `NTP=...` a spusťte `sudo systemctl restart systemd-timesyncd`. |

---

## 5. Krok 2: Docker Engine a Docker Compose

**Účel:** Celý AI stack poběží v kontejnerech. Instalujeme **Docker Engine z oficiálního apt repozitáře Dockeru**, ne balíček `docker.io` z Ubuntu ani snap.

| Zdroj | Proč ho nepoužijeme |
|---|---|
| `docker.io` (Ubuntu) | Starší verze. Compose plugin bývá zastaralý nebo chybí. |
| `snap install docker` | Omezení confinementu (přístup do `/opt`, bind mounty), jiné cesty a jiné chování při aktualizacích. |
| **`download.docker.com`** | Aktuální verze přímo od Dockeru včetně pluginů `compose` a `buildx`. Tento postup popisuje oficiální dokumentace. |

Dokumentace: [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)

### 5.1 Odstranění případných starých balíčků

Na čisté VM nic nenajde. Pokud v kroku 0 vyšel nějaký konflikt, odstraňte ho:

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null
done
sudo snap remove docker 2>/dev/null || true
```

### 5.2 Přidání apt repozitáře Dockeru

```bash
# GPG klíč, kterým Docker podepisuje balíčky
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Definice repozitáře (nový formát deb822)
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
```

**Ověření:**

```bash
gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc | sed -n 2p
```
```
      9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88
```
Fingerprint musí odpovídat hodnotě v oficiální dokumentaci.

Ve výstupu `apt-get update` musí být řádky s `download.docker.com`:
```
Get:5 https://download.docker.com/linux/ubuntu noble InRelease [48.5 kB]
Get:6 https://download.docker.com/linux/ubuntu noble/stable amd64 Packages [73.8 kB]
```

> **Proč `Signed-By`:** Klíč Dockeru platí jen pro tento repozitář, ne pro všechny. Kdyby někdo podvrhl balíček v jiném repozitáři, klíč Dockeru ho „nepodepíše“.

### 5.3 Instalace

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

| Balíček | Obsah |
|---|---|
| `docker-ce` | Docker Engine, démon `dockerd` |
| `docker-ce-cli` | klient, příkaz `docker` |
| `containerd.io` | container runtime, na kterém Docker staví |
| `docker-buildx-plugin` | `docker buildx`, moderní sestavování image |
| `docker-compose-plugin` | `docker compose` (Compose v2+, bez pomlčky) |

Služba `docker` se po instalaci sama spustí a je povolená po startu systému:

```bash
systemctl is-enabled docker containerd; systemctl is-active docker
```
```
enabled
enabled
active
```

### 5.4 Uživatel ve skupině `docker`

**Účel:** Bez `sudo` ovládá Docker jen root. Přidáním do skupiny `docker` získá uživatel přístup k socketu `/var/run/docker.sock`.

```bash
sudo usermod -aG docker $USER
```

Členství ve skupině se projeví **až v novém přihlášení**. Odhlaste se, znovu se připojte přes SSH a ověřte:

```bash
id -nG
```
```
labadmin adm cdrom sudo dip plugdev lxd docker
```

> ⚠️ **Bezpečnostní dopad: skupina `docker` = root.**
> Kdo smí mluvit s Docker démonem, může spustit kontejner s připojeným kořenovým souborovým systémem hosta a v něm dělat cokoli jako root:
> ```bash
> docker run --rm -it -v /:/host alpine chroot /host   # = root shell na hostu
> ```
> Proto:
> - do skupiny `docker` přidávejte jen ty, kdo by stejně měli `sudo`;
> - socket `/var/run/docker.sock` nikdy nevystavujte po síti ani do kontejnerů, které ho nepotřebují;
> - kde root ekvivalent nechcete, zvažte [rootless mode](https://docs.docker.com/engine/security/rootless/).
>
> Více: [Docker security](https://docs.docker.com/engine/security/), [Linux post-installation steps](https://docs.docker.com/engine/install/linux-postinstall/).

### 5.5 Ověření

```bash
docker version --format "Client {{.Client.Version}} / Server {{.Server.Version}}"
docker compose version
docker run --rm hello-world
```

**Očekávaný výstup:**
```
Client 29.9.3 / Server 29.9.3
Docker Compose version v5.7.1

Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
...
Hello from Docker!
This message shows that your installation appears to be working correctly.
...
```

`hello-world` ověří celý řetězec najednou: klient → démon → stažení image z Docker Hubu → spuštění kontejneru → výstup zpět do terminálu.

```bash
docker info --format "Storage: {{.Driver}}  Cgroup: {{.CgroupDriver}} v{{.CgroupVersion}}  Root: {{.DockerRootDir}}"
```
```
Storage: overlayfs  Cgroup: systemd v2  Root: /var/lib/docker
```

> Verze v ukázkách odpovídají referenčnímu labu (listopad 2026). U vás mohou být novější. Zde to nevadí, Docker Engine se aktualizuje přes `apt`. Pevné verze naopak budeme držet u **image** aplikací.

### 5.6 Tahák: základní příkazy Dockeru

**Image:**

| Příkaz | Co dělá |
|---|---|
| `docker images` | seznam stažených image |
| `docker pull <image>:<tag>` | stáhne image z registru |
| `docker rmi <image>` | smaže image (nesmí ho používat žádný kontejner) |

**Kontejnery:**

| Příkaz | Co dělá |
|---|---|
| `docker ps` / `docker ps -a` | běžící / všechny kontejnery |
| `docker logs -f --tail 100 <kontejner>` | posledních 100 řádků logu a dál sleduje (`Ctrl+C` ukončí) |
| `docker exec -it <kontejner> sh` | shell uvnitř běžícího kontejneru |
| `docker inspect <kontejner>` | kompletní konfigurace v JSON (síť, volumes, env) |
| `docker stats --no-stream` | aktuální spotřeba CPU a RAM kontejnerů |
| `docker stop <k>` / `docker start <k>` / `docker rm <k>` | zastaví / spustí / smaže kontejner |

**Volumes, sítě a disk:**

| Příkaz | Co dělá |
|---|---|
| `docker volume ls` / `docker volume inspect <v>` | seznam / detail volumes |
| `docker network ls` | seznam sítí |
| `docker system df` | kolik místa zabírají image, kontejnery a volumes |

**Docker Compose** (spouští se v adresáři s `docker-compose.yml`):

| Příkaz | Co dělá |
|---|---|
| `docker compose up -d` | vytvoří a spustí vše na pozadí. Změněné služby znovu vytvoří, nezměněné nechá. |
| `docker compose ps` | stav služeb včetně healthchecku (`healthy`/`unhealthy`) |
| `docker compose logs -f <služba>` | logy služby |
| `docker compose restart <služba>` | restart (nenačte změny v compose ani `.env`, na to je `up -d`) |
| `docker compose pull` | stáhne image podle verzí v compose |
| `docker compose config` | zobrazí výslednou konfiguraci po dosazení proměnných z `.env` (**vypíše i tajemství!**) |
| `docker compose down` | zastaví a smaže kontejnery a síť. **Volumes zůstanou.** |
| `docker compose down -v` | ⚠️ smaže **i volumes**, tedy všechna data |

Dokumentace: [Docker CLI reference](https://docs.docker.com/reference/cli/docker/), [Docker Compose](https://docs.docker.com/compose/), [docker compose CLI](https://docs.docker.com/reference/cli/docker/compose/)

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock` | Členství ve skupině `docker` se ještě neprojevilo. Odhlaste se a znovu přihlaste. Pozor: SSH s `ControlMaster`/`ControlPersist` (multiplexing) může znovu použít staré spojení se starými skupinami. Ukončete ho přes `ssh -O exit <host>`, případně dočasně použijte `newgrp docker`. |
| `NO_PUBKEY 8D81803C0EBFCD88` při `apt-get update` | Chybí nebo je nečitelný GPG klíč. Zkontrolujte `/etc/apt/keyrings/docker.asc` a jeho práva (`chmod a+r`). |
| `Conflicting values set for option Signed-By` | Repozitář Dockeru je definovaný dvakrát, např. starý `docker.list` a nový `docker.sources`. Jeden smažte. |
| `toomanyrequests: You have reached your pull rate limit` | Limit anonymních stahování z Docker Hubu (sdílená veřejná IP celé učebny). Přihlaste se `docker login` nebo použijte registry mirror. |
| `docker: command not found` po instalaci přes snap | Odinstalujte snap (`sudo snap remove docker`) a postupujte podle 5.2–5.3. |

---

## 6. Krok 3: LiteLLM Proxy a PostgreSQL

**Účel:** Spustíme samotnou AI gateway. LiteLLM bude přijímat požadavky ve formátu OpenAI API na portu 4000 a přeposílat je na OpenRouter. PostgreSQL potřebuje pro **virtuální klíče, uživatele, spend tracking, logy požadavků a Admin UI**. Bez databáze funguje LiteLLM jen jako „hloupá“ proxy s jediným master key.

Dokumentace: [Docker quick start](https://docs.litellm.ai/docs/proxy/docker_quick_start), [Config](https://docs.litellm.ai/docs/proxy/configs), [Production best practices](https://docs.litellm.ai/docs/proxy/prod), [OpenRouter provider](https://docs.litellm.ai/docs/providers/openrouter)

### 6.1 Pracovní adresář a API klíč poskytovatele

Adresář `/opt/ai-stack` bude patřit vašemu uživateli. `docker compose` čte `.env` pod právy uživatele, který ho spouští, takže by ho jinak nepřečetl. Ostatní uživatelé do adresáře nesmí (`750`).

API klíč z OpenRouteru (kap. 2.2) vložíme tak, aby se **neobjevil na obrazovce ani v historii shellu**. `read -s` nezobrazuje psané znaky a proměnná se po zápisu smaže:

```bash
sudo install -d -o "$USER" -g "$USER" -m 750 /opt/ai-stack
cd /opt/ai-stack
umask 077
read -rsp "OpenRouter API key: " K && echo
printf "OPENROUTER_API_KEY=%s\n" "$K" >> .env
unset K
chmod 600 .env
```

**Ověření** (délka a začátek klíče, ne klíč samotný):

```bash
ls -l .env
awk -F= '/^OPENROUTER_API_KEY=/{print "len=" length($2), "prefix=" substr($2,1,9)}' .env
LC_ALL=C grep -c '[[:cntrl:]]' .env      # musí být 0
```
```
-rw------- 1 labadmin labadmin 82 Nov 16 13:22 .env
len=73 prefix=sk-or-v1-
0
```

> ⚠️ **Pozor při vkládání:** Klíč vložte a hned stiskněte Enter. Pokud mezitím zmáčknete šipku, Home apod., `read` uloží do proměnné i escape sekvenci terminálu (např. `ESC [ D`). Ta na obrazovce není vidět, ale LiteLLM pak hlásí *„Forbidden control character detected in headers“* (viz Troubleshooting). Kontrolní `grep` výše to odhalí. Klíč OpenRouteru má **73 znaků**.

### 6.2 Generování tajemství

```bash
cd /opt/ai-stack
umask 077
cat >> .env <<EOF

# --- LiteLLM ---
LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32)
LITELLM_SALT_KEY=sk-$(openssl rand -hex 32)
UI_USERNAME=admin
UI_PASSWORD=$(openssl rand -base64 18 | tr -d "/+=")

# --- PostgreSQL ---
POSTGRES_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 .env
cut -d= -f1 .env | grep -v '^#' | grep .      # jen názvy proměnných, ne hodnoty
```
```
OPENROUTER_API_KEY
LITELLM_MASTER_KEY
LITELLM_SALT_KEY
UI_USERNAME
UI_PASSWORD
POSTGRES_PASSWORD
```

`openssl rand -hex 32` vrátí 32 náhodných bajtů jako 64 hex znaků (256 bitů entropie). Vzor souboru je v repu jako [`deploy/.env.example`](../deploy/.env.example).

#### Master key vs. virtual key

| | **Master key** (`LITELLM_MASTER_KEY`) | **Virtual key** |
|---|---|---|
| Kdo ho má | jen administrátor gateway | uživatel, tým nebo aplikace (např. Open WebUI) |
| Oprávnění | **vše**: volání modelů, vytváření a mazání klíčů, uživatelů, týmů, nastavení | jen volání povolených modelů |
| Omezení | žádná | budget, rate limit (RPM/TPM), seznam modelů, expirace |
| Spend tracking | nesleduje se po aplikacích | útrata se počítá na klíč, uživatele a tým |
| Zneplatnění | změnou v `.env` a restartem (dotkne se všeho) | jedním klikem nebo API voláním, ostatních se to nedotkne |
| Vznik | vygenerujete sami (`sk-` + náhodný řetězec) | vytvoří ho LiteLLM (`/key/generate` nebo Admin UI), uloží se v DB |

**Pravidlo:** Master key se používá jen pro administraci. Každý klient dostane vlastní virtual key (kap. 7). Když jeden klíč unikne, zneplatníte jen ten jeden.

#### Proč se salt key nesmí měnit

`LITELLM_SALT_KEY` je klíč, kterým LiteLLM **šifruje citlivé hodnoty uložené v databázi**, např. API klíče poskytovatelů přidané přes Admin UI. Kdybyste ho po prvním startu změnili, LiteLLM by uložené hodnoty už nedokázal dešifrovat a modely přidané přes UI by přestaly fungovat. Neexistuje rotace „na místě“. Proto:
- vygenerujte ho **před prvním startem** a pak už na něj nesahejte;
- zálohujte ho spolu se zálohou databáze (záloha DB bez salt key je z části nepoužitelná).

Master key naopak rotovat lze ([Rotating master key](https://docs.litellm.ai/docs/proxy/master_key_rotations)).

### 6.3 Konfigurace LiteLLM: `config.yaml`

Soubor [`deploy/config.yaml`](../deploy/config.yaml) zkopírujte do `/opt/ai-stack/config.yaml`:

```yaml
model_list:
  - model_name: nemotron-3-ultra                      # jméno, které uvidí klienti
    litellm_params:
      model: openrouter/nvidia/nemotron-3-ultra-550b-a55b:free   # poskytovatel/ID modelu
      api_key: os.environ/OPENROUTER_API_KEY          # klíč z proměnné prostředí
    model_info:
      description: "NVIDIA Nemotron 3 Ultra via OpenRouter (free tier)"

litellm_settings:
  request_timeout: 600

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  trusted_proxy_ranges: []
```

Klíčové body:
- **`model_name`** je veřejné jméno modelu. Klienti volají `nemotron-3-ultra` a nevědí, že za ním je OpenRouter. Až budete chtít model vyměnit, změníte jen `litellm_params.model`.
- **`os.environ/…`** znamená, že hodnota se čte z proměnné prostředí. V `config.yaml` tak nejsou žádná tajemství a soubor lze verzovat v gitu.
- **`trusted_proxy_ranges: []`**: klienti se připojují přímo, ne přes reverse proxy. LiteLLM proto nevěří hlavičce `X-Forwarded-For`, kterou by jinak šlo podvrhnout (obcházení limitu přihlášení na IP).

### 6.4 `docker-compose.yml`

Soubor [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) zkopírujte do `/opt/ai-stack/docker-compose.yml`. Ve stavu po tomto kroku obsahuje služby `postgres` a `litellm`. Finální verze v repu má navíc `open-webui` z kroku 4. Hlavní části:

```yaml
name: ai-stack

x-logging: &default-logging          # rotace logů – max. 3 × 10 MB na kontejner
  driver: json-file
  options: { max-size: "10m", max-file: "3" }

services:
  postgres:
    image: postgres:16.15            # pinovaná verze
    restart: unless-stopped
    environment:
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?missing in .env}
      POSTGRES_DB: litellm
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm -d litellm"]
      ...
    networks: [ai-net]               # žádné ports: → DB není zvenku dostupná

  litellm:
    image: ghcr.io/berriai/litellm:v1.106.6
    restart: unless-stopped
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    environment:
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY:?missing in .env}
      LITELLM_SALT_KEY: ${LITELLM_SALT_KEY:?missing in .env}
      DATABASE_URL: postgresql://litellm:${POSTGRES_PASSWORD}@postgres:5432/litellm
      UI_USERNAME: ${UI_USERNAME:-admin}
      UI_PASSWORD: ${UI_PASSWORD:?missing in .env}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:?missing in .env}
      LITELLM_MODE: PRODUCTION
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    ports:
      - "4000:4000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:4000/health/liveliness', timeout=5).status == 200 else 1)"]
      start_period: 90s
      ...
```

| Prvek | Proč |
|---|---|
| **Pinované verze image** | `latest` se mění pod rukama. Po restartu by mohla naběhnout jiná verze s jinou DB migrací. S pinovanou verzí víte, co běží, a update je vědomý krok (kap. 8.3). Použitá verze byla v době psaní stará alespoň 2 týdny, takže měla čas na odhalení případných chyb. |
| **`restart: unless-stopped`** | Kontejner se po pádu nebo restartu serveru sám spustí, pokud ho ručně nezastavíte. |
| **`healthcheck`** | Docker pravidelně ověřuje, že služba opravdu odpovídá, nejen že běží proces. Stav vidíte v `docker compose ps` (`healthy`). |
| **`depends_on: condition: service_healthy`** | LiteLLM startuje až ve chvíli, kdy Postgres přijímá spojení. Jinak by při prvním startu spadl na chybě připojení k DB. |
| **Python v healthchecku** | Image LiteLLM neobsahuje `curl` ani `wget`. Ověřte příkazem `docker run --rm --entrypoint sh <image> -c "which curl wget python3"`. |
| **`${PROMĚNNÁ:?missing in .env}`** | Pokud proměnná v `.env` chybí, `docker compose` odmítne start s jasnou chybou. Kontejner nenaběhne s prázdným heslem. |
| **Explicitní `environment:` místo `env_file: .env`** | Každý kontejner dostane jen proměnné, které potřebuje. LiteLLM nevidí `WEBUI_SECRET_KEY` a Open WebUI nevidí API klíč OpenRouteru. |
| **Volume `pgdata`** | Data databáze přežijí `docker compose down`, update image i restart serveru. |
| **Rotace logů** | Výchozí `json-file` log driver logy neomezuje, na 40GB disku by je časem zaplnil. |
| **`LITELLM_MODE: PRODUCTION`** | LiteLLM nebude uvnitř kontejneru hledat a načítat vlastní `.env`. Proměnné dodává výhradně compose. |

### 6.5 Spuštění

```bash
cd /opt/ai-stack
docker compose config --quiet && echo CONFIG_OK     # syntaktická kontrola + dosazení .env
docker compose pull                                 # stáhne image (~2,5 GB, pár minut)
docker compose up -d
```

**Očekávaný výstup:**
```
CONFIG_OK
 ...
 Container ai-stack-postgres-1 Started
 Container ai-stack-postgres-1 Waiting
 Container ai-stack-postgres-1 Healthy
 Container ai-stack-litellm-1 Starting
 Container ai-stack-litellm-1 Started
```

První start LiteLLM trvá 30–60 s, protože provádí migrace DB schématu. Sledujte ho:

```bash
docker compose ps
docker compose logs -f litellm         # Ctrl+C ukončí sledování
```
```
NAME                  IMAGE                              ...   STATUS                    PORTS
ai-stack-litellm-1    ghcr.io/berriai/litellm:v1.106.6   ...   Up 34 seconds (healthy)   0.0.0.0:4000->4000/tcp, [::]:4000->4000/tcp
ai-stack-postgres-1   postgres:16.15                     ...   Up 45 seconds (healthy)   5432/tcp
```
V logu hledejte:
```
INFO:     Uvicorn running on http://0.0.0.0:4000 (Press CTRL+C to quit)
LiteLLM: Proxy initialized with Config, Set models:
    nemotron-3-ultra
```

Všimněte si, že Postgres má ve sloupci PORTS jen `5432/tcp` bez `0.0.0.0:`. Port je dostupný jen uvnitř Docker sítě.

### 6.6 Ověření API

Pro testy si načtěte proměnné z `.env` do aktuálního shellu. Hodnoty se nevypisují, ale zůstanou v prostředí shellu, takže ho po testech zavřete:

```bash
cd /opt/ai-stack
set -a; . ./.env; set +a
```

**a) Liveness a readiness** (bez autentizace):
```bash
curl -s http://localhost:4000/health/liveliness; echo
curl -s http://localhost:4000/health/readiness | jq '{status, db}'
```
```
"I'm alive!"
{ "status": "healthy", "db": "connected" }
```
`liveliness` říká, že proces běží. `readiness` navíc ověřuje spojení s databází. Viz [Health checks](https://docs.litellm.ai/docs/proxy/health).

**b) Seznam modelů** (vyžaduje klíč):
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/v1/models      # bez klíče
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq
```
```
401
{
  "data": [ { "id": "nemotron-3-ultra", "object": "model", ... } ],
  "object": "list"
}
```

**c) Testovací chat completion:**
```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "nemotron-3-ultra",
        "messages": [{"role": "user", "content": "Odpověz jednou větou česky: co je AI gateway?"}],
        "max_tokens": 400
      }' | jq '{model, content: .choices[0].message.content, usage: {prompt_tokens: .usage.prompt_tokens, completion_tokens: .usage.completion_tokens, cost: .usage.cost}}'
```
```json
{
  "model": "nemotron-3-ultra",
  "content": "AI gateway je vrstva infrastruktury, která spravuje, zabezpečuje a optimalizuje komunikaci mezi aplikacemi a modely umělé inteligence, ...",
  "usage": { "prompt_tokens": 33, "completion_tokens": 79, "cost": 0 }
}
```
Odpověď trvá řádově jednotky sekund. Text se bude lišit, protože LLM neodpovídá deterministicky. Nemotron 3 Ultra je *reasoning* model: část `completion_tokens` tvoří „přemýšlení“ (`reasoning_tokens`), proto nenastavujte `max_tokens` příliš nízko.

**d) Spend log:**
```bash
curl -s http://localhost:4000/spend/logs -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  | jq -c 'sort_by(.startTime) | .[] | {startTime, model_group, total_tokens, spend, status}'
```
```
{"startTime":"2026-11-16T12:27:58.174000Z","model_group":"nemotron-3-ultra","total_tokens":112,"spend":0.0,"status":"success"}
```
> Záznamy se do DB zapisují **dávkově** (zhruba po desítkách sekund). Pokud request hned nevidíte, zkuste to za minutu.

### 6.7 Admin UI

V prohlížeči otevřete `http://<IP_SERVERU>:4000/ui` a přihlaste se:
- **Username:** `admin` (hodnota `UI_USERNAME`)
- **Password:** hodnota `UI_PASSWORD` z `.env`. Zobrazíte ji příkazem `grep ^UI_PASSWORD /opt/ai-stack/.env`.

[SCREENSHOT: přihlašovací stránka LiteLLM Admin UI]

Po přihlášení si projděte:
- **Models**: model `nemotron-3-ultra` (z `config.yaml`) [SCREENSHOT: Models]
- **Virtual Keys**: zatím prázdné, první klíč vytvoříme v kroku 4
- **Logs**: požadavky z testů výše, včetně neúspěšných [SCREENSHOT: Logs s testovacím requestem]
- **Usage**: útrata (u free modelu 0 USD) a počty tokenů

> 🔐 Podle [dokumentace](https://docs.litellm.ai/docs/proxy/ui) jsou `UI_USERNAME`/`UI_PASSWORD` určené jen pro první přihlášení. V produkci vytvořte v Admin UI osobní účty adminů (*Internal Users*) a přihlášení přes proměnné prostředí vypněte (`general_settings.disable_env_credential_login: true`). Pokud `UI_PASSWORD` nenastavíte, do UI se lze přihlásit **master key**.

**Ověření z příkazové řádky** (když nemáte po ruce prohlížeč):
```bash
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" -X POST http://localhost:4000/login \
  --data-urlencode "username=$UI_USERNAME" --data-urlencode "password=$UI_PASSWORD"
```
```
303 -> http://localhost:4000/ui?login=success
```

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| `required variable LITELLM_MASTER_KEY is missing a value: missing in .env` | V `.env` chybí proměnná nebo spouštíte `docker compose` z jiného adresáře. `.env` se čte z aktuálního adresáře. |
| `open /opt/ai-stack/.env: permission denied` | `.env` patří rootovi. Opravte: `sudo chown $USER: /opt/ai-stack/.env`. |
| `litellm` zůstává `starting`/`unhealthy`, v logu `Can't reach database server at postgres:5432` | Postgres ještě nenaběhl nebo nesedí heslo. Pozor: **heslo DB se nastavuje jen při prvním startu prázdného volume.** Pokud jste `POSTGRES_PASSWORD` v `.env` změnili až potom, databáze má pořád staré heslo. V labu lze volume smazat (`docker compose down -v`, **smaže data!**). Jinak změňte heslo v DB přes `ALTER USER`. |
| `500 … Forbidden control character detected in headers. Potential header injection attack.` | V API klíči v `.env` je neviditelný řídicí znak, typicky escape sekvence po stisku šipky při vkládání nebo `\r` z Windows. Zkontrolujte `LC_ALL=C grep -c '[[:cntrl:]]' .env` a délku klíče (73). Opravte řádek a spusťte `docker compose up -d`. |
| `401 … Authentication Error` při volání OpenRouteru | Neplatný nebo smazaný OpenRouter klíč. Vytvořte nový. |
| `401` na `/v1/models` i s klíčem | Chybí `Bearer ` v hlavičce, nebo jste použili jiný klíč než `LITELLM_MASTER_KEY`. Pozor na prázdnou proměnnou, pokud jste nespustili `set -a; . ./.env`. |
| `429 Too Many Requests` / `rate limit` | Vyčerpán limit free modelů OpenRouteru (20/min, 50/den). Počkejte, nebo použijte jiný účet či klíč. |
| `404 … No endpoints found matching your data policy` | Nastavení soukromí na OpenRouteru vylučuje všechny poskytovatele free modelu (kap. 2.2, bod 3). |
| `Invalid model name passed in model=…` | Klient volá jiné jméno než `model_name` v `config.yaml` (např. ID z OpenRouteru místo `nemotron-3-ultra`). |
| Admin UI se nenačte zvenku, lokálně `curl` funguje | Síťový firewall mezi vámi a VM blokuje port 4000, nebo voláte špatnou IP. |
| Změna v `config.yaml` se neprojevila | Config se čte při startu: `docker compose restart litellm`. |

---

## 7. Krok 4: Open WebUI

**Účel:** Uživatelé nebudou volat API přes `curl`. Dostanou webové chatovací rozhraní. Open WebUI se připojí k LiteLLM jako k „OpenAI“ serveru, s vlastním **virtual key** a přes **interní Docker síť**.

Dokumentace: [Open WebUI – Quick start](https://docs.openwebui.com/getting-started/quick-start/), [Environment variables](https://docs.openwebui.com/reference/env-configuration), [OpenAI-compatible providers](https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-openai-compatible/)

### 7.1 Virtual key pro Open WebUI

Proč ne master key:
- **Princip nejmenších oprávnění.** Open WebUI potřebuje jen volat modely. Master key by mu dal i právo vytvářet a mazat klíče, uživatele a nastavení. I dokumentace Open WebUI doporučuje pro proxy jako LiteLLM *least-privilege* klíče.
- **Spend tracking.** Útrata a logy se v LiteLLM přiřadí ke klíči `open-webui`. Uvidíte, kolik stojí webové UI v porovnání s ostatními aplikacemi.
- **Bezpečné odvolání.** Pokud klíč unikne (např. ze zálohy volume Open WebUI), zneplatníte jen jeho. Ostatní klienti ani admin přístup se změny nedotknou.

Klíč vytvoříme API voláním s master key a jeho hodnotu rovnou zapíšeme do `.env`, bez vypsání na obrazovku:

```bash
cd /opt/ai-stack
set -a; . ./.env; set +a
umask 077

resp=$(curl -s http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"open-webui","models":["nemotron-3-ultra"],"metadata":{"service":"open-webui"}}')

echo "$resp" | jq -c '{key_alias, models, key_prefix: .key[0:5]}'

printf "\n# --- Open WebUI ---\nOPENWEBUI_LITELLM_KEY=%s\nWEBUI_SECRET_KEY=%s\nWEBUI_URL=http://<IP_SERVERU>:3000\n" \
  "$(echo "$resp" | jq -r .key)" "$(openssl rand -hex 32)" >> .env
chmod 600 .env
unset resp
```
```
{"key_alias":"open-webui","models":["nemotron-3-ultra"],"key_prefix":"sk-Ab"}
```

- `"models": ["nemotron-3-ultra"]` omezí klíč jen na tento model. Model přidaný později do `config.yaml` tento klíč automaticky neuvidí.
- Stejně lze nastavit i `max_budget`, `rpm_limit`, `tpm_limit` nebo `duration` (expirace). Viz [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys).
- Klíč můžete vytvořit i v Admin UI: **Virtual Keys → + Create New Key** [SCREENSHOT: vytvoření virtual key v Admin UI]. Hodnota klíče se zobrazí **jen jednou**.
- `WEBUI_SECRET_KEY` podepisuje přihlašovací tokeny (JWT) Open WebUI. Když ho změníte, odhlásí se všichni uživatelé.

### 7.2 Služba `open-webui` v compose

Do `docker-compose.yml` přibude služba a volume. Finální soubor je [`deploy/docker-compose.yml`](../deploy/docker-compose.yml):

```yaml
  open-webui:
    image: ghcr.io/open-webui/open-webui:v0.12.5
    restart: unless-stopped
    environment:
      OPENAI_API_BASE_URL: http://litellm:4000/v1
      OPENAI_API_KEY: ${OPENWEBUI_LITELLM_KEY:?missing in .env}
      ENABLE_OLLAMA_API: "False"
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY:?missing in .env}
      WEBUI_URL: ${WEBUI_URL:-http://localhost:3000}
      DEFAULT_USER_ROLE: pending
    volumes:
      - open-webui-data:/app/backend/data
    ports:
      - "3000:8080"
    depends_on:
      litellm:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl --silent --fail http://localhost:8080/health | jq -ne 'input.status == true' || exit 1"]
      start_period: 120s
      ...
    networks: [ai-net]

volumes:
  pgdata:
  open-webui-data:
```

| Prvek | Vysvětlení |
|---|---|
| `http://litellm:4000/v1` | Docker Compose ve vlastní síti poskytuje **DNS podle jména služby**. Open WebUI se k LiteLLM dostane interně a provoz neopouští hosta. Nepoužívejte `localhost`, uvnitř kontejneru znamená ten kontejner sám. |
| `ports: "3000:8080"` | Open WebUI v kontejneru poslouchá na 8080. Na hostu ho vystavíme na 3000. |
| `ENABLE_OLLAMA_API: "False"` | Lokální Ollamu nemáme. Bez tohoto nastavení UI zkouší připojení a do logu píše chyby. |
| `DEFAULT_USER_ROLE: pending` | Každý další registrovaný uživatel musí počkat, až ho admin schválí. |
| volume `open-webui-data` | uživatelé, chaty, nastavení (SQLite DB), nahrané soubory, cache embedding modelu |
| `depends_on … service_healthy` | Open WebUI startuje, až když LiteLLM odpovídá, takže při startu načte seznam modelů. |

> ⚠️ **Past: „ConfigVar“ proměnné se čtou jen při prvním startu.**
> `OPENAI_API_BASE_URL`, `OPENAI_API_KEY`, `ENABLE_OLLAMA_API`, `DEFAULT_USER_ROLE`, `ENABLE_SIGNUP` a další si Open WebUI při **prvním** startu uloží do své databáze. Od té chvíle platí hodnota z databáze a změna v `.env` se **ignoruje**. Proto:
> - virtual key musí být v `.env` **dřív**, než Open WebUI poprvé spustíte;
> - pozdější změnu (např. nový klíč) proveďte v **Admin Panel → Settings → Connections**;
> - alternativa je `ENABLE_PERSISTENT_CONFIG=False`, kdy se proměnné čtou při každém startu, ale změny z UI se po restartu ztratí.

### 7.3 Spuštění

```bash
cd /opt/ai-stack
docker compose config --quiet && echo CONFIG_OK
docker compose pull open-webui         # ~6,5 GB, chvíli to potrvá
docker compose up -d
docker compose ps
```
```
NAME                    ...   STATUS                    PORTS
ai-stack-litellm-1      ...   Up 36 minutes (healthy)   0.0.0.0:4000->4000/tcp, [::]:4000->4000/tcp
ai-stack-open-webui-1   ...   Up 55 seconds (healthy)   0.0.0.0:3000->8080/tcp, [::]:3000->8080/tcp
ai-stack-postgres-1     ...   Up 37 minutes (healthy)   5432/tcp
```

Při prvním startu Open WebUI stahuje z Hugging Face embedding model `sentence-transformers/all-MiniLM-L6-v2` (pro práci s dokumenty, RAG). V logu uvidíte `Fetching 30 files…` a varování `You are sending unauthenticated requests to the HF Hub`, které můžete ignorovat. Model se uloží do volume, další starty už ho nestahují.

```bash
docker compose logs -f open-webui
```

### 7.4 Ověření konektivity (CLI)

```bash
# Open WebUI vidí model přes LiteLLM s virtual key
docker compose exec -T open-webui sh -c \
  'curl -s http://litellm:4000/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" | jq -c "[.data[].id]"'

# Virtual key NEMÁ admin práva (vytvoření klíče musí selhat)
docker compose exec -T open-webui sh -c \
  'curl -s -o /dev/null -w "%{http_code}\n" http://litellm:4000/key/generate -H "Authorization: Bearer $OPENAI_API_KEY" -d "{}"'

# Kontejner Open WebUI nevidí tajemství, která nepotřebuje
docker compose exec -T open-webui sh -c 'env | cut -d= -f1 | grep -E "LITELLM_MASTER|OPENROUTER|SALT|POSTGRES" || echo none'

curl -s http://localhost:3000/health; echo
```
```
["nemotron-3-ultra"]
401
none
{"status":true}
```

### 7.5 První přihlášení: admin účet

> ⚠️ **První zaregistrovaný účet se automaticky stane administrátorem.**
> Dokud se nikdo nezaregistruje, může admin účet „obsadit“ **kdokoli**, kdo se k portu 3000 dostane jako první. Proto:
> - zaregistrujte se **hned po prvním startu**, ještě než adresu komukoli pošlete;
> - stav ověříte příkazem `curl -s http://localhost:3000/api/config | jq .onboarding`. Hodnota `true` znamená, že admin ještě neexistuje.
> - Alternativa pro automatizované nasazení: proměnné `WEBUI_ADMIN_EMAIL` a `WEBUI_ADMIN_PASSWORD` vytvoří admina už při startu a registraci vypnou. Viz [First-run bootstrap window](https://docs.openwebui.com/security/accepted-risks/first-run-bootstrap-window).

1. Otevřete `http://<IP_SERVERU>:3000`.
2. Klikněte na **Get started** a vyplňte jméno, e-mail a heslo. E-mail slouží jen jako přihlašovací jméno, nic se na něj neposílá.
   [SCREENSHOT: registrační formulář prvního (admin) účtu]
3. Po přihlášení zkontrolujte, že v **Admin Panel → Users** máte roli `admin`.
   [SCREENSHOT: Admin Panel → Users s rolí admin]

Po založení admina:
```bash
curl -s http://localhost:3000/api/config | jq -c '{version, onboarding, enable_signup: .features.enable_signup}'
```
```
{"version":"0.12.5","onboarding":null,"enable_signup":false}
```
V referenčním labu byla po registraci admina registrace dalších uživatelů vypnutá (`enable_signup: false`). Studenty pak přidáte ručně (**Admin Panel → Users → +**), nebo registraci zapnete v **Admin Panel → Settings → General**. Díky `DEFAULT_USER_ROLE: pending` je pak budete schvalovat.

### 7.6 Ověření: chat přes celý řetězec

1. V horní části obrazovky vyberte model **`nemotron-3-ultra`**. Open WebUI ho načetlo z `GET /v1/models` v LiteLLM.
   [SCREENSHOT: výběr modelu nemotron-3-ultra]
2. Napište testovací dotaz, např. *„Co je AI gateway? Odpověz třemi větami.“*
3. Během pár sekund přijde odpověď. Reasoning modely může UI zobrazit s rozbalovacím blokem „Thinking“.
   [SCREENSHOT: odpověď modelu v chatu]

**Ověření na straně LiteLLM:**

```bash
cd /opt/ai-stack; set -a; . ./.env; set +a

# requesty z Open WebUI v access logu (IP kontejneru open-webui v síti ai-net)
docker compose logs --since 10m litellm | grep -E "POST /v1/chat/completions"

# spend log s aliasem klíče
curl -s http://localhost:4000/spend/logs -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  | jq -c 'sort_by(.startTime) | .[-3:][] | {startTime, key_alias: .metadata.user_api_key_alias, model_group, total_tokens, status}'

# souhrn za klíč
curl -s "http://localhost:4000/key/info?key=$OPENWEBUI_LITELLM_KEY" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  | jq -c '.info | {key_alias, models, spend, last_active}'
```
```
litellm-1  | INFO:     172.18.0.4:53814 - "POST /v1/chat/completions HTTP/1.1" 200 OK
litellm-1  | INFO:     172.18.0.4:53808 - "POST /v1/chat/completions HTTP/1.1" 200 OK

{"startTime":"2026-11-16T13:09:46.595000Z","key_alias":"open-webui","model_group":"nemotron-3-ultra","total_tokens":579,"status":"success"}

{"key_alias":"open-webui","models":["nemotron-3-ultra"],"spend":0.0,"last_active":"2026-11-16T13:10:11.693000+00:00"}
```

V Admin UI LiteLLM (`http://<IP_SERVERU>:4000/ui` → **Logs**) je request vidět s klíčem `open-webui`. [SCREENSHOT: LiteLLM Logs s requestem od klíče open-webui]

> 💡 **Proč dva požadavky na jeden dotaz?** Open WebUI kromě vlastní odpovědi posílá na pozadí další požadavky na stejný model, např. **vygenerování názvu chatu**, tagů nebo návrhů dalších otázek. Tyto *tasks* se taky počítají do limitů a útraty. U free modelu s limitem 50 požadavků denně je to znát. Lze je vypnout nebo přesměrovat na jiný model v **Admin Panel → Settings → Interface**.

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| V nabídce není žádný model | Open WebUI se nedostane k LiteLLM nebo má špatný klíč. Spusťte test z 7.4 a podívejte se do `docker compose logs open-webui`. Zkontrolujte **Admin Panel → Settings → Connections** (URL `http://litellm:4000/v1` a klíč). Pamatujte, že změna v `.env` se po prvním startu neprojeví (ConfigVar). |
| `401` / `Authentication Error` v chatu | Virtual key byl smazán nebo zablokován v LiteLLM. Vytvořte nový a vložte ho v **Settings → Connections**. |
| `key not allowed to access model` | Klíč má v `models` jiný seznam. Upravte klíč v Admin UI LiteLLM. |
| `open-webui` dlouho `starting` / `unhealthy` | První start stahuje embedding model (pomalý internet, blokovaný `huggingface.co`). Sledujte `docker compose logs -f open-webui`. Bez přístupu na HF použijte `OFFLINE_MODE=True`, ale RAG pak nebude fungovat. |
| Někdo jiný se stal adminem | V labu: `docker compose down`, `docker volume rm ai-stack_open-webui-data` (**smaže všechny chaty a uživatele**), `docker compose up -d` a ihned se zaregistrujte. |
| `429` v chatu | Limit free modelu na OpenRouteru (20/min, 50/den), viz kap. 2.2. Zvýší ho i tasks Open WebUI (název chatu atd.). |
| Port 3000 nedostupný z prohlížeče | Ověřte `curl -I http://localhost:3000` na serveru. Pokud lokálně funguje, blokuje to síťový firewall mezi vámi a VM. |

---

## 8. Krok 5: Provoz

Všechny příkazy se spouštějí v adresáři `/opt/ai-stack`:
```bash
cd /opt/ai-stack
```

### 8.1 Stav a logy

| Úkol | Příkaz |
|---|---|
| Stav služeb a healthchecků | `docker compose ps` |
| Logy jedné služby, živě | `docker compose logs -f litellm` (nebo `open-webui`, `postgres`) |
| Posledních N řádků / za poslední dobu | `docker compose logs --tail 100 litellm`, `docker compose logs --since 30m litellm` |
| Jen chyby | `docker compose logs --since 1h litellm \| grep -iE "error\|exception"` |
| Spotřeba CPU a RAM | `docker stats --no-stream` |
| Obsazení disku Dockerem | `docker system df` |
| Výsledek posledních healthchecků | `docker inspect --format '{{json .State.Health}}' ai-stack-litellm-1 \| jq` |

Logy kontejnerů rotuje Docker podle `x-logging` v compose (3 × 10 MB na kontejner). Jsou v `/var/lib/docker/containers/<id>/*-json.log`. Pro dlouhodobé uchování je posílejte do centrálního logování (viz kap. 10).

### 8.2 Restart a změny konfigurace

| Situace | Příkaz | Poznámka |
|---|---|---|
| Restart jedné služby | `docker compose restart litellm` | Proces se restartuje se **stejnou** konfigurací kontejneru. |
| Změna `config.yaml` | `docker compose restart litellm` | Soubor je připojený jako volume, LiteLLM ho načte při startu. |
| Změna `docker-compose.yml` nebo `.env` | `docker compose up -d` | Compose znovu vytvoří jen změněné kontejnery. `restart` by změny **nenačetl**. |
| Zastavení celého stacku | `docker compose stop` / `docker compose start` | Kontejnery zůstanou, jen se zastaví. |
| Odstranění kontejnerů a sítě | `docker compose down` | **Volumes (data) zůstanou.** Další `up -d` vše vytvoří znovu. |
| ⚠️ Smazání včetně dat | `docker compose down -v` | Smaže volumes `pgdata` a `open-webui-data`. **Nevratné!** |
| Po restartu serveru | nic | `restart: unless-stopped` + `systemctl is-enabled docker` = stack naběhne sám. |

### 8.3 Update na novou verzi

**Postup:** záloha → přečíst release notes → změnit tag → `pull` → `up -d` → ověřit.

```bash
cd /opt/ai-stack

# 1) záloha (kap. 8.4) – před každým updatem!

# 2) release notes
#    LiteLLM:    https://github.com/BerriAI/litellm/releases
#    Open WebUI: https://github.com/open-webui/open-webui/releases
#    Hledejte: breaking changes, DB migrace, změny proměnných prostředí.

# 3) změna verze image (příklad LiteLLM)
sed -i 's|ghcr.io/berriai/litellm:v1.106.6|ghcr.io/berriai/litellm:<NOVÁ_VERZE>|' docker-compose.yml
grep "image:" docker-compose.yml

# 4) stažení a nasazení
docker compose pull litellm
docker compose up -d litellm

# 5) ověření
docker compose ps
docker compose logs --tail 50 litellm
curl -s http://localhost:4000/health/readiness | jq '{status, db}'
```

**Očekávaný výstup kroku 4:**
```
 Container ai-stack-litellm-1 Recreate
 Container ai-stack-litellm-1 Recreated
 ...
 Container ai-stack-litellm-1 Started
```

| Komponenta | Na co si dát pozor |
|---|---|
| **LiteLLM** | Při startu automaticky migruje schéma DB. **Návrat na starší verzi po migraci nemusí fungovat.** Proto vždy nejdřív záloha DB. Volte release starý aspoň 1–2 týdny. |
| **Open WebUI** | Také migruje svou DB (`webui.db`). Downgrade oficiálně podporovaný není, tedy záloha volume. Viz [Updating Open WebUI](https://docs.openwebui.com/getting-started/updating). |
| **PostgreSQL** | **Minor** verze (`16.15` → `16.16`) stačí změnit tag a `up -d`, formát dat je kompatibilní. **Major** verze (`16` → `17`) **nelze** jen přepnout. Je potřeba `pg_dump` → nový prázdný volume → `pg_restore`, případně `pg_upgrade`. |
| **Docker Engine** | Aktualizuje se přes `apt` spolu se systémem (`sudo apt-get upgrade`). Při upgradu se restartuje démon a s ním i kontejnery. |

Úklid starých image po úspěšném updatu (smaže jen image nepoužívané žádným kontejnerem):
```bash
docker image prune
```

### 8.4 Záloha

**Co zálohovat:**

| Co | Proč | Jak |
|---|---|---|
| `.env` | tajemství, **včetně `LITELLM_SALT_KEY`**, bez kterého nejdou dešifrovat credentials v DB | kopie souboru |
| `docker-compose.yml`, `config.yaml` | konfigurace (je i v gitu, ale záloha ukládá přesně tu verzi, která běžela) | kopie souborů |
| Postgres (LiteLLM) | virtual keys, uživatelé, týmy, budgety, spend logy | `pg_dump` za běhu, konzistentní |
| volume `open-webui-data` | uživatelé, chaty, nastavení, nahrané soubory, vektorová DB | `tar` volume, krátce zastavit kvůli SQLite |

```bash
cd /opt/ai-stack
sudo install -d -o "$USER" -g "$USER" -m 700 /opt/ai-stack-backups
TS=$(date +%Y%m%d-%H%M%S); B=/opt/ai-stack-backups/$TS
umask 077; mkdir -p "$B"

# 1) konfigurace a tajemství
cp -p .env docker-compose.yml config.yaml "$B/"

# 2) PostgreSQL – online dump ve formátu custom (-Fc, komprimovaný, pro pg_restore)
docker compose exec -T postgres pg_dump -U litellm -d litellm -Fc > "$B/litellm-db.dump"

# 3) Open WebUI – krátké zastavení kvůli konzistenci SQLite, bez cache modelů
docker compose stop open-webui
docker run --rm \
  -v ai-stack_open-webui-data:/data:ro \
  -v "$B":/backup \
  alpine:3.24.3 sh -c "umask 077; tar czf /backup/open-webui-data.tar.gz -C /data --exclude=./cache . \
                       && chown $(id -u):$(id -g) /backup/open-webui-data.tar.gz"
docker compose start open-webui

chmod 600 "$B"/*
ls -la "$B"
```
**Očekávaný výstup:**
```
drwx------ 2 labadmin labadmin   4096 Nov 16 14:18 .
-rw------- 1 labadmin labadmin   1356 Nov 16 13:25 config.yaml
-rw------- 1 labadmin labadmin   3882 Nov 16 14:02 docker-compose.yml
-rw------- 1 labadmin labadmin    858 Nov 16 14:02 .env
-rw------- 1 labadmin labadmin 274620 Nov 16 14:16 litellm-db.dump
-rw------- 1 labadmin labadmin  40503 Nov 16 14:18 open-webui-data.tar.gz
```

Vysvětlení:
- **`docker run … alpine tar`**: k obsahu volume se nejbezpečněji dostanete dočasným kontejnerem, který volume připojí (`:ro` = jen pro čtení). Nespoléhejte na interní cestu `/var/lib/docker/volumes/…`.
- **`--exclude=./cache`**: cache obsahuje stažené embedding modely (~1 GB), které si Open WebUI při startu stáhne znovu. Bez ní má záloha řádově desítky kB místo 1 GB.
- **`chown` a `umask 077`**: kontejner běží jako root, takže bez toho by archiv patřil rootovi a byl čitelný pro všechny. Záloha přitom obsahuje hashe hesel uživatelů a uložený virtual key.
- **Výpadek** Open WebUI trvá jen pár sekund (zastavení → tar → start, healthy zhruba za 30 s). LiteLLM API běží celou dobu.

**Ověření zálohy:**
```bash
docker compose exec -T postgres pg_restore --list < "$B/litellm-db.dump" | grep -c "TABLE DATA"   # počet tabulek s daty, např. 98
tar tzf "$B/open-webui-data.tar.gz" | head      # ./webui.db, ./vector_db/..., ./uploads/
```

**Zkušební obnova DB** do dočasného kontejneru, bez dopadu na produkci:
```bash
docker run -d --name pg-restore-test -e POSTGRES_USER=litellm -e POSTGRES_PASSWORD=test -e POSTGRES_DB=litellm postgres:16.15
sleep 10
docker exec -i pg-restore-test pg_restore -U litellm -d litellm --no-owner < "$B/litellm-db.dump" && echo RESTORE_OK
docker exec pg-restore-test psql -U litellm -d litellm -tAc 'select key_alias from "LiteLLM_VerificationToken";'
docker rm -f pg-restore-test
```
```
RESTORE_OK
open-webui
```

> 🔐 Záloha obsahuje **všechna tajemství** (`.env`). Ukládejte ji mimo server (jinak při ztrátě VM přijdete o data i zálohu), šifrovaně (např. `age`, `gpg`, šifrovaný backup repozitář `restic`/`borg`) a s omezeným přístupem. Pravidelné spouštění (cron/systemd timer) a retence jsou námět na pokračování.

Dokumentace: [Open WebUI – Backups](https://docs.openwebui.com/tutorials/maintenance/backups)

### 8.5 Obnova (osnova)

Na stejném nebo novém serveru s nainstalovaným Dockerem (kap. 4–5):

```bash
B=/opt/ai-stack-backups/<TIMESTAMP>
sudo install -d -o "$USER" -g "$USER" -m 750 /opt/ai-stack && cd /opt/ai-stack
cp -p "$B"/.env "$B"/docker-compose.yml "$B"/config.yaml .

# 1) Postgres: spustit jen DB (prázdný volume), obnovit dump
docker compose up -d postgres
docker compose exec -T postgres pg_restore -U litellm -d litellm --clean --if-exists --no-owner < "$B/litellm-db.dump"

# 2) Open WebUI: vytvořit volume a rozbalit do něj archiv
docker volume create ai-stack_open-webui-data
docker run --rm -v ai-stack_open-webui-data:/data -v "$B":/backup:ro alpine:3.24.3 \
  tar xzf /backup/open-webui-data.tar.gz -C /data

# 3) zbytek stacku
docker compose up -d
docker compose ps
```

> Compose při `up -d` upozorní, že volume `ai-stack_open-webui-data` „already exists but was not created by Docker Compose“. Jde jen o varování, volume se použije.
>
> Obnovu na **běžící** produkční instanci (přepsání existujících dat) dělejte jen se zálohou aktuálního stavu. `--clean` maže objekty v DB před obnovením.

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| Po `pull` + `up -d` běží pořád stará verze | V compose zůstal starý tag, nebo jste spustili `restart` místo `up -d`. Ověřte `docker compose ps` (sloupec IMAGE). |
| LiteLLM po updatu nenaběhne, v logu chyba migrace (`prisma`, `migration`) | Vraťte tag na původní verzi. Pokud už migrace proběhla a stará verze nefunguje, obnovte DB ze zálohy (8.5). Pak hledejte řešení v release notes a issues. |
| `pg_dump: error: connection … failed` | Postgres neběží nebo voláte špatného uživatele. Spusťte `docker compose ps postgres`. |
| Záloha je obrovská | Nepoužili jste `--exclude=./cache`. |
| `no space left on device` | Spusťte `docker system df`, ukliďte staré image (`docker image prune`) a staré zálohy. Logy hlídá rotace. |

---

## 9. Bezpečnostní poznámky

Tento lab je záměrně zjednodušený. Než podobný stack nasadíte pro skutečné uživatele, projděte si tyto body.

### 9.1 Tajemství

- **Kde jsou:** jen v `/opt/ai-stack/.env` (práva `600`, vlastník provozní uživatel) a v zálohách. V gitu je pouze [`deploy/.env.example`](../deploy/.env.example) s placeholdery a `.env` je v `.gitignore`.
- **Co nedělat:** nevypisovat je (`cat .env`, `docker compose config`, `docker inspect` je zobrazí v čitelné podobě), neposílat chatem ani e-mailem, nevkládat do tiketů a screenshotů.
- **Viditelnost v kontejnerech:** proměnné prostředí kontejneru vidí každý, kdo smí na hostu spustit `docker inspect`, tedy každý ve skupině `docker`. Proto má každý kontejner jen ty proměnné, které potřebuje. Pro vyšší úroveň použijte Docker secrets nebo externí secret manager (Vault, Azure Key Vault…). LiteLLM umí načítat klíče přímo z nich.
- **Rotace:** OpenRouter klíč a virtual keys lze kdykoli rotovat. Master key má [vlastní postup](https://docs.litellm.ai/docs/proxy/master_key_rotations). **`LITELLM_SALT_KEY` neměnit** (kap. 6.2).
- **Únik klíče:** okamžitě ho zneplatněte u zdroje (OpenRouter → Keys, LiteLLM → Virtual Keys) a vytvořte nový.

### 9.2 Skupina `docker`

Členství ve skupině `docker` odpovídá **rootovi na hostu** (kap. 5.4). Přidávejte do ní jen administrátory. Socket `/var/run/docker.sock` nikdy nepřipojujte do aplikačních kontejnerů a nevystavujte ho po TCP bez TLS.

### 9.3 Vystavené porty

| Port | Komu je dostupný | Riziko | Doporučení pro produkci |
|---|---|---|---|
| 3000 (Open WebUI) | celá lab síť | přihlašovací stránka a do vytvoření admina i možnost převzít admin účet | za reverse proxy s TLS, publikovat jen `127.0.0.1:3000:8080` |
| 4000 (LiteLLM API + Admin UI) | celá lab síť | Admin UI s heslem z env, API chráněné klíči | API jen pro aplikace, které ho potřebují. Admin UI omezit (VPN/IP allowlist) nebo vypnout (`DISABLE_ADMIN_UI`). Publikovat `127.0.0.1:4000:4000`. |
| 5432 (Postgres) | nikomu (jen síť `ai-net`) | – | ponechat |

Připomenutí: porty publikované Dockerem **obcházejí ufw** (kap. 4.4). Omezení dostupnosti řešte bindováním na `127.0.0.1`, pravidly v chainu `DOCKER-USER` nebo síťovým firewallem.

### 9.4 Proč zatím nemáme HTTPS (a co s tím)

**Současný stav:** Prohlížeč komunikuje s Open WebUI a klienti s LiteLLM přes **nešifrované HTTP**. Hesla, session tokeny, virtual keys i obsah konverzací jdou po síti v čitelné podobě a kdokoli ve stejné síti je může odposlechnout.

**Proč to v labu zatím neřešíme:**
- lab je izolovaná síť bez skutečných uživatelů a citlivých dat;
- TLS vyžaduje DNS jméno a certifikát (interní CA nebo Let's Encrypt), což je samostatné téma;
- cílem tohoto kroku je pochopit samotný AI stack a nekomplikovat ho další vrstvou.

**Co s tím v produkci:**
1. Přidat **reverse proxy** (Caddy, Traefik nebo nginx) jako další službu v compose. Bude jediná vystavená na portu 443.
2. Certifikát z **interní CA** (např. AD CS v doméně `lab.example.com`) nebo z Let's Encrypt (pro veřejné domény, Caddy to umí automaticky).
3. Porty 3000 a 4000 publikovat jen na `127.0.0.1` nebo vůbec, protože proxy je ve stejné Docker síti.
4. Nastavit `WEBUI_URL=https://…` a v LiteLLM `trusted_proxy_ranges` na síť proxy, aby fungovaly IP adresy klientů a limity přihlášení.
5. Přesměrovat HTTP → HTTPS a zapnout HSTS.

Do zavedení HTTPS: **nepoužívat skutečná hesla z jiných systémů** a nevkládat do chatu citlivá data. Free modely na OpenRouteru navíc mohou prompty logovat (kap. 2.2).

### 9.5 Další body

- **První účet = admin:** po nasazení se hned zaregistrujte (kap. 7.5).
- **Admin UI LiteLLM:** env přihlášení (`UI_USERNAME`/`UI_PASSWORD`) je jen pro první přihlášení. Pak vytvořte osobní admin účty a env login vypněte (kap. 6.7).
- **Data v promptech:** LiteLLM ukládá do spend logů metadata požadavků. Ukládání obsahu promptů a odpovědí je samostatné nastavení, které je potřeba posoudit z pohledu GDPR a interních pravidel.
- **Aktualizace:** bezpečnostní opravy vyžadují pravidelné updaty OS (`apt`), Docker Engine i image (kap. 8.3).

---

## 10. Další kroky

Osnova pro navazující části školení:

1. **Uživatelé a role v Open WebUI**
   - role `admin`, `user`, `pending`; schvalování registrací; ruční zakládání účtů
   - skupiny a oprávnění (přístup k modelům, funkcím, znalostním bázím)
   - [Roles](https://docs.openwebui.com/features/authentication-access/rbac/roles)
2. **Další modely v LiteLLM**
   - přidání dalších free i placených modelů (OpenRouter, Anthropic, OpenAI, Azure OpenAI, lokální Ollama/vLLM)
   - `model_name` jako alias: výměna poskytovatele bez zásahu do klientů
   - fallbacks a load balancing mezi poskytovateli; `store_model_in_db` a správa modelů z Admin UI
3. **Budgety a rate limity v LiteLLM**
   - `max_budget`, `budget_duration`, `rpm_limit`, `tpm_limit` na virtual key, uživatele a tým
   - týmy a interní uživatelé, reporting útraty
   - [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys), [Cost tracking](https://docs.litellm.ai/docs/proxy/cost_tracking)
4. **SSO**
   - Open WebUI: OIDC (Entra ID, Keycloak) nebo LDAP proti AD `lab.example.com`, mapování skupin na role
   - LiteLLM Admin UI: SSO pro administrátory
   - per-user identita až do LiteLLM (`ENABLE_FORWARD_USER_INFO_HEADERS`) a útrata po uživatelích
5. **Reverse proxy s TLS**
   - Caddy, Traefik nebo nginx v compose, certifikát z interní CA (AD CS), DNS záznamy
   - uzavření portů 3000 a 4000, HSTS, `trusted_proxy_ranges`
6. **Logování do SIEM**
   - LiteLLM callbacks (OpenTelemetry, Datadog, Langfuse, S3…) a JSON logy (`json_logs: true`)
   - logy kontejnerů přes Docker log driver (syslog/gelf/fluentd) nebo agenta (Fluent Bit, Elastic Agent, Wazuh)
   - auditní události: přihlášení, vytváření klíčů, změny rolí; GDPR a retence promptů
7. **Provozní automatizace**
   - plánované šifrované zálohy mimo server (systemd timer + restic/borg)
   - monitoring (`/health/readiness`, Prometheus metriky), alerting
   - nasazení přes Ansible a infrastrukturu jako kód

---

## 11. Odkazy

| Téma | Odkaz |
|---|---|
| Docker Engine na Ubuntu | <https://docs.docker.com/engine/install/ubuntu/> |
| Docker post-install (skupina docker) | <https://docs.docker.com/engine/install/linux-postinstall/> |
| Docker security | <https://docs.docker.com/engine/security/> |
| Docker a firewall | <https://docs.docker.com/engine/network/packet-filtering-firewalls/> |
| Docker Compose | <https://docs.docker.com/compose/> |
| LiteLLM – Docker quick start | <https://docs.litellm.ai/docs/proxy/docker_quick_start> |
| LiteLLM – Config | <https://docs.litellm.ai/docs/proxy/configs> |
| LiteLLM – Production | <https://docs.litellm.ai/docs/proxy/prod> |
| LiteLLM – Virtual keys | <https://docs.litellm.ai/docs/proxy/virtual_keys> |
| LiteLLM – Admin UI | <https://docs.litellm.ai/docs/proxy/ui> |
| LiteLLM – OpenRouter | <https://docs.litellm.ai/docs/providers/openrouter> |
| LiteLLM – releases | <https://github.com/BerriAI/litellm/releases> |
| Open WebUI – Quick start | <https://docs.openwebui.com/getting-started/quick-start/> |
| Open WebUI – Environment variables | <https://docs.openwebui.com/reference/env-configuration> |
| Open WebUI – Updating | <https://docs.openwebui.com/getting-started/updating> |
| Open WebUI – Backups | <https://docs.openwebui.com/tutorials/maintenance/backups> |
| Open WebUI – releases | <https://github.com/open-webui/open-webui/releases> |
| OpenRouter – API keys | <https://openrouter.ai/settings/keys> |
| OpenRouter – limity | <https://openrouter.ai/docs/api/reference/limits> |

### Použité verze (referenční lab, listopad 2026)

| Komponenta | Verze |
|---|---|
| Ubuntu Server | 24.04 LTS, jádro 6.8.0-149 |
| Docker Engine / Compose | 29.9.3 / v5.7.1 (od 16. 11. večer 29.10.0) |
| LiteLLM | `ghcr.io/berriai/litellm:v1.106.6` |
| PostgreSQL | `postgres:16.15` |
| Open WebUI | `ghcr.io/open-webui/open-webui:v0.12.5` |
| Alpine (zálohy) | `alpine:3.24.3` |
| Model | `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` |

---

## 12. Příloha A: Automatická příprava serveru (`prepare.sh`)

**Účel:** Na školení se nechceme dívat, jak se ~9 GB image stahuje přes sdílenou linku. Skript [`deploy/prepare.sh`](../deploy/prepare.sh) proto **předem** provede všechny přípravy z kapitol 4–6 a stáhne image. Samotný stack **nespouští**. To zůstává na účastnících (kap. 6.5 a dál).

| Krok skriptu | Odpovídá kapitole | Poznámka |
|---|---|---|
| 0/7 kontrola OS, místa na `/var` (min. 15 GB), RAM, portů 3000/4000 | 3 | malé místo = konec s chybou, obsazený port = varování |
| 1/7 `apt upgrade`, časové pásmo, nástroje | 4.1–4.3 | upgrade lze vynechat přes `--skip-upgrade` |
| 2/7 Docker Engine + Compose z `download.docker.com` | 5.1–5.3 | instaluje jen při shodě **fingerprintu GPG klíče** |
| 3/7 uživatel do skupiny `docker` | 5.4 | projeví se po novém přihlášení |
| 4/7 `/opt/ai-stack` + `docker-compose.yml`, `config.yaml`, `.env.example` | 6.1, 6.3, 6.4 | odlišný existující soubor nejdřív zazálohuje (`*.bak-<datum>`) |
| 5/7 `.env` s tajemstvími | 6.1, 6.2, 7.1 | existující hodnoty **nikdy nepřepisuje**; OpenRouter klíč se zeptá skrytě |
| 6/7 `docker compose config` + `docker compose pull` + `alpine:3.24.3` | 6.5, 7.3, 8.4 | 3 pokusy při výpadku sítě |
| 7/7 testovací `docker run`, `docker info` | 5.5 | |

**Co skript záměrně nedělá:**
- nespouští stack (`docker compose up`);
- nevytváří virtual key pro Open WebUI, protože k tomu musí běžet LiteLLM (kap. 7.1); v `.env` nechá prázdný řádek `OPENWEBUI_LITELLM_KEY=`;
- nepovyšuje už nainstalovaný Docker (viz níže);
- nerestartuje server, jen upozorní, pokud je restart potřeba.

### Spuštění

Na server zkopírujte obsah adresáře `deploy/` (např. `git clone` repozitáře nebo `scp`) a jako běžný uživatel se sudo spusťte:

```bash
cd ~/ai-stack-deploy          # adresář se soubory z deploy/
chmod +x prepare.sh
sudo ./prepare.sh             # nebo: sudo ./prepare.sh --skip-upgrade
```

Pokud skript běží v terminálu, zeptá se na API klíč OpenRouteru:
```
  Paste the OpenRouter API key (sk-or-v1-…) and press Enter.
  The key is not displayed. Empty Enter = fill it in later.
  OpenRouter API key:
```
Klíč se kontroluje stejně jako v kap. 6.1: řídicí znaky (např. ze šipek) znamenají, že se klíč neuloží. Neočekávaný tvar (jiný prefix než `sk-or-v1-` nebo jiná délka než 73 znaků) jen vyvolá varování.

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
==> 6/7 Validate compose and pull images
  [OK] docker-compose.yml is valid
  [OK] All images are available locally:
postgres:16.15  642MB
ghcr.io/open-webui/open-webui:v0.12.5  6.45GB
ghcr.io/berriai/litellm:v1.106.6  1.81GB
alpine:3.24.3  13MB
...
Preparation complete. The stack is NOT running yet. Next steps (guide sections 6.5 and 7):
```

Skript vypisuje hlášky anglicky (`[OK]`, `[WARN]`, `[ERROR]`), stejně jako ostatní skripty v repu. Varování se na konci zopakují v souhrnu `Warnings:`.

Celý výstup se ukládá do `/var/log/ai-stack-prepare.log` (práva 600). API klíč se do logu nedostane, protože `read -s` ho nevypisuje.

### Ověření

```bash
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
ls -l /opt/ai-stack
cut -d= -f1 /opt/ai-stack/.env | grep -v '^#' | grep .     # jen názvy proměnných
```

### Pokračování po přípravě

Před prvním `up` ještě chybí virtual key pro Open WebUI. Compose by kvůli prázdné proměnné `OPENWEBUI_LITELLM_KEY` (`${…:?missing in .env}`) odmítl celý soubor, proto pro první start DB a LiteLLM předáme dočasnou hodnotu jen v prostředí příkazu:

```bash
cd /opt/ai-stack
OPENWEBUI_LITELLM_KEY=pending docker compose up -d postgres litellm
```

Pak vytvořte virtual key podle kap. 7.1. Hodnotu ale **vyplňte do existujícího řádku** `OPENWEBUI_LITELLM_KEY=` (`WEBUI_SECRET_KEY` a `WEBUI_URL` už skript vygeneroval, `printf … >> .env` z kap. 7.1 by vytvořil duplicitní řádky). Nakonec spusťte `docker compose up -d`.

> Open WebUI při prvním startu ještě stáhne z Hugging Face embedding model (~90 MB, kap. 7.3). Ten se stahuje až do volume běžícího kontejneru, takže ho skript předem nestáhne.

### Opakované spuštění a server s běžícím stackem

Skript je **idempotentní**. Po přerušení (výpadek sítě při stahování) ho stačí spustit znovu. Na serveru, kde stack už běží, nic nepřepíše ani nerestartuje. Referenční lab: `.env` měl před během i po něm stejný kontrolní součet a kontejnery běžely bez přerušení.

> ⚠️ **Upgrade Dockeru = restart všech kontejnerů.** Při upgradu balíčku `docker-ce` se restartuje démon `dockerd` a s ním všechny kontejnery. Díky `restart: unless-stopped` se samy vrátí, ale LiteLLM a Open WebUI jsou zhruba minutu nedostupné. Přesně to se stalo při prvním testu skriptu v referenčním labu: `apt-get install docker-ce` povýšil 29.9.3 → 29.10.0. Skript proto už nainstalovaný Docker **nepovyšuje**: instaluje s `apt-get install --no-upgrade` a při `apt upgrade` Docker balíčky dočasně podrží (`apt-mark hold`). Docker povyšujte vědomě v servisním okně: `sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.

### Troubleshooting

| Příznak | Příčina / řešení |
|---|---|
| `Run with sudo` / `Cannot determine the regular user` | Skript potřebuje root, ale zároveň musí znát uživatele, kterému patří `/opt/ai-stack`. Spouštějte `sudo ./prepare.sh` z běžného účtu, ne z `sudo -i`. Případně použijte `--user JMÉNO`. |
| `Missing …/docker-compose.yml` | `prepare.sh` musí ležet ve stejném adresáři jako soubory z `deploy/`. |
| `Docker GPG key fingerprint mismatch` | Stažený klíč není klíč Dockeru (proxy, MITM, změna klíče). Neinstalujte, ověřte fingerprint v [oficiální dokumentaci](https://docs.docker.com/engine/install/ubuntu/). |
| `Attempt 1/3 failed: … compose pull` | Výpadek sítě nebo rate limit registru. Skript to zkusí znovu, případně ho spusťte celý znovu; už stažené vrstvy se nestahují. |
| `No terminal – set OPENROUTER_API_KEY manually` | Skript běžel bez TTY (např. `ssh server 'sudo ./prepare.sh'`). Klíč doplňte podle kap. 6.1, nebo spusťte `ssh -t`. |

