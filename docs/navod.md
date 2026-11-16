# AI gateway v labu: LiteLLM + Open WebUI v Dockeru

Školicí návod. Na čisté VM s Ubuntu Server 24.04 postavíme vlastní **AI gateway** (LiteLLM) a nad ní webové chatovací rozhraní (Open WebUI). Jazykový model nepoběží lokálně. Použijeme bezplatný model přes službu OpenRouter.

> **Konvence:**
> - Příkazy se spouštějí na serveru jako běžný uživatel se sudo.
> - `<IP_SERVERU>` nahraďte IP adresou své VM. V referenčním labu je to `192.0.2.10`.
> - Hodnoty ve tvaru `<NĚCO>` jsou placeholdery. Skutečná tajemství do návodu ani do gitu nikdy nepatří.

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
3. **Zkontrolujte nastavení soukromí.** V **Settings → Privacy** (<https://openrouter.ai/settings/privacy>) musíte povolit použití poskytovatelů, kteří u free endpointů mohou prompty logovat nebo je použít k trénování. Jinak OpenRouter vrátí chybu typu *„No endpoints found matching your data policy“*. Důsledek: **do free modelů nepište citlivá ani firemní data.**
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

*Další kapitoly (LiteLLM, Open WebUI, provoz, bezpečnost, další kroky) se doplňují průběžně.*
