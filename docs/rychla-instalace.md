# Rychlá instalace: celý AI stack jedním skriptem

Chcete mít funkční AI gateway a hrát si s ní, aniž byste procházeli celý návod krok za krokem? Skript [`deploy/install-all.sh`](../deploy/install-all.sh) nainstaluje a nastaví **konečný stav školení** (fáze `5-local-model`) najednou:

| Co dostanete | Kde |
|---|---|
| **Open WebUI**: chat s modely, admin účet už založený | `http://<SERVER_IP>:3000`, HTTPS `https://<SERVER_IP>` |
| **LiteLLM**: AI gateway s modely, fallbacky a guardraily (`secrets-block`, `pii-mask`, `promptguard`) | API a Admin UI `http://<SERVER_IP>:4000/ui`, HTTPS `https://<SERVER_IP>:8443` |
| **Modely** | `nemotron-3-ultra` (zdarma přes OpenRouter), `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` (s klíčem Anthropic), `qwen-local` (se sdíleným model serverem) |
| **Virtual keys** | `open-webui` (pro Open WebUI) a `client` (pro vaše klienty: `curl`, Claude Code, Codex, SDK) |
| **Filtr v Open WebUI** | „Gateway Notice Filter“: blokuje rodná čísla, přidává upozornění „Odpověď vygenerovala AI“ |
| **HTTPS** přes Caddy s vlastní CA | root certifikát vyexportovaný do `/opt/ai-stack/caddy-root.crt` |

Co se v jednotlivých částech děje a proč, vysvětlují podrobné návody [část 1](navod.md) a [část 2](navod-cast2.md). Tahle stránka je zkratka. Když se chcete něco naučit, projděte si návody i potom na hotovém stacku.

---

## Co musíte udělat ručně

Skript zvládne vše na serveru. Sám ale nezaloží účty u poskytovatelů ani nesáhne na vaši pracovní stanici. To je na vás:

| # | Úkol | Povinné? | Kdy |
|---|---|---|---|
| 1 | Připravit VM s Ubuntu Server 24.04 | ano | před instalací |
| 2 | Založit účet na OpenRouter a vytvořit API klíč | **ano** | před instalací |
| 3 | Klíč Anthropic (Claude modely) | ne | před instalací nebo později |
| 4 | Klíč PromptGuard (externí guardrail) | ne | před instalací nebo později |
| 5 | Adresa a klíč sdíleného model serveru (od lektora) | ne | před instalací nebo později |
| 6 | Spustit skript a vložit klíče | ano | instalace |
| 7 | Importovat root certifikát na stanici (HTTPS) | jen pro HTTPS a klienty | po instalaci |
| 8 | Nastavit klienty (Claude Code, Codex, …) | ne | po instalaci |
| 9 | Vypnout *Builtin Tools* u `qwen-local` v Open WebUI | jen s lokálním modelem | po instalaci |

Bez volitelných klíčů stack normálně běží. Jen příslušné funkce vrátí chybu (Claude modely `AuthenticationError`, guardrail `promptguard` `401`, `qwen-local` chybu spojení).

### 1. Virtuální stroj

| Položka | Hodnota |
|---|---|
| OS | Ubuntu Server 24.04 LTS, čistá instalace (stačí i *minimized*) |
| CPU / RAM / disk | 2 vCPU / 8 GB / 40 GB (na `/var` aspoň 17 GB volných) |
| Přístup | SSH, uživatel s právy `sudo` |
| Síť | internet: apt repozitáře, `download.docker.com`, `ghcr.io`, Docker Hub, `github.com`, `openrouter.ai`, `huggingface.co` (a `api.anthropic.com`, `promptguard.co`, pokud je použijete) |
| Volné porty | 3000, 4000, 443, 8443 |

### 2. OpenRouter API klíč (povinný)

1. Na <https://openrouter.ai/> se zaregistrujte (Google, GitHub nebo e-mail).
2. V **Settings → Privacy** povolte free endpointy. Jinak free model skončí chybou *„No endpoints found matching your data policy“*. Do free modelů proto nepište citlivá data.
3. V **Keys** → **Create Key** vytvořte klíč (*Credit limit* klidně `0`) a hned si ho zkopírujte. Začíná `sk-or-v1-` a zobrazí se jen jednou.

Podrobnosti a limity free modelů (50 požadavků denně): [část 1, kap. 2.2](navod.md#22-účet-a-api-klíč-na-openrouterai).

### 3.–5. Volitelné klíče

| Klíč | Kde ho získat | K čemu |
|---|---|---|
| Anthropic (`sk-ant-…`) | [console.anthropic.com](https://console.anthropic.com/settings/keys) → API Keys, účet s kreditem | Claude modely a fallback z free modelu na Claude Haiku |
| PromptGuard (`pg_…`) | [promptguard.co](https://promptguard.co): registrace, free tier | guardrail `promptguard` (prompt injection, jailbreak) |
| Model server | od lektora: adresa `http://<MODEL_SERVER_IP>:11434` a klíč | lokální model `qwen-local` |

---

## Instalace

### 6. Spuštění skriptu

Přihlaste se na server a stáhněte repozitář **do domovského adresáře** (skript `use-stage.sh` ho tam hledá):

```bash
ssh labadmin@192.0.2.10
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Davids-on/ai-gateway-training.git ~/ai-gateway-training
cd ~/ai-gateway-training/deploy
sudo ./install-all.sh
```

Na minimalizované instalaci Ubuntu `git` chybí, proto ho instalujeme jako první.

Skript se během běhu zeptá na klíče. **Vstup se nezobrazuje** (ani hvězdičky), klíč vložte a stiskněte Enter. Prázdný Enter klíč přeskočí, doplníte ho později:

```
  OpenRouter API key (sk-or-v1-…), then press Enter.
  The key is not displayed. Empty Enter = fill it in later.
  OpenRouter API key:
  [OK] OPENROUTER_API_KEY saved (length 73, prefix sk-or-v1-)
  ...
  Address of the shared model server from the instructor, e.g. http://192.0.2.20:11434
  (without /v1). Empty Enter = skip, the model qwen-local will then not work.
  LOCAL_LLM_API_BASE:
```

Celá instalace trvá 10–20 minut (aktualizace systému a stažení ~9 GB image). Užitečné přepínače:

| Přepínač | Účinek |
|---|---|
| `--skip-upgrade` | vynechá `apt upgrade` (rychlejší) |
| `--admin-email jana@example.com` | e-mail admin účtu v Open WebUI (výchozí `admin@example.com`) |
| `--help` | nápověda |

**Očekávaný konec výstupu:**
```
==> 9/9 Smoke tests
  [OK] LiteLLM models for the client key: ["nemotron-3-ultra","claude-opus-5-5","claude-sonnet-5-5","claude-haiku-5-5","qwen-local"]
  [OK] Test request answered: OK
  [OK] Open WebUI /health OK
  [OK] HTTPS Open WebUI: https://192.0.2.10 (200)
  [OK] HTTPS LiteLLM: https://192.0.2.10:8443 (200)

==> Done

The AI stack is running in its final state.

  Open WebUI (chat):     http://192.0.2.10:3000      https://192.0.2.10
  LiteLLM Admin UI:      http://192.0.2.10:4000/ui   https://192.0.2.10:8443/ui
  ...
```

Varování (`[WARN]`) na konci shrnují, co nefunguje. Typicky chybějící volitelný klíč.

### Přihlašovací údaje

Skript **nic tajného nevypisuje**. Hesla a klíče jsou jen v `/opt/ai-stack/.env` (práva `600`):

```bash
sudo grep -E '^(WEBUI_ADMIN_|UI_USERNAME|UI_PASSWORD|CLIENT_LITELLM_KEY)' /opt/ai-stack/.env
```

| Proměnná | K čemu |
|---|---|
| `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD` | přihlášení do Open WebUI (admin) |
| `UI_USERNAME`, `UI_PASSWORD` | přihlášení do LiteLLM Admin UI (`/ui`) |
| `CLIENT_LITELLM_KEY` | virtual key pro vaše klienty |
| `LITELLM_MASTER_KEY` | jen pro administraci gateway, **nikdy** ho nedávejte do klientů |

Heslo admina si v Open WebUI můžete změnit (*Settings → Account*). Nové heslo pak uložte i do `.env` (`./set-env.sh WEBUI_ADMIN_PASSWORD`), jinak se opakované spuštění skriptu do Open WebUI nepřihlásí a kontrolu filtru přeskočí s varováním.

### Ověření

1. Otevřete `http://<SERVER_IP>:3000`, přihlaste se jako admin a v novém chatu zvolte `nemotron-3-ultra`. Zeptejte se třeba *„Jaké je hlavní město Polska?“*. Pod odpovědí uvidíte *„Odpověď vygenerovala AI. Před použitím ji ověřte.“* (filtr).
2. Zkuste guardrail: *„Zaplať objednávku kartou 4111 1111 1111 1111, platnost 12/28.“* skončí chybou z gateway `Content blocked: credit_card pattern detected` (`secrets-block`).
3. Zkuste filtr: *„Ověř formát rodného čísla 850615/1234.“* odmítne už Open WebUI.

Z konzole serveru přímo proti API:
```bash
cd /opt/ai-stack
set -a; . ./.env; set +a
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $CLIENT_LITELLM_KEY" -H "Content-Type: application/json" \
  -d '{"model":"nemotron-3-ultra","messages":[{"role":"user","content":"Řekni ahoj."}]}' \
  | jq -r '.choices[0].message.content'
```

---

## Po instalaci (ručně)

### 7. Root certifikát na stanici (HTTPS)

HTTPS používá certifikáty od vlastní CA Caddy. Prohlížeč a klienti jí věří, až když root certifikát naimportujete. Stáhněte ho ze serveru a porovnejte otisk s tím, který vypsal skript (`SHA-256 …`):

```bash
scp labadmin@192.0.2.10:/opt/ai-stack/caddy-root.crt ~/caddy-root.crt
openssl x509 -in ~/caddy-root.crt -noout -fingerprint -sha256
```

| Stanice | Import (práva administrátora) |
|---|---|
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/caddy-root.crt` |
| Windows | `certutil -addstore -f Root caddy-root.crt` (PowerShell jako správce) |
| Linux | `sudo cp ~/caddy-root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| Node.js (Claude Code) | proměnná `NODE_EXTRA_CA_CERTS=$HOME/caddy-root.crt` |
| Python SDK | proměnná `SSL_CERT_FILE=$HOME/caddy-root.crt` |

Ověření: `https://<SERVER_IP>` se v prohlížeči otevře bez varování. Firefox má vlastní úložiště (*Nastavení → Certifikáty → Importovat*). Podrobně: [část 2, kap. 7.5](navod-cast2.md#75-root-certifikát-a-důvěra-na-klientech).

### 8. Klienti

Klíč `CLIENT_LITELLM_KEY` má povolené všechny modely. Například Claude Code:

```bash
export ANTHROPIC_BASE_URL=https://192.0.2.10:8443        # BEZ /v1
export ANTHROPIC_AUTH_TOKEN=<CLIENT_LITELLM_KEY>
export NODE_EXTRA_CA_CERTS=$HOME/caddy-root.crt
claude
```

Claude Code potřebuje klíč Anthropic na gateway (bez něj Claude modely nefungují). Codex CLI, Claude Desktop, SDK a trvalé nastavení: [část 2, kap. 8](navod-cast2.md#8-modul-f-integrace-klientů).

> [!TIP]
> Pro každého člověka nebo nástroj je lepší vlastní klíč (přehled útraty, možnost zneplatnit jeden klíč). Další klíče vytvoříte v LiteLLM Admin UI (*Virtual Keys → Create New Key*) nebo podle [části 2, kap. 8.1](navod-cast2.md#81-virtual-key-pro-uživatele).

### 9. Lokální model v Open WebUI

Jen pokud jste zadali model server. Jako admin v *Admin Panel → Settings → Models → `qwen-local`* (tužka):
- **Capabilities → Builtin Tools → vypnout.** Jinak Open WebUI posílá s každou zprávou definice 37 nástrojů a CPU model odpovídá minuty.
- **Save & Update.**

Proč: [část 2, kap. 9.5](navod-cast2.md#95-lokální-model-v-open-webui).

---

## Doplnění klíče později

Klíč uložíte skriptem `set-env.sh` (zeptá se skrytě) a stack restartujete s novou hodnotou:

```bash
cd /opt/ai-stack
./set-env.sh ANTHROPIC_API_KEY          # nebo PROMPTGUARD_API_KEY, LOCAL_LLM_API_KEY
./set-env.sh LOCAL_LLM_API_BASE http://<MODEL_SERVER_IP>:11434   # adresa není tajná
docker compose up -d
```

`docker compose up -d` vytvoří kontejner LiteLLM znovu s novými proměnnými. Opakované spuštění `sudo ./install-all.sh` je také bezpečné: existující tajemství, klíče a účty zachová a doplní jen to, co chybí.

## Řešení problémů

| Příznak | Příčina | Řešení |
|---|---|---|
| `OPENROUTER_API_KEY is empty` a konec | klíč nebyl zadán | `cd /opt/ai-stack && ./set-env.sh OPENROUTER_API_KEY`, pak skript znovu |
| `Test request failed: ... 429` / `rate limit` | free model je přetížený nebo jste vyčerpali 50 požadavků za den | zkusit později; s klíčem Anthropic LiteLLM přepne na `claude-haiku-5-5` |
| `No endpoints found matching your data policy` | OpenRouter Privacy zakazuje free endpointy | povolit v *Settings → Privacy* |
| `LiteLLM did not become healthy` | chyba v `.env` nebo konfiguraci | `cd /opt/ai-stack && docker compose logs --tail 50 litellm` |
| `Port 3000 is in use` | na VM už něco běží | uvolnit port, nebo použít čistou VM |
| `permission denied ... docker.sock` | uživatel ještě není ve skupině `docker` | odhlásit a znovu přihlásit (nebo `sudo docker …`) |
| `Open WebUI already has an admin account` a filtr přeskočen | admin byl založen ručně | filtr nainstalovat ručně: [část 2, kap. 6.6](navod-cast2.md#66-druhá-vrstva-filter-function-v-open-webui) |
| prohlížeč hlásí nedůvěryhodný certifikát | root certifikát není importovaný | krok 7 |

Další provoz (logy, update, záloha): [část 1, kap. 8](navod.md#8-provoz).
