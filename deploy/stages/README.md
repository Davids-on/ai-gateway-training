# Configuration stages

The training builds the AI stack step by step. Each directory holds the
`docker-compose.yml` and `config.yaml` (and from stage 4 on the `Caddyfile`)
exactly as they look on the server at that point of the guide.

| Stage | Guide | What is added |
|---|---|---|
| `1-base` | part 1, sections 6–7 | PostgreSQL, LiteLLM with one free OpenRouter model, Open WebUI |
| `2-models` | part 2, modules A and D | Claude models (Anthropic), `drop_params`, fallbacks; `ANTHROPIC_API_KEY`, `PROMPTGUARD_API_KEY` passed to LiteLLM; Open WebUI user as `end_user` in the spend logs (`ENABLE_FORWARD_USER_INFO_HEADERS`, `user_header_name`, section 5.6) |
| `3-guardrails` | part 2, module E | guardrails `secrets-block`, `pii-mask`, `promptguard` |
| `4-https` | part 2, module F0 | Caddy reverse proxy with an internal CA (ports 443, 8443) |
| `5-local-model` | part 2, module G | local model `qwen-local` (Ollama on the shared model server) – **final state** |

Switching a server to a stage (the script backs up the previous files and shows a diff):

```bash
cd /opt/ai-stack
./use-stage.sh --diff 2-models   # what would change
./use-stage.sh 2-models          # back up + copy
```

## Maintenance

`5-local-model/` is the source of truth. After changing it, rebuild stages 1–4:

```bash
python3 deploy/stages/build-stages.py
git diff deploy/stages
```

The script also copies `5-local-model/Caddyfile` to `4-https/`.
