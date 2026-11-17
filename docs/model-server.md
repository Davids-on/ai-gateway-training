# Příprava VM s lokálním AI modelem (model server)

Návod pro lektora: jak připravit **samostatnou VM s lokálním jazykovým modelem**, kterou ve školení sdílejí všichni účastníci. Každý účastník ji v [části 2, modulu G](navod-cast2.md#9-modul-g-lokální-model-přes-ai-gateway) připojí do své AI gateway (LiteLLM) jako další model vedle cloudových.

> **Referenční lab vs. školení:** V referenčním labu běží model server na stejné VM jako AI stack (`192.0.2.10`), ale jako **samostatný compose projekt** v `/opt/local-llm`, s vlastní sítí i volume a s voláním přes IP a publikovaný port, tedy stejně jako kdyby šlo o jinou VM. Ve školení je to **dedikovaná VM**. Postup je stejný, jen se liší IP a velikost modelu.

Konfigurační soubory: [`deploy/local-llm/`](../deploy/local-llm/). Příkazy referenčního labu: [`command-log.md`](command-log.md).

---

## 1. Architektura

```
VM účastníka 1: LiteLLM ──┐
VM účastníka 2: LiteLLM ──┼── HTTP :11434 + "Authorization: Bearer <LOCAL_LLM_API_KEY>"
VM účastníka N: LiteLLM ──┘                     │
                                                ▼
                          model server ┌─────────────────────────────┐
                                       │ caddy :11434  (kontrola klíče) │
                                       │   └─▶ ollama:11434 (llm-net)  │
                                       │         └─ qwen3:4b-instruct  │
                                       └─────────────────────────────┘
```

| Komponenta | Image | Úloha |
|---|---|---|
| **Ollama** | `ollama/ollama:0.40.13` | inference server: stahuje modely, drží je v RAM, nabízí API `/api/chat` (a OpenAI-kompatibilní `/v1`) |
| **Caddy** | `caddy:2.11.7` | jediný publikovaný port; pustí dál jen requesty se správným API klíčem |

**Proč Ollama:** nejjednodušší cesta k lokálnímu modelu. Jeden kontejner, modely z knihovny stáhne jedním příkazem (`ollama pull`), běží na CPU i GPU, má nativní podporu v LiteLLM (`ollama_chat/`). Alternativy pro produkci s GPU: **vLLM** (vyšší propustnost při mnoha souběžných uživatelích) nebo **llama.cpp server**.

**Proč Caddy před Ollamou:** Ollama **nemá žádnou autentizaci**. Kdokoli, kdo se dostane na port 11434, může model používat, stahovat nové modely (desítky GB) nebo je mazat (`DELETE /api/delete`). Caddy proto propustí jen request s hlavičkou `Authorization: Bearer <LOCAL_LLM_API_KEY>`, ostatní dostanou `401`. LiteLLM tuto hlavičku posílá automaticky, když má model nastavené `api_key`. Port Ollamy samotné se ven nepublikuje.

**Proč model `qwen3:4b-instruct`:** viz [kap. 2](#2-hw-a-volba-modelu).

---

## 2. HW a volba modelu

### 2.1 Parametry VM

| Položka | Školení (sdílená VM) | Referenční lab (sdílí VM se stackem) |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS | Ubuntu Server 24.04 LTS |
| CPU | **8 vCPU** s AVX2 (ideálně AVX-512) | 2 vCPU (Xeon Silver 4208, AVX-512) |
| RAM | **16 GB** | 8 GB (z toho ~3 GB volné pro model) |
| Disk | **60 GB SSD** | 58 GB (sdílený) |
| GPU | ne | ne |

Ověření, že CPU má potřebné instrukce (bez AVX2 je inference na CPU řádově pomalejší):
```bash
nproc; free -h; df -h /
grep -o -m1 -w avx2 /proc/cpuinfo; grep -o -m1 avx512f /proc/cpuinfo
```
```
8
               total        used        free ...
Mem:            15Gi ...
avx2
avx512f
```
Pokud `avx2` chybí, na hypervisoru nastavte CPU model VM na `host` / *host-passthrough* (VMware: EVC mode nesmí AVX2 maskovat).

### 2.2 Doporučený model

| Model (tag v Ollamě) | Velikost | RAM s 4 sloty × 8K kontext | Poznámka |
|---|---|---|---|
| **`qwen3:4b-instruct`** | 2,5 GB | ~8 GB | **doporučeno pro školení**: bez fáze „thinking“, kontext až 256K, **zpracuje více requestů paralelně** |
| `qwen3:8b` | 5,2 GB | ~11 GB | lepší kvalita, ale zhruba poloviční rychlost; hybridní thinking (vypíná LiteLLM přes `think: false`) |
| `qwen3.5:4b` | 3,3 GB | – | novější a umí i obrázky, ale v Ollamě 0.40.13 **neumí paralelní requesty** (`model architecture does not currently support parallel requests`), takže všichni účastníci čekají v jedné frontě |

**Proč na tom tolik záleží:** Na sdílené VM pošle 10–15 účastníků dotaz během pár sekund. Model, který zpracovává requesty jen po jednom, odpoví poslednímu účastníkovi až po několika minutách. Ověřeno v referenčním labu: u `qwen3.5:2b` Ollama spustila runner s `n_slots = 1`, u `qwen3:1.7b` a `qwen3:4b-instruct` s `n_slots = 2` (podle `OLLAMA_NUM_PARALLEL`).

### 2.3 Očekávaný výkon (CPU)

Naměřeno v referenčním labu, 2 vCPU, `qwen3:4b-instruct`, bez dalšího zatížení:

| Metrika | Hodnota |
|---|---|
| načtení modelu do RAM (první request po startu) | ~10 s |
| zpracování promptu | ~12–25 tokenů/s |
| generování odpovědi, 1 request | **~4,5 tokenu/s** |
| generování, 2 requesty souběžně | ~2,4 tokenu/s každý (CPU je plně vytížené) |
| krátká odpověď (1 věta) | ~16 s |
| odpověď ~200 tokenů | ~55 s |

Na 8 vCPU počítejte zhruba s 2–3× vyšší rychlostí (generování na CPU omezuje hlavně propustnost paměti, ne počet jader). **Před školením změřte** ([kap. 5.4](#54-zátěžový-test-před-školením)). Pro představu: na GPU (např. třídy RTX 4090) generuje model této velikosti řádově 100+ tokenů/s.

> **Co z toho plyne pro školení:** Lokální model na CPU je ukázka principu (data neopouštějí firmu, nulová cena za token, stejné API za gatewayí), ne náhrada cloudového modelu. Krátké dotazy, žádné dlouhé dokumenty. Coding agenti (Claude Code, Codex) s takovým modelem prakticky nepracují: posílají desítky tisíc tokenů kontextu.

---

## 3. Síť

**Odchozí (z model serveru, HTTPS):**

| Cíl | K čemu |
|---|---|
| Ubuntu archive | `apt` |
| `download.docker.com` | Docker Engine |
| Docker Hub (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) | image `ollama/ollama` (~3,4 GB) a `caddy` |
| `registry.ollama.ai` a jeho CDN (přesměrování na `*.r2.cloudflarestorage.com`) | stažení modelu (`ollama pull`, 2,5 GB) |

Po stažení image a modelu už server internet **nepotřebuje**. Inference běží čistě lokálně (a díky `OLLAMA_NO_CLOUD=1` Ollama ani nenabídne cloudové modely).

**Příchozí (na model server):**

| Port | Odkud | K čemu |
|---|---|---|
| TCP 22 | stanice lektora | správa |
| TCP **11434** | **jen VM účastníků** (LiteLLM) | API modelu přes Caddy |

Stanice účastníků přímý přístup na 11434 nepotřebují: všechno jde přes jejich gateway. Přesně to je pointa modulu G.

---

## 4. Instalace

Postup předpokládá čistou VM s Ubuntu 24.04, běžného uživatele se `sudo` a přístup přes SSH.

### 4.0 Rychlá cesta: skript `setup-model-server.sh`

**Co a proč:** Celou přípravu z kap. 4.1–4.6 (Docker, `/opt/local-llm`, `.env` s vygenerovaným klíčem, spuštění, stažení a zahřátí modelu, ověření 401/200, volitelně omezení portu) udělá jeden samostatný skript [`deploy/local-llm/setup-model-server.sh`](../deploy/local-llm/setup-model-server.sh). `docker-compose.yml` a `Caddyfile` má v sobě, na VM tedy stačí zkopírovat jen tento soubor. Ruční postup níže zůstává jako vysvětlení, co skript dělá.

Parametry (model, počet slotů, kontext, `KEEP_ALIVE`, povolené sítě) lze zadat třemi způsoby: upravit blok `Settings` na začátku skriptu, předat přepínači (`--model`, `--parallel`, `--context`, `--keep-alive`, `--allow-cidr`), nebo je skript při spuštění v terminálu sám vyžádá (Enter = ponechat nabídnutou hodnotu). Při opakovaném spuštění nabídne hodnoty uložené v `.env`.

```bash
scp deploy/local-llm/setup-model-server.sh <uzivatel>@<IP_MODEL_SERVERU>:
ssh <uzivatel>@<IP_MODEL_SERVERU>
sudo ./setup-model-server.sh                       # interaktivně
sudo ./setup-model-server.sh --allow-cidr 192.0.2.0/24 --yes   # bez dotazů, s omezením portu
```

Očekávaný konec výstupu:
```
  [OK] Without the key: HTTP 401
  [OK] Wrong key: HTTP 401
  [OK] With the key: HTTP 200
  [OK] Answer: Hlavním městem Česka je Praha.
  [OK] Parallel slots: n_slots = 4
...
  LOCAL_LLM_API_BASE=http://<IP_MODEL_SERVERU>:11434
  LOCAL_LLM_API_KEY=(hidden – show: sudo grep LOCAL_LLM_API_KEY /opt/local-llm/.env)
  model in config.yaml: ollama_chat/qwen3:4b-instruct
```

| Přepínač | Účel |
|---|---|
| `--yes` | bez dotazů (hodnoty z přepínačů, `.env` nebo bloku `Settings`) |
| `--allow-cidr <sítě>` | povolí port 11434 jen z uvedených sítí (pravidla v `DOCKER-USER`, trvale přes systemd unit `local-llm-firewall.service`); `none` = firewall neměnit (výchozí) |
| `--new-key` | vygeneruje nový `LOCAL_LLM_API_KEY` a restartuje Caddy (výměna klíče po školení) |
| `--show-key` | vypíše klíč v souhrnu (jinak se nikde nezobrazí ani nezaloguje) |
| `--skip-upgrade`, `--no-model` | přeskočí `apt upgrade` / stažení a zahřátí modelu |

Log běhu: `/var/log/local-llm-setup.log` (práva 600, bez klíče).

> **Referenční lab:** Skript ověřen opakovaným spuštěním nad existujícím `/opt/local-llm` (`--skip-upgrade --yes`): konfigurace beze změny, kontejnery se nerestartovaly, 401/401/200, odpověď modelu, `n_slots = 2`. Krok s firewallem (`--allow-cidr`) v labu **neověřen** (stejně jako kap. 4.6). Na čisté VM ve školení skript projde i instalací Dockeru (stejný kód jako `deploy/prepare.sh`).


### 4.1 Docker

Stejně jako na VM účastníků: [část 1, kap. 4 a 5](navod.md#4-krok-1-příprava-systému) (aktualizace systému, Docker z oficiálního repozitáře s ověřením GPG klíče, skupina `docker`). `prepare.sh` sem **nepoužívejte**, ten připravuje AI stack, ne model server (pro model server je `setup-model-server.sh`, kap. 4.0).

Ověření:
```bash
docker version --format '{{.Server.Version}}'; docker compose version --short
docker run --rm hello-world | grep -m1 Hello
```

### 4.2 Adresář a konfigurace

**Co a proč:** Stejné uspořádání jako u AI stacku: konfigurace v `/opt/local-llm`, tajemství v `.env` s právy 600.

```bash
sudo install -d -o "$USER" -g "$USER" -m 750 /opt/local-llm
cd /opt/local-llm
# zkopírujte sem z repozitáře deploy/local-llm/: docker-compose.yml, Caddyfile, .env.example
cp ~/ai-gateway-training/deploy/local-llm/{docker-compose.yml,Caddyfile,.env.example} .
```

Vytvoření `.env` s vygenerovaným klíčem (klíč se nevypíše na obrazovku):
```bash
umask 077
cat > .env <<EOF
LOCAL_LLM_API_KEY=sk-local-$(openssl rand -hex 24)
OLLAMA_NUM_PARALLEL=4
OLLAMA_CONTEXT_LENGTH=8192
OLLAMA_KEEP_ALIVE=24h
EOF
chmod 600 .env
awk -F= '{print $1, length($2)}' .env
```
```
LOCAL_LLM_API_KEY 57
OLLAMA_NUM_PARALLEL 4
OLLAMA_CONTEXT_LENGTH 4
OLLAMA_KEEP_ALIVE 3
```

| Proměnná | Školení (8 vCPU / 16 GB) | Ref. lab (2 vCPU) | Význam |
|---|---|---|---|
| `OLLAMA_NUM_PARALLEL` | **4** | 2 | kolik requestů model zpracovává současně; další čekají ve frontě (max. `OLLAMA_MAX_QUEUE` = 128, pak `503`) |
| `OLLAMA_CONTEXT_LENGTH` | 8192 | 8192 | výchozí kontext v tokenech; **každý slot si rezervuje vlastní KV cache**, RAM tedy roste s `NUM_PARALLEL × CONTEXT_LENGTH` |
| `OLLAMA_KEEP_ALIVE` | 24h | 24h | jak dlouho zůstane model v RAM po posledním requestu; načtení trvá sekundy až desítky sekund |

Klíčové části [`docker-compose.yml`](../deploy/local-llm/docker-compose.yml):
- `ollama` **nemá `ports:`**. Je dostupná jen z interní sítě `llm-net`, tedy jen pro Caddy.
- `OLLAMA_MAX_LOADED_MODELS=1`: v RAM je vždy jen jeden model (CPU server).
- `OLLAMA_NO_CLOUD=1`: vypne cloudové modely Ollamy (tagy `:cloud` se počítají na ollama.com).
- volume `ollama-models`: stažené modely (GB), přežijí update image.

[`Caddyfile`](../deploy/local-llm/Caddyfile):
```caddyfile
:11434 {
	@unauthorized not header Authorization "Bearer {$LOCAL_LLM_API_KEY}"
	respond @unauthorized `{"error":"unauthorized"}` 401

	reverse_proxy ollama:11434 {
		flush_interval -1
	}
}
```
`{$LOCAL_LLM_API_KEY}` doplní Caddy z proměnné prostředí při načtení konfigurace. `flush_interval -1` posílá tokeny dál hned (streaming).

Validace:
```bash
docker compose config --quiet && echo compose-ok
docker run --rm -e LOCAL_LLM_API_KEY=x -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.7 caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -1
```
```
compose-ok
Valid configuration
```

### 4.3 Spuštění

```bash
docker compose pull
docker compose up -d
docker compose ps --format '{{.Service}} {{.Status}}'
```
```
caddy Up 20 seconds
ollama Up 26 seconds (healthy)
```

Ollama v logu hlásí, na čem počítá:
```bash
docker compose logs ollama | grep -E 'Listening|inference compute'
```
```
... msg="Listening on [::]:11434 (version 0.40.13)"
... msg="inference compute" id=cpu library=cpu ... total="15.6 GiB" available="15.2 GiB"
```

### 4.4 Stažení modelu

```bash
docker compose exec ollama ollama pull qwen3:4b-instruct
docker compose exec ollama ollama list
```
```
NAME                 ID              SIZE      MODIFIED
qwen3:4b-instruct    0edcdef34593    2.5 GB    5 seconds ago
```
Stažení 2,5 GB trvalo v referenčním labu necelou minutu. Model je uložený ve volume `ollama-models`.

### 4.5 Ověření

Načtěte si klíč do shellu (po testech shell zavřete):
```bash
set -a; . ./.env; set +a
IP=$(hostname -I | awk '{print $1}')
```

**1. Bez klíče a se špatným klíčem → 401:**
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://$IP:11434/api/tags
curl -s -w " %{http_code}\n" -H "Authorization: Bearer spatny" http://$IP:11434/api/tags
```
```
401
{"error":"unauthorized"} 401
```

**2. S klíčem → seznam modelů:**
```bash
curl -s -H "Authorization: Bearer $LOCAL_LLM_API_KEY" http://$IP:11434/api/tags | jq -r '.models[].name'
```
```
qwen3:4b-instruct
```

**3. Chat a rychlost** (první volání zahrnuje načtení modelu do RAM):
```bash
curl -s -H "Authorization: Bearer $LOCAL_LLM_API_KEY" http://$IP:11434/api/chat -d '{
  "model": "qwen3:4b-instruct", "stream": false, "think": false,
  "messages": [{"role": "user", "content": "Jaké je hlavní město Česka? Odpověz jednou větou."}]
}' | jq -c '{c: .message.content, load_s: (.load_duration/1e9|round),
             total_s: (.total_duration/1e9*10|round/10),
             tok_s: (.eval_count/(.eval_duration/1e9)*10|round/10)}'
```
```
{"c":"Hlavním městem Česka je Praha.","load_s":10,"total_s":16.2,"tok_s":4.5}
```

**4. Model zůstal v RAM a má více slotů:**
```bash
docker compose exec ollama ollama ps
docker compose logs ollama | grep n_slots | tail -1
```
```
NAME                 ID              SIZE      PROCESSOR    CONTEXT    UNTIL
qwen3:4b-instruct    0edcdef34593    5.1 GB    100% CPU     8192       24 hours from now
... initializing, n_slots = 2, n_ctx_slot = 8192 ...
```
`SIZE` zahrnuje i KV cache všech slotů (ref. lab: 2 sloty → 5,1 GB, ve školení se 4 sloty počítejte ~8 GB). Pokud v logu uvidíte `model architecture does not currently support parallel requests` a `n_slots = 1`, zvolený model paralelní zpracování neumí (kap. 2.2).

### 4.6 Omezení přístupu na síťové úrovni

Klíč v Caddy je první vrstva. Druhou je povolit port 11434 jen z VM účastníků. **Pozor: Docker obchází `ufw`** (část 1, kap. 4.4). Publikované porty kontejnerů se filtrují v řetězci `DOCKER-USER`, ne pravidly `ufw allow`:

```bash
# všechno na 11434 zahodit, kromě sítě VM účastníků (příklad: 192.0.2.0/24)
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 11434 --ctdir ORIGINAL -j DROP
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 11434 --ctdir ORIGINAL -s 192.0.2.0/24 -j ACCEPT
sudo iptables -L DOCKER-USER -n --line-numbers
```
Pravidla nepřežijí restart (trvale přes `iptables-persistent` nebo skript po startu Dockeru). Jednodušší alternativa je ACL na úrovni sítě nebo hypervisoru (NSX, security group).

> **Referenční lab:** Firewall jsme neměnili (stack i model server jsou na jedné VM). Pravidla výše jsou podle [dokumentace Dockeru](https://docs.docker.com/engine/network/packet-filtering-firewalls/), v labu neověřená.

---

## 5. Předání účastníkům a provoz

### 5.1 Co účastníci potřebují

| Hodnota | Kam ji účastník zapíše |
|---|---|
| `http://<IP_MODEL_SERVERU>:11434` | `LOCAL_LLM_API_BASE` v `/opt/ai-stack/.env` |
| `LOCAL_LLM_API_KEY` | `LOCAL_LLM_API_KEY` v `/opt/ai-stack/.env` |
| název modelu `qwen3:4b-instruct` | už je v konfiguraci fáze `5-local-model` (`ollama_chat/qwen3:4b-instruct`) |

Klíč je **společný pro všechny**. Rozdávejte ho stejným kanálem jako ostatní klíče (kap. 4 přehledu), ne na projektoru. Kdo klíč zná, může model volat i mimo gateway. Proto v produkci model server patří do sítě, kam vidí jen gateway (kap. 4.6).

Pokud ve školení použijete jiný model, upravte před školením `model:` u `qwen-local` v [`deploy/stages/5-local-model/config.yaml`](../deploy/stages/5-local-model/config.yaml) a spusťte `python3 deploy/stages/build-stages.py` (lokální model je jen v této fázi, ostatní se nezmění). Alias `qwen-local` zůstává, klienti nic nemění.

### 5.2 Před začátkem modulu: zahřátí

Model se po restartu načítá do RAM až s prvním requestem. Před modulem G pošlete jeden dotaz (kap. 4.5, bod 3), ať první účastník nečeká.

### 5.3 Sledování během modulu

```bash
cd /opt/local-llm
docker compose exec ollama ollama ps                              # model v RAM, do kdy
docker compose logs -f --since 1m ollama | grep -E 'POST|n_slots' # každý dokončený request + délka
top -bn1 | head -12                                               # llama-server ~ N×100 % CPU = počítá
```
Řádek `[GIN] ... | 200 | 54.1s | ... | POST "/api/chat"` je dokončený request s celkovou dobou včetně čekání ve frontě.

### 5.4 Zátěžový test před školením

Simulace 8 účastníků najednou (krátké odpovědi, `num_predict` omezuje délku):
```bash
set -a; . ./.env; set +a; IP=$(hostname -I | awk '{print $1}')
time (for i in $(seq 1 8); do
  curl -s -H "Authorization: Bearer $LOCAL_LLM_API_KEY" http://$IP:11434/api/chat -d '{
    "model":"qwen3:4b-instruct","stream":false,"options":{"num_predict":100},
    "messages":[{"role":"user","content":"Napiš krátký odstavec o Praze."}]}' \
  | jq -c '{tok_s:(.eval_count/(.eval_duration/1e9)*10|round/10), total_s:(.total_duration/1e9|round)}' &
done; wait)
```
Výsledek zapište do přehledu školení. Pokud poslední request trvá déle než ~2 minuty, snižte `OLLAMA_CONTEXT_LENGTH` a zvyšte `OLLAMA_NUM_PARALLEL`, nebo zvolte menší model.

### 5.5 Výměna modelu, update Ollamy

```bash
docker compose exec ollama ollama pull qwen3:8b       # nový model
docker compose exec ollama ollama rm qwen3:4b-instruct # starý (uvolní disk)
```
Na gatewayích pak změnit `model:` v `config.yaml` a `docker compose restart litellm`.

Update Ollamy: v `docker-compose.yml` změnit tag (verze ≥ 2 týdny stará, [releases](https://github.com/ollama/ollama/releases)), `docker compose pull && docker compose up -d`. Modely ve volume zůstanou.

---

## 6. Troubleshooting

| Příznak | Příčina | Řešení |
|---|---|---|
| `401 {"error":"unauthorized"}` | chybí nebo nesedí klíč; mezera či uvozovky v `.env` | porovnat `awk -F= '{print $1, length($2)}' .env` na obou stranách; po změně `.env` na model serveru `docker compose up -d caddy` |
| první odpověď trvá o desítky sekund déle | načítání modelu do RAM | zahřát (kap. 5.2), `OLLAMA_KEEP_ALIVE=24h` |
| odpověď na „ahoj“ trvá minutu a víc | model „přemýšlí“ (thinking) | v LiteLLM `think: false` (je v `config.yaml`), nebo instruct model bez thinkingu |
| requesty se řadí, i když `OLLAMA_NUM_PARALLEL` > 1 | architektura modelu neumí paralelní zpracování (`n_slots = 1` v logu) | model z rodiny `qwen3` (kap. 2.2) |
| `503` / `server busy` | fronta plná (`OLLAMA_MAX_QUEUE`) | víc slotů, menší model, nebo méně souběžných uživatelů |
| kontejner `ollama` restartuje, v `dmesg` je `Out of memory` | model + KV cache se nevejdou do RAM | snížit `OLLAMA_NUM_PARALLEL` nebo `OLLAMA_CONTEXT_LENGTH`, menší model |
| z Open WebUI trvá každá zpráva minuty | Open WebUI posílá s každou zprávou ~37 definic vestavěných nástrojů (~7 000 tokenů) | u modelu vypnout *Capabilities → Builtin Tools* (část 2, kap. 9.5) |
| `ollama pull` končí chybou TLS / timeout | chybí prostup na `registry.ollama.ai` nebo CDN | kap. 3; model lze stáhnout jinde a přenést jako volume |
| `Error: model requires more system memory` | málo volné RAM pro načtení | zavřít jiné modely (`ollama ps`, `ollama stop <model>`), menší model |

---

## 7. Odkazy

| Téma | Odkaz |
|---|---|
| Ollama – Docker | <https://docs.ollama.com/docker> |
| Ollama – FAQ (proměnné prostředí, paralelismus) | <https://docs.ollama.com/faq> |
| Ollama – API | <https://docs.ollama.com/api> |
| Ollama – releases | <https://github.com/ollama/ollama/releases> |
| Ollama – knihovna modelů Qwen3 | <https://ollama.com/library/qwen3> |
| LiteLLM – Ollama provider | <https://docs.litellm.ai/docs/providers/ollama> |
| Docker a firewall (`DOCKER-USER`) | <https://docs.docker.com/engine/network/packet-filtering-firewalls/> |
