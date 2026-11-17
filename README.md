# AI gateway v labu: LiteLLM + Open WebUI

Školení: na VM s Ubuntu Server 24.04 postavíte vlastní **AI gateway** ([LiteLLM](https://docs.litellm.ai/)) s webovým rozhraním ([Open WebUI](https://docs.openwebui.com/)), připojíte k ní cloudové modely i lokální model a naučíte se ji spravovat: klíče, budgety, guardraily, HTTPS a klienty jako Claude Code, Codex CLI nebo Claude Desktop.

## Pro účastníky

| Návod | Obsah |
|---|---|
| [Část 1: Instalace](docs/navod.md) | Docker, LiteLLM + PostgreSQL, Open WebUI, provoz, záloha, bezpečnost |
| [Část 2: Používání a správa](docs/navod-cast2.md) | modely a fallbacky, Open WebUI pro uživatele, skupiny, týmy a budgety, guardraily, HTTPS, klienti, lokální model |

Návody mají **jádro** (krok za krokem, stačí k dokončení labu) a sbalené bloky **📘 Samostudium** (pozadí, alternativy, produkční poznámky) a **🔧 Řešení problémů**.

## Pro lektora

| Dokument | Obsah |
|---|---|
| [Přehled školení](docs/prehled-skoleni.md) | osnova, časový plán, příprava VM, sítě a stanic, klíče, checklist |
| [Příprava VM účastníků](docs/priprava-serveru.md) | skript `deploy/prepare.sh` |
| [Model server](docs/model-server.md) | sdílená VM s lokálním modelem (Ollama), skript `deploy/local-llm/setup-model-server.sh` |
| [Command log](docs/command-log.md) | příkazy z přípravy referenčního labu |

## Struktura repozitáře

```
deploy/
  stages/          konfigurace serveru po fázích školení (1-base … 5-local-model)
  prepare.sh       příprava VM účastníka (Docker, konfigurace, tajemství, image)
  set-env.sh       bezpečný zápis hodnoty do .env
  use-stage.sh     přepnutí serveru na další fázi konfigurace
  .env.example     vzor .env (skutečný .env nikdy necommitovat)
  openwebui/       filtr pro Open WebUI (modul E)
  local-llm/       model server: compose, Caddyfile, setup skript
docs/              návody a podklady pro lektora
```
