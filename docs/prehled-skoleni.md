# Přehled školení: AI gateway v labu (LiteLLM + Open WebUI)

Souhrn pro lektora a organizátora: cíl, osnova obou částí, co musí být připravené na VM účastníků, na jejich stanicích a u lektora, a co je ještě otevřené. Podrobné kroky jsou v návodech [`navod.md`](navod.md) (část 1) a [`navod-cast2.md`](navod-cast2.md) (část 2), příprava VM v [`priprava-serveru.md`](priprava-serveru.md) a model serveru v [`model-server.md`](model-server.md).

Návody jsou psané pro GitHub: hlavní text je **jádro** (step-by-step pro lab i výklad), sbalené bloky **📘 Samostudium** obsahují pozadí a produkční poznámky a bloky **🔧 Řešení problémů** troubleshooting. Na školení procházejte jádro, samostudijní bloky otevírejte podle času a dotazů.

---

## 1. Cíl a výsledek

Účastník na čisté VM s Ubuntu Server 24.04 postaví vlastní **AI gateway** a naučí se ji používat a spravovat:

```
prohlížeč ──HTTPS :443──▶ Caddy ──▶ Open WebUI ──┐
klienti   ──HTTPS :8443─▶ Caddy ──▶ LiteLLM ◀────┘ (virtual key)
(curl, SDK, Claude Code,             │   └──▶ PostgreSQL (klíče, spend, logy)
 Codex CLI, Claude Desktop)          ├──▶ OpenRouter → Nemotron 3 Ultra (free)
                                     ├──▶ Anthropic  → Claude Opus / Sonnet / Haiku 5.5
                                     └──▶ model server (sdílená VM) → Ollama → Qwen3 4B (lokálně)
```

Na konci školení má každý účastník:
- běžící stack v Dockeru (`/opt/ai-stack`), zálohovaný a s postupem pro update,
- čtyři cloudové modely za jednotnými aliasy, s fallbackem mezi poskytovateli, a jeden lokální model na vlastním serveru,
- týmy, virtual keys s budgety a rate limity, přehled útraty,
- guardraily (blokace tajemství, maskování PII, detekce prompt injection),
- HTTPS přes Caddy s vlastní CA,
- připojené klienty: API (OpenAI i Anthropic formát), Claude Code, Codex CLI, Claude Desktop.

**Verze v referenčním labu (listopad 2026):** LiteLLM `v1.106.6`, Open WebUI `v0.12.5`, PostgreSQL `16.15`, Caddy `2.11.7`, Alpine `3.24.3` (zálohy), Ollama `0.40.13` + `qwen3:4b-instruct` (model server), Docker 29.10 / Compose v5.8.

---

## 2. Osnova

### Část 1: Instalace ([`navod.md`](navod.md))

| # | Kapitola | Obsah | Ověření / lab |
|---|---|---|---|
| 1 | Úvod | LLM, tokeny, proč AI gateway, LiteLLM, Open WebUI, Docker v kostce, architektura | – (teorie) |
| 2 | Prerekvizity | VM, účet a API klíč OpenRouter, free limity, přehled portů a adresářů | klíč vytvořen |
| 3 | Průzkum výchozího stavu | prostředky VM, kolize (Docker/Podman), obsazené porty, firewall, internet | výchozí stav zdokumentován |
| 4 | Příprava systému | `apt upgrade`, časové pásmo, nástroje, `ufw` (a proč ho Docker obchází) | – |
| 5 | Docker | oficiální repo s ověřením GPG klíče, instalace, skupina `docker` (= root), tahák příkazů | `hello-world` |
| 6 | LiteLLM + PostgreSQL | repozitář a konfigurace fáze `1-base`, `.env` a tajemství (`set-env.sh`), `config.yaml`, `docker-compose.yml`, spuštění, Admin UI | `/v1/models`, chat přes `curl` |
| 7 | Open WebUI | virtual key pro Open WebUI, služba v compose, první admin účet | chat v prohlížeči, záznam ve spend logu |
| 8 | Provoz | stav a logy, změny konfigurace, update verze (jen výklad), záloha a obnova | záloha vytvořena |
| 9 | Bezpečnost | tajemství, skupina `docker`, vystavené porty, chybějící HTTPS | – (diskuse) |
| 10–11 | Další kroky, odkazy | návaznost na část 2; mimo rozsah: SSO, SIEM, automatizace | – |

### Část 2: Používání a správa ([`navod-cast2.md`](navod-cast2.md))

| Modul | Téma | Lab |
|---|---|---|
| **A** | Přidávání modelů v LiteLLM: Anthropic přímo, `model_name` jako alias, `config.yaml` vs. Admin UI, fallback; konfigurace `2-models` | Claude modely, simulovaný výpadek → fallback |
| **B** | Open WebUI pro uživatele: parametry chatu, vlastní asistenti (Workspace → Models), knihovna promptů, porovnání modelů | asistent „IT helpdesk CZ“ + prompty |
| **C** | Uživatelé, role, skupiny, viditelnost modelů | skupina „Pilot“ vidí jen vybrané modely |
| **D** | Týmy, interní uživatelé, virtual keys, `max_budget`, `rpm_limit`, reporting útraty | klíč s RPM limitem → `429`, klíč s budgetem → vyčerpání |
| **E** | Guardrails (konfigurace `3-guardrails`): `litellm_content_filter` (blokace tajemství, maskování PII), PromptGuard (prompt injection), Filter function v Open WebUI | zablokovaný request, maskované PII, zachycená injection, dohledání v logu |
| **F0** | HTTPS (konfigurace `4-https`): Caddy, interní CA, důvěra na klientech, streaming, IP klienta za proxy, uzavření portů 3000/4000 | `https://<SERVER_IP>` a `https://<SERVER_IP>:8443` bez varování |
| **F** | Integrace klientů: curl, OpenAI a Anthropic SDK, Claude Code, Codex CLI, Claude Desktop | každý účastník má vlastní virtual key, útrata per klíč |
| **G** | Lokální model (konfigurace `5-local-model`): sdílený model server (Ollama + Qwen3 4B na CPU), napojení do LiteLLM (`ollama_chat/`), guardraily a fallbacky vs. data, Open WebUI (Builtin Tools vypnout) | `qwen-local` přes `curl` i v Open WebUI, spend 0 |
| Příl. A | Lokální AI model obecně: pojmy, výpočet paměti, HW požadavky, Ollama na notebooku / v Dockeru / s GPU | – |

Ze školení vyřazeno: RAG / Knowledge, Presidio, Cursor (volá gateway ze svého cloudu, lab není z internetu dostupný), observabilita.

**Konfigurace po fázích:** Moduly A, E, F0 a G mění konfiguraci serveru. Každý přepne `/opt/ai-stack` na další fázi z [`deploy/stages/`](../deploy/stages/) skriptem `./use-stage.sh <stage>` (ukáže `diff`, zazálohuje, zkopíruje). Ostatní moduly konfiguraci nemění.

> Písmena modulů části 2 odpovídají pořadí ve výuce (A modely → B Open WebUI → C uživatelé).

### Doporučené pořadí a orientační čas

Časy nejsou v návodech změřené, jde o odhad pro plánování. Ověřte je na zkušebním průchodu.

| Blok | Odhad | Poznámka |
|---|---|---|
| Část 1, kap. 1–2 (teorie, OpenRouter) | 1 h | registraci na OpenRouter lze zadat předem |
| Část 1, kap. 3–5 | 0,5 h | s `prepare.sh` jen procházení a vysvětlení |
| Část 1, kap. 6–7 | 1,5–2 h | jádro části 1 |
| Část 1, kap. 8–9 | 1 h | |
| Část 2, modul A | 1 h | |
| Část 2, moduly B + C | 1,5 h | |
| Část 2, modul D | 1 h | |
| Část 2, modul E | 1,5 h | |
| Část 2, moduly F0 + F | 2–2,5 h | import CA na stanicích bývá časově nejnáročnější |
| Část 2, modul G + příloha A | 1–1,5 h | odpovědi lokálního modelu trvají desítky sekund, sdílený server se při souběhu zpomalí |

Celkem zhruba **2 dny**. Moduly jděte v pořadí návodu: B a C potřebují Claude modely z modulu A, F0 je předpoklad pro Claude Desktop v modulu F a fáze konfigurace jdou po sobě (A → E → F0 → G). Moduly B a C lze mezi sebou prohodit (admin vidí všechny modely vždy), D nemění konfiguraci a může jít kdykoli po A.

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
| model server, TCP 11434 (lab síť) | lokální model (modul G) |

**Příchozí přístup ze stanic účastníků na VM:** TCP 22 (SSH), 3000 (Open WebUI), 4000 (LiteLLM), 443 a 8443 (Caddy). Lokální `ufw` zůstává v labu vypnutý (kap. 4.4).

Lab nemá DNS pro `lab.example.com`, všechno jede přes IP. Certifikát Caddy se proto vystavuje na IP (`SERVER_IP` v `.env`), **IP VM se po přípravě nesmí změnit** (DHCP rezervace nebo statická adresa).

### 3.3 Předpřipravení VM skriptem `prepare.sh` (doporučeno)

Aby se ~9 GB image nestahovalo na místě přes sdílenou linku, lektor VM připraví předem. Podrobně: [`priprava-serveru.md`](priprava-serveru.md).

```bash
git clone <REPO_URL> ~/ai-gateway-training   # v domovském adresáři účtu účastníka
cd ~/ai-gateway-training/deploy
sudo ./prepare.sh                                  # interaktivně, ne přes ssh bez -t
```

Skript udělá kroky z kap. 3–6 části 1: kontroly, `apt upgrade`, nástroje, Docker z oficiálního repa (s ověřením fingerprintu GPG klíče), skupinu `docker`, `/opt/ai-stack` s konfigurací fáze `1-base` a pomocnými skripty, `.env` s vygenerovanými tajemstvími a `SERVER_IP`, stažení image **všech fází** a validaci compose i `Caddyfile`. Ptá se skrytě na klíče OpenRouter, Anthropic a PromptGuard (prázdný Enter = doplnit později, `./set-env.sh`).

**Záměrně nedělá:** nespouští stack, nevytváří virtual key pro Open WebUI, nepřepíná fáze části 2, nepovyšuje už nainstalovaný Docker, nerestartuje server. To zůstává na účastnících.

Repozitář musí zůstat v `~/ai-gateway-training` účtu účastníka: návod i `use-stage.sh` z něj v části 2 berou další fáze konfigurace.

Pokud se VM klonují ze šablony: `prepare.sh` spusťte až **na každém klonu** (nebo aspoň krok s `.env`), jinak budou mít všechny VM stejná tajemství a `SERVER_IP` šablony. Image a repozitář ve šabloně být můžou.

**Kontrola po přípravě (na každé VM):**
```bash
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}'   # 5 image
ls -la /opt/ai-stack                                               # compose, config, .env (600), set-env.sh, use-stage.sh
head -1 /opt/ai-stack/config.yaml                                  # ... STAGE 1-base ...
cut -d= -f1 /opt/ai-stack/.env | grep -v '^#' | grep .             # jen názvy proměnných
groups                                                             # obsahuje docker (po novém přihlášení)
```

> **Rozhodnutí lektora:** Pokud chcete, aby si účastníci instalaci Dockeru vyzkoušeli sami, `prepare.sh` nespouštějte a nechte jen předstažené image (např. ze šablony). Kapitoly 4–5 jsou na ruční průchod napsané.

### 3.4 Model server pro modul G (jedna sdílená VM)

Podrobný postup: [`model-server.md`](model-server.md). Celou přípravu umí skript [`deploy/local-llm/setup-model-server.sh`](../deploy/local-llm/setup-model-server.sh) (`model-server.md`, kap. 4.0).

| Položka | Hodnota |
|---|---|
| OS | Ubuntu Server 24.04 LTS |
| CPU / RAM / disk | **8 vCPU** (AVX2, ideálně AVX-512) / **16 GB** / **60 GB SSD** |
| GPU | ne (inference na CPU) |
| Software | Docker, compose projekt `/opt/local-llm`: `ollama/ollama:0.40.13` + `caddy:2.11.7` |
| Model | `qwen3:4b-instruct` (2,5 GB), `OLLAMA_NUM_PARALLEL=4` |
| Síť odchozí | Docker Hub, `registry.ollama.ai` + CDN (jen při přípravě) |
| Síť příchozí | TCP 11434 **jen z VM účastníků**, TCP 22 od lektora |

Účastníkům se předá adresa `http://<MODEL_SERVER_IP>:11434` a sdílený `LOCAL_LLM_API_KEY`. Proč Qwen3 a ne novější Qwen 3.5: Qwen 3.5 v Ollamě 0.40.13 neumí paralelní requesty a všichni účastníci by čekali v jedné frontě (`model-server.md`, kap. 2.2).

---

## 4. Účty a klíče

| Klíč | Kdo ho zajišťuje | Poznámka |
|---|---|---|
| **OpenRouter** | ideálně **každý účastník vlastní účet** | free model má limit **50 požadavků/den na účet** (1000/den po nákupu ≥ 10 kreditů). Jeden sdílený klíč pro celou třídu se vyčerpá během dopoledne. V *Settings → Privacy* musí být povolené free endpointy. |
| **Anthropic** | lektor (účet s kreditem) | potřeba pro moduly A–F (Claude modely). Doporučení: samostatný workspace a klíč na každou VM s nízkým spend limitem v Anthropic Console, po školení klíče zrušit. Klíč leží v `.env` na VM účastníka, takže ho účastník vidí. |
| **PromptGuard** | lektor nebo účastník | free tier 5 USD/měsíc, **1 klíč na účet** → pro více VM buď více účtů, nebo sdílený klíč s rizikem vyčerpání free tieru. **Volitelný:** bez klíče stack běží (compose dosadí `not-configured`), v modulu E selžou jen testy s guardrailem `promptguard`. |
| Master key, salt key, hesla DB a Admin UI | generuje `prepare.sh` / část 1, kap. 6.2 | `LITELLM_SALT_KEY` se po prvním startu nesmí měnit. |
| Virtual keys | účastníci během labu | pro Open WebUI (část 1, kap. 7.1) a pro klienty (část 2, kap. 8.1) |
| `LOCAL_LLM_API_KEY` | lektor (generuje se na model serveru) | jeden sdílený klíč pro všechny gateway (modul G); po školení vyměnit |

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
- [ ] model server podle kap. 3.4 (`model-server.md`), prostup 11434 z VM účastníků
- [ ] na stanicích: prohlížeč, SSH, `curl`, `jq`, Python, Claude Code, Codex CLI, Claude Desktop, práva na import CA

**Den předem**
- [ ] `prepare.sh` doběhl na všech VM bez `[ERROR]`, kontrola z kap. 3.3; na klonech ze šablony spuštěný na každém klonu
- [ ] `<REPO_URL>` je veřejně (nebo účastníkům) dostupná a repozitář je na VM v `~/ai-gateway-training`
- [ ] na jedné VM kompletní zkušební průchod (část 1 kap. 6.5 → část 2 modul G), včetně fallbacku, 429 a guardrailů
- [ ] model server: zátěžový test (`model-server.md`, kap. 5.4), výsledek zapsat do kap. 7
- [ ] těsně před modulem G: zahřát model (`model-server.md`, kap. 5.2)
- [ ] klienti Claude Code a Codex CLI otestovaní na čisté stanici (v referenčním labu ověřena jen strana gateway)

**Na konci školení**
- [ ] uzavření přímých portů 3000/4000 (část 2, kap. 7.8, až po modulu G)
- [ ] zrušení Anthropic a PromptGuard klíčů, případně i OpenRouter klíčů; vyměnit `LOCAL_LLM_API_KEY` na model serveru
- [ ] smazání nebo reset VM

---

## 7. Otevřené body

- **Screenshoty:** `navod.md` obsahuje 13 placeholderů a `navod-cast2.md` 1 placeholder `[SCREENSHOT: …]` (registrace OpenRouter, Admin UI, Open WebUI), je potřeba je doplnit.
- **Klienti:** Claude Code a Codex CLI nebyly v referenčním labu nainstalované, jejich konfigurace je podle oficiální dokumentace. Před školením projít na čisté stanici (viz checklist).
- **Časový plán** v kap. 2 je odhad, změřit při zkušebním průchodu.
- **Výkon model serveru** na 8 vCPU / 16 GB není změřený (referenční lab má 2 vCPU: ~4,5 tokenu/s). Změřit zátěžovým testem a podle výsledku upravit `OLLAMA_NUM_PARALLEL` nebo model.
- **Firewall model serveru** (`DOCKER-USER`, `setup-model-server.sh --allow-cidr`) ověřen při zkušebním průchodu 17. 11. 2026: povolená síť projde, ostatní zdroje se zahodí, pravidla přežijí restart. Ručně zadaná pravidla z `model-server.md` kap. 4.6 (bez skriptu) restart nepřežijí.
- **URL repozitáře:** v návodech je placeholder `<REPO_URL>`, po publikaci na GitHubu ho doplnit (`navod.md` kap. 6.1, `priprava-serveru.md`, tento přehled).
- **Konfigurační fáze:** zdrojem pravdy je `deploy/stages/5-local-model/`, fáze 1–4 se z ní generují (`python3 deploy/stages/build-stages.py`). Po každé změně konfigurace skript spustit a změnu projít v `git diff`.
- **Distribuce klíčů Anthropic/PromptGuard** na VM účastníků: rozhodnout model (sdílený vs. per VM) podle rozpočtu a počtu účastníků.
