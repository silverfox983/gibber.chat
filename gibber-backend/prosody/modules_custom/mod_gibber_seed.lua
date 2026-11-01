-- Starter-node seeding: gives a fresh self-hosted server content on the
-- landing page's Spaces preview and inside the app, without a first-run
-- wizard. Runs on the PubSub/Spaces component host, directly against the
-- mod_pubsub service API, so no accounts or iq round-trips are involved.
--
-- Configuration (set on the component host):
--   gibber_starter_nodes = {
--     { node = "welcome"; title = "Welcome"; description = "..."; },
--     ...
--   }
--
-- Created nodes are owned by "admin@<domain>" (when present) and otherwise
-- belong to the server itself (actor = true). Safe to re-run: existing nodes
-- are left untouched.

local st = require "prosody.util.stanza";
local timer = require "prosody.util.timer";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";

local default_starters = {
	{ node = "welcome"; title = "Welcome"; description = "Start here: what this server is about and first steps."; },
	{ node = "general"; title = "General"; description = "Everything and anything - say hello!"; },
	{ node = "support"; title = "Support"; description = "Questions, feedback and help."; },
};

local function seed()
	local host_mods = (prosody.hosts[module.host] or {}).modules;
	if host_mods == nil or host_mods.pubsub == nil or host_mods.pubsub.service == nil then
		module:log("warn", "No pubsub service on %s - skipping starter seeding", module.host);
		return;
	end
	local service = host_mods.pubsub.service;
	local domain = module:get_option_string("gibber_domain");
	local starterNodes = module:get_option("gibber_starter_nodes", default_starters);

	for _, spec in ipairs(starterNodes) do
		local ok, err = service:create(spec.node, true, {
			title = spec.title;
			description = spec.description;
			type = "urn:xmpp:spaces:0";
			access_model = "open";
			publish_model = "publishers";
			persist_items = true;
			max_items = 10000;
			deliver_notifications = true;
			deliver_payloads = true;
		});
		if ok then
			module:log("info", "Seeded starter space %s (%s)", spec.node, spec.title);
			if domain ~= nil and domain ~= "" then
				service:set_affiliation(spec.node, true, "admin@" .. domain, "owner");
			end
			local item = st.stanza("item", { xmlns = xmlns_pubsub; id = "intro" })
				:tag("entry", { xmlns = "http://www.w3.org/2005/Atom" })
					:tag("title"):text("Welcome to " .. spec.title):up()
					:tag("summary"):text(
						(spec.description or "") ..
						" Create your own space with the Spaces tab, join the trending IRC rooms from the front page, or bridge this server to Telegram, Discord, WhatsApp and Matrix with the Networks panel.")
					:up()
					:tag("updated"):text(os.date("!%Y-%m-%dT%H:%M:%SZ")):up();
			local published, perr = service:publish(spec.node, true, "intro", item);
			if not published then
				module:log("debug", "Could not publish intro item on %s: %s", spec.node, perr or "?");
			end
		else
			module:log("debug", "Starter space %s not created: %s", spec.node, err or "exists");
		end
	end
end

timer.add_task(1, seed);