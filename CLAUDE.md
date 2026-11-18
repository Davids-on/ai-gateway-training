# Projekt: AI gateway školení (LiteLLM + Open WebUI)

## Prostředí
- Cílový server: Ubuntu Server 24.04. Konkrétní IP, SSH alias a doména labu jsou v `CLAUDE.local.md` (mimo git).
- Na serveru pracuj VÝHRADNĚ přes SSH alias z `CLAUDE.local.md`: `ssh <alias> '<příkaz>'`
- Sudo bez hesla: vždy `sudo -n`; nikdy interaktivní příkazy (bez editorů, `less`, potvrzovacích dotazů – používej `-y`, `DEBIAN_FRONTEND=noninteractive`)
- Nasazení na serveru žije v `/opt/ai-stack`; zdrojová verze souborů je v `deploy/` tohoto repa

## Pravidla
- Tajné hodnoty (API klíče, master key, hesla) NIKDY nepiš do repa ani do návodu. V návodu používej placeholdery `<LITELLM_MASTER_KEY>` apod. Na serveru patří do `/opt/ai-stack/.env` s právy 600. V repu je jen `.env.example`.
- Image vždy pinuj na konkrétní ověřenou verzi z oficiální dokumentace, nikdy `latest`. Verzi vyber alespoň 2 týdny starou.
- Před destruktivní akcí (mazání volume, `docker system prune`, změna firewallu, restart sítě) se zastav a zeptej se.
- Každý krok, který provedeš, zapiš do návodu `docs/navod.md` hned po ověření, že funguje. Spuštěné příkazy loguj do `private/command-log.md` (mimo git).
- Repo je veřejné: do souborů v gitu nikdy nepiš skutečné hodnoty labu (IP, hostname, doménu, jména uživatelů a osob, název firmy). Ve výstupech a příkladech použij dokumentační hodnoty:
  - IP serveru `192.0.2.10`, síť `192.0.2.0/24`, DNS server `192.0.2.53` (RFC 5737)
  - doména `lab.example.com`, DC `dc01.lab.example.com`, firma „Example“, e-mail `helpdesk@example.com` (RFC 2606)
  - linuxový uživatel `labadmin`, SSH alias v příkladech `ai-lab`
- Převodní tabulka skutečných hodnot je v `CLAUDE.local.md`; pre-commit hook kontroluje commit proti `private/denylist.txt`.

## Návod
- Jazyk: čeština, odborné termíny anglicky tam, kde je to v oboru zvykem
- Účel: školení, takže u každého kroku: co a proč děláme, příkaz, očekávaný výstup, ověření, typické problémy
