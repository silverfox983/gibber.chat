-- Slidge Gateway Component Configuration for Prosody
-- This file configures Prosody to accept external gateway components

-- Component connection secrets (must match the secrets in .env.slidge)
component_secret = "CHANGE_ME_DEFAULT_COMPONENT_SECRET"

-- Example: How to add a component (uncomment and configure):
-- Component "telegram.gibberapp.online"
--     component_secret = "CHANGE_ME_TELEGRAM_SECRET_123"
--
-- Component "discord.gibberapp.online"
--     component_secret = "CHANGE_ME_DISCORD_SECRET_456"
--
-- Component "irc.gibberapp.online"
--     component_secret = "CHANGE_ME_IRC_SECRET_789"
--
-- Component "matrix.gibberapp.online"
--     component_secret = "CHANGE_ME_MATRIX_SECRET_abc"

-- Note: In Railway deployment with supervisord, components run as separate
-- containers in the same Docker network. In docker-compose, they connect
-- via the 'gibber_transports' bridge network.
