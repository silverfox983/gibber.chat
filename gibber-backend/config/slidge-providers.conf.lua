-- Slidge Gateway Provider Configuration
-- Auto-generated from environment or manually configured
-- This file is included by prosody.cfg.lua

-- Default component secret (fallback)
component_secret = os.getenv("SLIDGE_COMPONENT_SECRET") or "change-me-in-production"

-- Telegram Gateway
{% if env.TELEGRAM_ENABLED == "true" %}
Component "telegram.{{ env.PUBLIC_DOMAIN }}"
    component_secret = os.getenv("SLIDGRAM_SECRET") or os.getenv("SLIDGE_COMPONENT_SECRET") or "change-me"
{% endif %}

-- Discord Gateway
{% if env.DISCORD_ENABLED == "true" %}
Component "discord.{{ env.PUBLIC_DOMAIN }}"
    component_secret = os.getenv("SLIDCORD_SECRET") or os.getenv("SLIDGE_COMPONENT_SECRET") or "change-me"
{% endif %}

-- IRC Gateway
{% if env.IRC_ENABLED == "true" %}
Component "irc.{{ env.PUBLIC_DOMAIN }}"
    component_secret = os.getenv("SLIDIRC_SECRET") or os.getenv("SLIDGE_COMPONENT_SECRET") or "change-me"
{% endif %}

-- Matrix Gateway
{% if env.MATRIX_ENABLED == "true" %}
Component "matrix.{{ env.PUBLIC_DOMAIN }}"
    component_secret = os.getenv("MATRIDGE_SECRET") or os.getenv("SLIDGE_COMPONENT_SECRET") or "change-me"
{% endif %}
