# Projekt: AI gateway školení (LiteLLM + Open WebUI)

## Prostředí
- Cílový server: Ubuntu Server 24.04, IP 192.0.2.10, SSH alias `ai-lab`
- Lab doména: lab.example.com (DC: dc01.lab.example.com)
- Na serveru pracuj VÝHRADNĚ přes `ssh ai-lab '<příkaz>'`
- Sudo bez hesla: vždy `sudo -n`; nikdy interaktivní příkazy (bez editorů, `less`, potvrzovacích dotazů – používej `-y`, `DEBIAN_FRONTEND=noninteractive`)
- Nasazení na serveru žije v `/opt/ai-stack`; zdrojová verze souborů je v `deploy/` tohoto repa

## Pravidla
- Tajné hodnoty (API klíče, master key, hesla) NIKDY nepiš do repa ani do návodu. V návodu používej placeholdery `<LITELLM_MASTER_KEY>` apod. Na serveru patří do `/opt/ai-stack/.env` s právy 600. V repu je jen `.env.example`.
- Image vždy pinuj na konkrétní ověřenou verzi z oficiální dokumentace, nikdy `latest`. Verzi vyber alespoň 2 týdny starou.
- Před destruktivní akcí (mazání volume, `docker system prune`, změna firewallu, restart sítě) se zastav a zeptej se.
- Každý krok, který provedeš, zapiš do návodu `docs/navod.md` hned po ověření, že funguje. Spuštěné příkazy loguj do `docs/command-log.md`.

## Návod
- Jazyk: čeština, odborné termíny anglicky tam, kde je to v oboru zvykem
- Účel: školení, takže u každého kroku: co a proč děláme, příkaz, očekávaný výstup, ověření, typické problémy