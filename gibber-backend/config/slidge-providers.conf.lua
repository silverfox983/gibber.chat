-- Slidge Gateway Provider Configuration (base file)
--
-- NOTE: This file only needs to be VALID LUA so Prosody's include succeeds.
-- In the monolith deployment (railway.Dockerfile), the entrypoint script
-- regenerates this file from GIBBER_* environment variables before Prosody
-- starts, so its contents here are overridden. The split docker-compose
-- deployment (root docker-compose.yml) defines the gateway components in
-- "slidge-user-components.conf" instead.

component_secret = os.getenv("SLIDGE_COMPONENT_SECRET") or "change-me-in-production"