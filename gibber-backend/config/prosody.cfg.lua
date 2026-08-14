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
registration_throttle_max = 3
registration_throttle_period = 60

-- Storage backend
storage = "internal"

-- Self-signed cert for development
ssl = {
    certificate = "/etc/prosody/certs/gibberapp.online.crt";
    key = "/etc/prosody/certs/gibberapp.online.key";
}

-- Require encryption for client connections
c2s_require_encryption = false

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
}

-- MUC (Multi-User Chat) for group channels
Component "conference.gibberapp.online" "muc"
modules_enabled = { "vcard"; }
muc_room_default_public = true
muc_room_default_persistent = true
muc_room_default_members_only = false

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