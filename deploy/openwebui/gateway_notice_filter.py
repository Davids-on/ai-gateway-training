"""
title: Gateway Notice Filter
author: ai-gateway-training
version: 0.1
description: Blocks Czech birth numbers before they leave Open WebUI and appends an AI disclaimer to every answer.
"""

# Open WebUI Filter function (part 2, module E).
# Admin Panel -> Functions -> New Function -> paste this file -> Save -> enable.
#
#   inlet()  runs on the user's message BEFORE Open WebUI sends it to LiteLLM
#   outlet() runs on the model's answer AFTER it comes back, before it is shown
#
# Unlike the LiteLLM guardrails, this filter only protects Open WebUI users –
# API clients (Claude Code, Codex, scripts) talk to LiteLLM directly.

import re
from typing import Optional

from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        # Czech birth number (rodne cislo) in the common form 123456/7890
        block_pattern: str = Field(
            default=r"\b\d{6}/\d{3,4}\b",
            description="Regex – a user message matching it is rejected",
        )
        block_message: str = Field(
            default="The message contains a Czech birth number. Do not send personal data to AI – remove it and try again.",
            description="Message shown to the user when the message is rejected (set your own language here)",
        )
        disclaimer: str = Field(
            default="_AI-generated answer – verify it before use._",
            description="Text appended to every answer (empty = off; set your own language here)",
        )

    def __init__(self):
        self.valves = self.Valves()

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        messages = body.get("messages", [])
        last_user = next((m for m in reversed(messages) if m.get("role") == "user"), None)
        if last_user:
            content = last_user.get("content")
            # Content is either a string or a list of parts (text + images).
            text = content if isinstance(content, str) else " ".join(
                p.get("text", "") for p in content or [] if isinstance(p, dict)
            )
            if re.search(self.valves.block_pattern, text):
                # Raising an exception stops the request; Open WebUI shows the message.
                raise Exception(self.valves.block_message)
        return body

    def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        if not self.valves.disclaimer:
            return body
        suffix = f"\n\n{self.valves.disclaimer}"
        for message in reversed(body.get("messages", [])):
            if message.get("role") != "assistant":
                continue
            if self.valves.disclaimer not in (message.get("content") or ""):
                message["content"] = (message.get("content") or "") + suffix
            # Open WebUI 0.12+ renders the answer from the structured "output"
            # list (Responses-style items), so append to its last text part too.
            text_parts = [
                part
                for item in message.get("output") or []
                if isinstance(item, dict) and item.get("type") == "message"
                for part in item.get("content") or []
                if isinstance(part, dict) and part.get("type") == "output_text"
            ]
            if text_parts and self.valves.disclaimer not in text_parts[-1].get("text", ""):
                text_parts[-1]["text"] = text_parts[-1].get("text", "") + suffix
            break
        return body
