-- Gibber XMPP Server Configuration (Prosody)
-- Prosody: https://prosody.im/

-- Global server settings
http_ports = { 5280 }
https_ports = { 5281 }
http_interfaces = { "0.0.0.0" }
https_interfaces = { "0.0.0.0" }
cross_domain_bosh = true
cross_domain_websocket = true
consider_websocket_secure = true

-- Allow in-band registration (so Gibber client can create accounts)
allow_registration = true
registration_throttle_max = 10
registration_throttle_period = 60

-- Connection limits
c2s_stanza_size_limit = 65536
s2s_stanza_size_limit = 65536

-- Storage backend
storage = "internal"

-- TLS/SSL certificates for S2S federation
-- In Railway: acme.sh provisions Let's Encrypt certs via DNS-01 challenge
-- In docker-compose: Caddy handles TLS, certs shared via volume mount
ssl = {
    certificate = "/etc/prosody/certs/gibberapp.online.crt";
    key = "/etc/prosody/certs/gibberapp.online.key";
    capath = "/etc/ssl/certs";
}

-- Client-to-server encryption
-- PLAIN auth allowed because the WS proxy strips STARTTLS;
-- real TLS is handled by Caddy reverse proxy (docker-compose) or WSS from browser (Railway)
c2s_require_encryption = false
allow_unencrypted_plain_auth = true

-- S2S federation: require encryption now that we have proper Let's Encrypt certs
-- These MUST be global settings (not per-VirtualHost) to affect outbound S2S
s2s_require_encryption = true
s2s_secure_auth = true

-- Server contact info (XEP-0157)
contact_info = {
    admin = { "mailto:admin@gibberapp.online", "xmpp:admin@gibberapp.online" };
    abuse = { "mailto:abuse@gibberapp.online" };
    security = { "mailto:security@gibberapp.online" };
}

-- Server domain
VirtualHost "gibberapp.online"
modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "dialback";
    "disco";
    "carbons";
    "mam";
    "private";
    "vcard";
    "register";
    "admin_adhoc";
    "blocklist";
    "csi";
    "ping";
    "uptime";
    "version";
    "welcome";
    "http";
    "bosh";
    "websocket";
    "smacks";
    "http_file_share";
    "extdisco";
}

-- MAM (XEP-0313): Archive messages for offline retrieval
mam_max_archived_messages = 500

-- HTTP File Upload (XEP-0363)
http_file_share_size_limit = 50 * 1024 * 1024  -- 50 MB
http_file_share_expire_after = 7 * 86400  -- 7 days
http_paths = {
    file_share = "/upload";
}

-- External Service Discovery (XEP-0215) - STUN/TURN for WebRTC
external_services = {
    {
        type = "stun",
        transport = "udp",
        host = "gibberapp.online",
        port = 3478
    },
    {
        type = "turn",
        transport = "udp",
        host = "gibberapp.online",
        port = 3478,
        username = "gibber",
        password = "gibber-turn-secret-change-in-production"
    },
    {
        type = "turns",
        transport = "tcp",
        host = "gibberapp.online",
        port = 5349,
        username = "gibber",
        password = "gibber-turn-secret-change-in-production"
    }
}

-- Stream Management (XEP-0198)
smacks_hibernation_time = 300  -- 5 minutes
smacks_max_ack_delay = 30
smacks_max_resume_timeout = 600  -- 10 minutes

-- Welcome message
welcome_message = "Welcome to Gibber! Your account has been created successfully."

-- MUC (Multi-User Chat) for group channels
Component "conference.gibberapp.online" "muc"
modules_enabled = { 
    "vcard";
    "muc_mam";
}
muc_room_default_public = true
muc_room_default_persistent = true
muc_room_default_members_only = false
muc_room_default_allow_member_invites = true
muc_room_default_change_subject = true
muc_room_default_history_length = 50
muc_room_locking = false
muc_room_default_anonymous = false

-- Gateway transports (require backend authorization)
-- Component "slack.gibberapp.online" "slack_bridge"
-- Component "discord.gibberapp.online" "discord_bridge"
-- Component "irc.gibberapp.online" "irc_gateway"

-- Logging
log = {
    info = "*console";
    warn = "*console";
    error = "*console";
}

-- Data path
data_path = "/var/lib/prosody"

-- PID file
pidfile = "/var/run/prosody/prosody.pid"