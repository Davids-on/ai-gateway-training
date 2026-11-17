# Přehled školení: AI gateway v labu (LiteLLM + Open WebUI)

Souhrn pro lektora a organizátora: cíl, osnova obou částí, co musí být připravené na VM účastníků, na jejich stanicích a u lektora, a co je ještě otevřené. Podrobné kroky jsou v návodech [`navod.md`](navod.md) (část 1) a [`navod-cast2.md`](navod-cast2.md) (část 2).

---

## 1. Cíl a výsledek

Účastník na čisté VM s Ubuntu Server 24.04 postaví vlastní **AI gateway** a naučí se ji používat a spravovat:

```
prohlížeč ──HTTPS :443──▶ Caddy ──▶ Open WebUI ──┐
klienti   ──HTTPS :8443─▶ Caddy ──▶ LiteLLM ◀────┘ (virtual key)
(curl, SDK, Claude Code,             │   └──▶ PostgreSQL (klíče, spend, logy)
 Codex CLI, Claude Desktop)          ├──▶ OpenRouter → Nemotron 3 Ultra (free)
                                     └──▶ Anthropic  → Claude Opus / Sonnet / Haiku 5.5
```

Na konci školení má každý účastník:
- běžící stack v Dockeru (`/opt/ai-stack`), zálohovaný a s postupem pro update,
- čtyři modely za jednotnými aliasy, s fallbackem mezi poskytovateli,
- týmy, virtual keys s budgety a rate limity, přehled útraty,
- guardrails (blokace tajemství, maskování PII, detekce prompt injection),
- HTTPS přes Caddy s vlastní CA,
- připojené klienty: API (OpenAI i Anthropic formát), Claude Code, Codex CLI, Claude Desktop.

**Verze v referenčním labu (listopad 2026):** LiteLLM `v1.106.6`, Open WebUI `v0.12.5`, PostgreSQL `16.15`, Caddy `2.11.7`, Alpine `3.24.3` (zálohy), Docker 29.10 / Compose v5.7.

---

## 2. Osnova

### Část 1: Instalace ([`navod.md`](navod.md))

| # | Kapitola | Obsah | Ověření / lab |
|---|---|---|---|
| 1 | Úvod | LLM, tokeny, proč AI gateway, LiteLLM, Open WebUI, Docker v kostce, architektura | – (teorie) |
| 2 | Prerekvizity | VM, účet a API klíč OpenRouter, free limity, přehled portů a adresářů | klíč vytvořen |
| 3 | Krok 0: Průzkum | prostředky VM, kolize (Docker/Podman), obsazené porty, firewall, internet | výchozí stav zdokumentován |
| 4 | Krok 1: Příprava systému | `apt upgrade`, časové pásmo, nástroje, `ufw` (a proč ho Docker obchází) | – |
| 5 | Krok 2: Docker | oficiální repo s ověřením GPG klíče, instalace, skupina `docker` (= root), tahák příkazů | `hello-world` |
| 6 | Krok 3: LiteLLM + PostgreSQL | `.env` a tajemství, `config.yaml`, `docker-compose.yml`, spuštění, Admin UI | `/v1/models`, chat přes `curl` |
| 7 | Krok 4: Open WebUI | virtual key pro Open WebUI, služba v compose, první admin účet | chat v prohlížeči, záznam ve spend logu |
| 8 | Krok 5: Provoz | stav a logy, změny konfigurace, update verze, záloha a obnova | záloha vytvořena |
| 9 | Bezpečnost | tajemství, skupina `docker`, vystavené porty, chybějící HTTPS | – (diskuse) |
| 10–11 | Další kroky, odkazy | SSO, SIEM, automatizace | – |
| Příl. A | `prepare.sh` | automatická příprava serveru (pro lektora) | – |

### Část 2: Používání a správa ([`navod-cast2.md`](navod-cast2.md))

| Modul | Téma | Lab |
|---|---|---|
| **A** | Open WebUI pro uživatele: parametry chatu, vlastní asistenti (Workspace → Models), knihovna promptů, porovnání modelů | asistent „IT helpdesk CZ“ + prompty |
| **B** | Uživatelé, role, skupiny, viditelnost modelů | skupina „Pilot“ vidí jen vybrané modely |
| **C** | Přidávání modelů v LiteLLM: Anthropic přímo, `model_name` jako alias, `config.yaml` vs. Admin UI, fallback | Claude modely, simulovaný výpadek → fallback |
| **D** | Týmy, interní uživatelé, virtual keys, `max_budget`, `rpm_limit`, reporting útraty | klíč s RPM limitem → `429`, klíč s budgetem → vyčerpání |
| **E** | Guardrails: `litellm_content_filter` (blokace tajemství, maskování PII), PromptGuard (prompt injection), Filter function v Open WebUI | zablokovaný request, maskované PII, zachycená injection, dohledání v logu |
| **F0** | HTTPS: Caddy, interní CA, důvěra na klientech, streaming, IP klienta za proxy, uzavření portů 3000/4000 | `https://<IP>` a `https://<IP>:8443` bez varování |
| **F** | Integrace klientů: curl, OpenAI a Anthropic SDK, Claude Code, Codex CLI, Claude Desktop | každý účastník má vlastní virtual key, útrata per klíč |

Ze školení vyřazeno: RAG / Knowledge, Presidio, Cursor (volá gateway ze svého cloudu, lab není z internetu dostupný), modul G (observabilita).

### Doporučené pořadí a orientační čas

Časy nejsou v návodech změřené, jde o odhad pro plánování. Ověřte je na zkušebním průchodu.

| Blok | Odhad | Poznámka |
|---|---|---|
| Část 1, kap. 1–2 (teorie, OpenRouter) | 1 h | registraci na OpenRouter lze zadat předem |
| Část 1, kap. 3–5 | 0,5 h | s `prepare.sh` jen procházení a vysvětlení |
| Část 1, kap. 6–7 | 1,5–2 h | jádro části 1 |
| Část 1, kap. 8–9 | 1 h | |
| Část 2, moduly A + B | 1,5 h | |
| Část 2, modul C | 1 h | |
| Část 2, modul D | 1 h | |
| Část 2, modul E | 1,5 h | |
| Část 2, moduly F0 + F | 2–2,5 h | import CA na stanicích bývá časově nejnáročnější |

Celkem zhruba **2 dny**. F0 je předpoklad pro Claude Desktop, proto musí předcházet modulu F. Moduly A a B lze prohodit (admin vidí všechny modely vždy).

---

## 3. Příprava VM pro účastníky

### 3.1 Parametry VM (jedna na účastníka)

| Položka | Hodnota |
|---|---|
| OS | Ubuntu Server 24.04 LTS, čistá instalace (stačí i *minimized*) |
| CPU / RAM | 2 vCPU / **8 GB** (4 GB + swap funguje, ale je to na hraně) |
| Disk | 40 GB SSD; `prepare.sh` vyžaduje min. **17 GB volných na `/var`** (image mají ~9 GB) |
| Přístup | SSH, běžný uživatel se `sudo` |
| GPU | není potřeba (modely běží v cloudu) |

### 3.2 Síť

**Odchozí přístup z VM na internet** (HTTPS):

| Cíl | K čemu |
|---|---|
| Ubuntu archive / mirror | `apt` |
| `download.docker.com` | Docker Engine |
| `ghcr.io`, Docker Hub (`registry-1.docker.io` a CDN) | image LiteLLM, Open WebUI, Postgres, Caddy, Alpine |
| `huggingface.co` | Open WebUI při prvním startu stahuje embedding model (~90 MB), `prepare.sh` ho předem stáhnout neumí |
| `openrouter.ai` | free model (část 1) |
| `api.anthropic.com` | Claude modely (část 2) |
| API PromptGuard (`promptguard.co`) | guardrail (modul E) |

**Příchozí přístup ze stanic účastníků na VM:** TCP 22 (SSH), 3000 (Open WebUI), 4000 (LiteLLM), 443 a 8443 (Caddy). Lokální `ufw` zůstává v labu vypnutý (kap. 4.4).

Lab nemá DNS pro `lab.example.com`, všechno jede přes IP. Certifikát Caddy se proto vystavuje na IP (`SERVER_IP` v `.env`), **IP VM se po přípravě nesmí změnit** (DHCP rezervace nebo statická adresa).

### 3.3 Předpřipravení VM skriptem `prepare.sh` (doporučeno)

Aby se ~9 GB image nestahovalo na místě přes sdílenou linku, lektor VM připraví předem ([Příloha A](navod.md#12-příloha-a-automatická-příprava-serveru-preparesh)):

```bash
git clone <URL_REPOZITÁŘE> ~/ai-stack-deploy    # nebo scp obsahu deploy/
cd ~/ai-stack-deploy/deploy
sudo ./prepare.sh                                # interaktivně, ne přes ssh bez -t
```

Skript udělá kroky z kap. 3–6 části 1: kontroly, `apt upgrade`, nástroje, Docker z oficiálního repa (s ověřením fingerprintu GPG klíče), skupinu `docker`, `/opt/ai-stack` s konfigurací, `.env` s vygenerovanými tajemstvími a `SERVER_IP`, stažení všech image a validaci compose i `Caddyfile`. Ptá se skrytě na klíče OpenRouter, Anthropic a PromptGuard (prázdný Enter = doplnit později).

**Záměrně nedělá:** nespouští stack, nevytváří virtual key pro Open WebUI, nevytváří CA Caddy, nepovyšuje už nainstalovaný Docker, nerestartuje server. To zůstává na účastnících.

Pokud se VM klonují ze šablony: `prepare.sh` spusťte až **na každém klonu** (nebo aspoň krok s `.env`), jinak budou mít všechny VM stejná tajemství a `SERVER_IP` šablony. Image ve šabloně být můžou.

**Kontrola po přípravě (na každé VM):**
```bash
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}'   # 5 image
ls -l /opt/ai-stack                                                # compose, config, Caddyfile, .env (600)
cut -d= -f1 /opt/ai-stack/.env | grep -v '^#' | grep .             # jen názvy proměnných
groups                                                             # obsahuje docker (po novém přihlášení)
```

> **Rozhodnutí lektora:** Pokud chcete, aby si účastníci instalaci Dockeru vyzkoušeli sami, `prepare.sh` nespouštějte a nechte jen předstažené image (např. ze šablony). Kapitoly 4–5 jsou na ruční průchod napsané.

---

## 4. Účty a klíče

| Klíč | Kdo ho zajišťuje | Poznámka |
|---|---|---|
| **OpenRouter** | ideálně **každý účastník vlastní účet** | free model má limit **50 požadavků/den na účet** (1000/den po nákupu ≥ 10 kreditů). Jeden sdílený klíč pro celou třídu se vyčerpá během dopoledne. V *Settings → Privacy* musí být povolené free endpointy. |
| **Anthropic** | lektor (účet s kreditem) | potřeba pro moduly C a F. Doporučení: samostatný workspace a klíč na každou VM s nízkým spend limitem v Anthropic Console, po školení klíče zrušit. Klíč leží v `.env` na VM účastníka, takže ho účastník vidí. |
| **PromptGuard** | lektor nebo účastník | free tier 5 USD/měsíc, **1 klíč na účet** → pro více VM buď více účtů, nebo sdílený klíč s rizikem vyčerpání free tieru. |
| Master key, salt key, hesla DB a Admin UI | generuje `prepare.sh` / kap. 6.2 | `LITELLM_SALT_KEY` se po prvním startu nesmí měnit. |
| Virtual keys | účastníci během labu | pro Open WebUI (kap. 7.1) a pro klienty (část 2, kap. 8.1) |

Do free modelů na OpenRouteru se nesmí psát citlivá ani firemní data (poskytovatelé je mohou logovat).

---

## 5. Stanice účastníků

| Potřeba | Pro co |
|---|---|
| Moderní prohlížeč | Open WebUI, Admin UI LiteLLM |
| SSH klient | práce na VM |
| Terminál s `curl` a `jq` | testy API (část 2, kap. 8) |
| Python 3 + `pip install openai anthropic` | ukázky SDK (kap. 8.2) |
| **Právo importovat root CA** do úložiště důvěry (macOS Keychain, Windows cert store; Firefox má vlastní) | modul F0 – bez toho nefungují Claude Desktop ani Claude Code přes HTTPS |
| Node.js + **Claude Code** | modul F, kap. 8.3 (potřebuje `NODE_EXTRA_CA_CERTS`) |
| **Codex CLI** | modul F, kap. 8.4 |
| **Claude Desktop** s možností zapnout Developer Mode | modul F, kap. 8.5; v režimu gateway nepoužívá účet claude.ai |

Klienty doporučuji nainstalovat předem (instalace přes firemní proxy nebo bez admin práv je na místě zdržení). Pokud stanice spravuje MDM/GPO, ověřte předem, že import vlastní CA a Developer Mode v Claude Desktop nejsou zakázané.

---

## 6. Checklist před školením

**Týden předem**
- [ ] VM pro každého účastníka podle kap. 3.1, pevné IP, seznam IP ↔ účastník
- [ ] odchozí i příchozí síťové prostupy podle kap. 3.2 (otestovat z jedné VM a jedné stanice)
- [ ] účastníci mají účet OpenRouter a API klíč (nebo zajištěné kredity)
- [ ] Anthropic klíče se spend limitem, PromptGuard klíč(e)
- [ ] na stanicích: prohlížeč, SSH, `curl`, `jq`, Python, Claude Code, Codex CLI, Claude Desktop, práva na import CA

**Den předem**
- [ ] `prepare.sh` doběhl na všech VM bez `[ERROR]`, kontrola z kap. 3.3
- [ ] na jedné VM kompletní zkušební průchod (část 1 kap. 6.5 → část 2 modul F), včetně fallbacku, 429 a guardrails
- [ ] klienti Claude Code a Codex CLI otestovaní na čisté stanici (v referenčním labu ověřena jen strana gateway)

**Na konci školení**
- [ ] uzavření přímých portů 3000/4000 (část 2, kap. 7.8)
- [ ] zrušení Anthropic a PromptGuard klíčů, případně i OpenRouter klíčů
- [ ] smazání nebo reset VM

---

## 7. Otevřené body

- **Screenshoty:** `navod.md` obsahuje 13 placeholderů `[SCREENSHOT: …]` (registrace OpenRouter, Admin UI, Open WebUI), je potřeba je doplnit.
- **Klienti:** Claude Code a Codex CLI nebyly v referenčním labu nainstalované, jejich konfigurace je podle oficiální dokumentace. Před školením projít na čisté stanici (viz checklist).
- **Časový plán** v kap. 2 je odhad, změřit při zkušebním průchodu.
- **Distribuce klíčů Anthropic/PromptGuard** na VM účastníků: rozhodnout model (sdílený vs. per VM) podle rozpočtu a počtu účastníků.
