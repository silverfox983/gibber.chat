-- Minimal offline-message push trigger for the Gibber stack.
--
-- Replaces the upstream http_push module that stopped shipping with the
-- prosody 13.0 monolith image. When a chat message cannot be delivered
-- because the recipient is offline ("message/offline" pipeline event),
-- POST the raw stanza (plus the recipient JID and shared secret) to the
-- Gibber backend's /push/trigger endpoint, which routes it to the
-- recipient's web-push subscription.
--
-- Configuration (set on the VirtualHost):
--   http_push_endpoint = "http://127.0.0.1:8080/push/trigger"
--   http_push_secret   = "shared-secret"

local http = require "net.http";
local json_encode = require "util.json".encode;

local endpoint = module:get_option_string("http_push_endpoint");
local secret = module:get_option_string("http_push_secret");

local function user_host(stanza_to)
	local username, host = stanza_to:match("^([^@]+)@([^/@]+)$");
	return username, host;
end

module:hook("message/offline", function(event)
	local stanza = event.stanza;
	if not endpoint or not secret then return; end
	if stanza.name ~= "message" then return; end
	local stanza_type = stanza.attr.type;
	if stanza_type == "groupchat" or stanza_type == "error" then return; end
	if not stanza:get_child("body") then return; end

	local to = stanza.attr.to;
	if not to then return; end
	local username, host = user_host(to);
	if not host or host ~= module.host then return; end

	local payload = json_encode({
		secret = secret;
		jid = username .. "@" .. host;
		message = tostring(stanza);
	});
	if not payload then return; end

	http.request(endpoint, {
		method = "POST";
		body = payload;
		headers = { ["Content-Type"] = "application/json" };
	}, function (body, code)
		if code and code >= 400 then
			module:log("debug", "Push trigger for %s failed: %d %s", to, code or 0, body or "");
		else
			module:log("debug", "Push trigger for %s sent (status %s)", to, code or 0);
		end
	end);

	-- Never block the offline pipeline on the network call.
	return nil;
end, 100);