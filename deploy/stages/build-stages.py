#!/usr/bin/env python3
"""Derive the earlier configuration stages from the final one.

deploy/stages/5-local-model/ is the source of truth (docker-compose.yml,
config.yaml). This script rebuilds stages 1-4 from it by removing the blocks
that the training adds later. Run it after every change of the final stage:

    python3 deploy/stages/build-stages.py
    git diff deploy/stages        # review what changed

The Caddyfile of the final stage is copied to 4-https as well.
"""
import pathlib, re, shutil

root = pathlib.Path(__file__).resolve().parent  # deploy/stages
final = root / "5-local-model"

comp = (final / "docker-compose.yml").read_text()
conf = (final / "config.yaml").read_text()

new_keys = """      # Part 2, module A: Anthropic key. Empty = the Claude models return an
      # authentication error, the rest of the stack works.
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      # Part 2, module E: PromptGuard key. LiteLLM REFUSES TO START when the
      # promptguard guardrail has an empty key, hence the placeholder default:
      # the stack starts, only requests asking for "promptguard" are blocked.
      PROMPTGUARD_API_KEY: ${PROMPTGUARD_API_KEY:-not-configured}
"""
HEAD_C = """# AI stack: Open WebUI -> LiteLLM Proxy -> OpenRouter; PostgreSQL for LiteLLM
# Location on the server: /opt/ai-stack/docker-compose.yml
# Secrets are loaded from /opt/ai-stack/.env (template: .env.example).
"""
HEAD_Y = """# LiteLLM Proxy – configuration (/opt/ai-stack/config.yaml)
"""
# The final stage keeps its own header; strip it to the generic one first.
comp = HEAD_C + comp.split("\n", 4)[4]
conf = HEAD_Y + conf.split("\n", 2)[2]

stages = {
    "1-base": ("part 1 – Open WebUI -> LiteLLM -> OpenRouter, PostgreSQL", 1),
    "2-models": ("part 2, module A – + Anthropic models, fallbacks", 2),
    "3-guardrails": ("part 2, module E – + guardrails", 3),
    "4-https": ("part 2, module F0 – + Caddy HTTPS reverse proxy", 4),
    "5-local-model": ("part 2, module G – + local model (final state)", 5),
}

def cut(text, start, end):
    """Remove text from `start` up to (not including) `end`."""
    i = text.index(start)
    j = text.index(end, i)
    return text[:i] + text[j:]

def head_c(name, desc):
    return (f"# AI stack – STAGE {name}: {desc}\n"
            "# Location on the server: /opt/ai-stack/docker-compose.yml\n"
            "# Secrets are loaded from /opt/ai-stack/.env (template: .env.example).\n"
            "# Stages: deploy/stages/README.md\n")

def head_y(name, desc):
    return (f"# LiteLLM Proxy – STAGE {name}: {desc}\n"
            "# Location on the server: /opt/ai-stack/config.yaml\n")

for name, (desc, n) in stages.items():
    c, y = comp, conf
    if n < 5:
        c = c.replace("""      # Local model server (part 2, module G), e.g. http://<MODEL_SERVER_IP>:11434
      LOCAL_LLM_API_BASE: ${LOCAL_LLM_API_BASE:-}
      LOCAL_LLM_API_KEY: ${LOCAL_LLM_API_KEY:-}
""", "")
        y = cut(y, "  # --- Local model (part 2, module G) ---", "litellm_settings:")
    if n < 4:
        c = cut(c, "\n  caddy:\n", "\nvolumes:\n")
        c = c.replace("  caddy-data:\n  caddy-config:\n", "")
    if n < 3:
        y = cut(y, "# --- Guardrails (part 2, module E) ---", "general_settings:")
    if n < 2:
        c = c.replace(new_keys, "")
        c = cut(c, "      # Part 2, section 5.6: send the logged-in user", "    volumes:\n      - open-webui-data")
        y = cut(y, "  # Part 2, section 5.6: store the Open WebUI user", "  # X-Forwarded-For")
        y = cut(y, "  # --- Anthropic (direct provider, part 2 of the training) ---", "litellm_settings:")
        y = cut(y, "  # Silently drop request parameters", "general_settings:")
        y = y.replace("  request_timeout: 600\n", "  request_timeout: 600\n\n")
    c = head_c(name, desc) + c[len(HEAD_C):]
    y = head_y(name, desc) + y[len(HEAD_Y):]
    assert "\n\n\n" not in c, name
    y = re.sub(r"\n{3,}", "\n\n", y)
    d = root / name
    (d / "docker-compose.yml").write_text(c)
    (d / "config.yaml").write_text(y)
    print(name, len(c.splitlines()), len(y.splitlines()))

shutil.copyfile(final / "Caddyfile", root / "4-https" / "Caddyfile")
print("Caddyfile -> 4-https")
