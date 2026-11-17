# Osnova – Část 2: Používání a správa AI gateway

Navazuje na `docs/navod.md` (instalace LiteLLM + Open WebUI). Výsledný návod: `docs/navod-cast2.md`.
Stav labu na začátku: LiteLLM v1.106.6, Open WebUI v0.12.5, PostgreSQL 16.15, jeden model přes OpenRouter.

Každý krok v návodu: co a proč, příkaz, očekávaný výstup, ověření, typické problémy.

## Modul A: Open WebUI pro uživatele
- chat: výběr modelu, systémový prompt, parametry (temperature, max tokens), historie, sdílení, export
- porovnání modelů vedle sebe (multi-model chat)
- knihovna promptů (`/` příkazy), proměnné v promptech
- Workspace → Models: vlastní asistenti nad modely z LiteLLM
- *(RAG / Knowledge vyřazeno)*
- **Lab:** asistent „IT helpdesk CZ“ s vlastním systémovým promptem a promptovou knihovnou

## Modul B: Uživatelé, skupiny, přístup k modelům
- role admin / user / pending, schvalování, ruční zakládání účtů
- skupiny a viditelnost modelů a asistentů
- **Lab:** skupina „Pilot“ vidí jen vybrané modely

## Modul C: Přidávání modelů v LiteLLM
- přímý poskytovatel Anthropic (vlastní API klíč) + stávající OpenRouter
- `model_name` jako alias, výměna poskytovatele bez zásahu do klientů
- `config.yaml` (verzované) vs. Admin UI / API (`store_model_in_db`)
- fallbacks a load balancing, ceny modelů a spend tracking
- **Lab:** přidat Claude modely (Anthropic) a další free model, nastavit fallback, otestovat

## Modul D: Klíče, týmy, budgety, rate limity
- týmy a interní uživatelé, klíč per tým / uživatel / aplikace
- `max_budget`, `budget_duration`, `rpm_limit`, `tpm_limit`, omezení klíče na modely
- reporting útraty (UI, `/spend/*`)
- **Lab:** klíč s RPM limitem → 429; klíč s budgetem → vyčerpání

## Modul E: Guardrails
- koncept: `pre_call` / `post_call` / `during_call`, `default_on`, zapnutí per klíč / per request, fail-open vs. fail-closed
- **vestavěný content filter** LiteLLM (`litellm_content_filter`): blokovaná slova, regex (platební karty, rodná čísla, API klíče), blokovat vs. maskovat
- **PromptGuard** (`guardrail: promptguard`, SaaS, free tier 5 USD/měsíc): prompt injection, jailbreak, PII, secrets, data exfiltration
- Open WebUI Filter functions jako doplňková vrstva – srovnání s guardraily na gatewayi
- prompt injection: ukázka útoku, co guardrail zachytí a co ne
- *(Presidio vyřazeno)*
- **Lab:** zablokovat odeslání „tajných“ dat, maskovat PII, zachytit prompt injection, ověřit v logu

## Modul F0: HTTPS pro gateway (předpoklad pro Claude Desktop)
- reverse proxy Caddy v compose, TLS certifikát (interní CA Caddy, případně AD CS)
- důvěra v CA na klientech (macOS Keychain, Windows cert store, `NODE_EXTRA_CA_CERTS` pro Claude Code)
- streaming bez bufferování, timeouty, `trusted_proxy_ranges`

## Modul F: Integrace klientů
- **API obecně:** curl, Python `openai` SDK, Anthropic SDK (`/v1/messages`), tahák base URL / klíč / model
- **Claude Code:** `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` (virtual key), `settings.json` / managed settings, útrata per vývojář
- **Claude Desktop:** Developer → Configure Third-Party Inference → Gateway; vyžaduje `/v1/messages` se streamingem a tool use, **HTTPS** (mimo loopback), export `.mobileconfig` / `.reg` pro MDM
- **Codex CLI:** `~/.codex/config.toml`, provider `litellm`, `wire_api = "responses"`, `env_key`
- *(Cursor vyřazen – volá gateway ze svých cloudových serverů, lab není dostupný z internetu)*
- **Lab:** každý účastník dostane vlastní virtual key a připojí klienty; útrata per klíč v LiteLLM

## Modul G: Observabilita pro admina (volitelně)
- logy requestů, spend logs, ukládání promptů zap/vyp (GDPR)
- health endpointy

## Ověřené předpoklady (listopad 2026)
- LiteLLM v1.106.6 obsahuje guardrail hooky `promptguard` i `litellm_content_filter` (ověřeno v kontejneru)
- Claude Desktop gateway: https://claude.com/docs/third-party/claude-desktop/gateway
- Codex CLI: https://docs.litellm.ai/docs/proxy/client_setup/codex_cli
- PromptGuard: https://docs.litellm.ai/docs/proxy/guardrails/promptguard
