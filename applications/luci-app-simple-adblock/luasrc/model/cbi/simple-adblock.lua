-- Copyright 2016-2018 Stan Grishin <stangri@melmac.net>
-- Licensed to the public under the Apache License 2.0.

local readmeURL = "https://github.com/openwrt/packages/tree/master/net/simple-adblock/files/README.md"
-- local readmeURL = "https://github.com/stangri/openwrt_packages/tree/master/simple-adblock/files/README.md"

local packageName = "simple-adblock"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local nutil = require "nixio.util"
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local enabledFlag = uci:get(packageName, "config", "enabled")
local command, outputFile, outputCache, outputGzip
local targetDNS = uci:get(packageName, "config", "dns")
local checkDnsmasq = sys.call("which dnsmasq >/dev/null 2>&1") == 0 and true
local checkUnbound = sys.call("which unbound >/dev/null 2>&1") == 0 and true
local checkDnsmasqIpset = sys.call("dnsmasq -v 2>/dev/null | grep -q 'no-ipset' || ! dnsmasq -v 2>/dev/null | grep -q -w 'ipset'") ~= 0
   and sys.call("ipset help hash:net >/dev/null 2>&1") and true

if not targetDNS or targetDNS == "" then
	targetDNS = "dnsmasq.servers"
end

if targetDNS ~= "dnsmasq.addnhosts" and targetDNS ~= "dnsmasq.conf" and 
	 targetDNS ~= "dnsmasq.ipset" and targetDNS ~= "dnsmasq.servers" and 
	 targetDNS ~= "unbound.adb_list" then
	targetDNS = "dnsmasq.servers"
end

if targetDNS == "dnsmasq.addnhosts" then
	outputFile="/var/run/" .. packageName .. ".addnhosts"
	outputCache="/var/run/" .. packageName .. ".addnhosts.cache"
	outputGzip="/etc/" .. packageName .. ".addnhosts.gz"
elseif targetDNS == "dnsmasq.conf" then
	outputFile="/var/dnsmasq.d/" .. packageName .. ""
	outputCache="/var/run/" .. packageName .. ".dnsmasq.cache"
	outputGzip="/etc/" .. packageName .. ".dnsmasq.gz"
elseif targetDNS == "dnsmasq.servers" then
	outputFile="/var/run/" .. packageName .. ".servers"
	outputCache="/var/run/" .. packageName .. ".servers.cache"
	outputGzip="/etc/" .. packageName .. ".servers.gz"
elseif targetDNS == "unbound.adb_list" then
	outputFile="/var/lib/unbound/adb_list." .. packageName .. ""
	outputCache="/var/run/" .. packageName .. ".unbound.cache"
	outputGzip="/etc/" .. packageName .. ".unbound.gz"
end

local tmpfs, tmpfsMessage, tmpfsError, tmpfsStats
local tmpfsVersion, tmpfsStatus = "", "Stopped"
if fs.access("/var/run/" .. packageName .. ".json") then
	tmpfs = jsonc.parse(util.trim(sys.exec("cat /var/run/" .. packageName .. ".json")))
end

if tmpfs and tmpfs['data'] then
	if tmpfs['data']['status'] and tmpfs['data']['status'] ~= "" then
		tmpfsStatus = tmpfs['data']['status']
	end
	if tmpfs['data']['message'] and tmpfs['data']['message'] ~= "" then
		tmpfsMessage = tmpfs['data']['message']
	end
	if tmpfs['data']['error'] and tmpfs['data']['error'] ~= "" then
		tmpfsError = tmpfs['data']['error']
	end
	if tmpfs['data']['stats'] and tmpfs['data']['stats'] ~= "" then
		tmpfsStats = tmpfs['data']['stats']
	end
	if tmpfs['data']['version'] and tmpfs['data']['version'] ~= "" then
		tmpfsVersion = packageName .. " " .. tmpfs['data']['version']
	else 
		tmpfsVersion = packageName
	end
end

local statusTable = {}
local errorTable = {}
statusTable["statusNoInstall"] = packageName .. translate("is not installed or not found")
statusTable["statusStopped"] = translate("Stopped")
statusTable["statusStarting"] = translate("Starting")
statusTable["statusRestarting"] = translate("Restarting")
statusTable["statusForceReloading"] = translate("Force Reloading")
statusTable["statusDownloading"] = translate("Downloading")
statusTable["statusError"] = translate("Error")
statusTable["statusWarning"] = translate("Warning")
statusTable["statusFail"] = translate("Fail")
statusTable["statusSuccess"] = translate("Success")
errorTable["errorOutputFileCreate"] = translate("failed to create") .. " '" .. outputFile .. "' " .. translate("file")
errorTable["errorFailDNSReload"] = translate("failed to restart/reload DNS resolver")
errorTable["errorSharedMemory"] = translate("failed to access shared memory")
errorTable["errorSorting"] = translate("failed to sort data file")
errorTable["errorOptimization"] = translate("failed to optimize data file")
errorTable["errorWhitelistProcessing"] = translate("failed to process whitelist")
errorTable["errorDataFileFormatting"] = translate("failed to format data file")
errorTable["errorMovingDataFile"] = translate("failed to move temporary data file to") .. " '" .. outputFile .. "'"
errorTable["errorCreatingCompressedCache"] = translate("failed to create compressed cache")
errorTable["errorRemovingTempFiles"] = translate("failed to remove temporary files")
errorTable["errorRestoreCompressedCache"] = translate("failed to unpack compressed cache")
errorTable["errorRestoreCache"] = translate("failed to move") .. " '" .. outputCache .. "' " .. translate("to") .. " '" .. outputFile .. "'"
errorTable["errorOhSnap"] = translate("failed to create blocklist or restart DNS resolver")
errorTable["errorStopping"] = translate("failed to stop") .. " " .. packageName
errorTable["errorDNSReload"] = translate("failed to reload/restart DNS resolver")
errorTable["errorDownloadingList"] = translate("failed to download")
errorTable["errorParsingList"] = translate("failed to parse")

m = Map("simple-adblock", translate("Simple AdBlock Settings"))
m.apply_on_parse = true
m.on_after_apply = function(self)
	sys.call("/etc/init.d/simple-adblock restart")
end

h = m:section(NamedSection, "config", "simple-adblock", translate("Service Status") .. " [" .. tmpfsVersion .. "]")

if tmpfsStatus == "statusStarting" or
	 tmpfsStatus == "statusRestarting" or
	 tmpfsStatus == "statusForceReloading" or
	 tmpfsStatus == "statusDownloading" then
	ss = h:option(DummyValue, "_dummy", translate("Service Status"))
	ss.template = "simple-adblock/status"
	ss.value = statusTable[tmpfsStatus] .. '...'
	if tmpfsMessage then
		sm = h:option(DummyValue, "_dummy", translate("Task"))
		sm.template = "simple-adblock/status"
		sm.value = tmpfsMessage
	end
else
	if tmpfsStatus == "statusStopped" then
		ss = h:option(DummyValue, "_dummy", translate("Service Status"))
		ss.template = "simple-adblock/status"
		ss.value = statusTable[tmpfsStatus]
		if fs.access(outputCache) then
			sm = h:option(DummyValue, "_dummy", translate("Info"))
			sm.template = "simple-adblock/status"
			sm.value = translate("Cache file containing") .. " " .. util.trim(sys.exec("wc -l < " .. outputCache)) .. " " .. translate("domains found") .. "."
		elseif fs.access(outputGzip) then
			sm = h:option(DummyValue, "_dummy", translate("Info"))
			sm.template = "simple-adblock/status"
			sm.value = translate("Compressed cache file found") .. "."
		end
	else
		ss = h:option(DummyValue, "_dummy", translate("Service Status"))
		ss.template = "simple-adblock/status"
		if tmpfsStatus == "statusSuccess" then
			ss.value = tmpfsVersion .. " " .. translate("is blocking") .. 
				" " .. util.trim(sys.exec("wc -l < " .. outputFile)) .. 
				" " .. translate("domains") .. " (" .. translate("with") .. 
				" " .. targetDNS .. ")."
		else
			ss.value = statusTable[tmpfsStatus]
		end
		if tmpfsMessage then
			ms = h:option(DummyValue, "_dummy", translate("Message"))
			ms.template = "simple-adblock/status"
			ms.value = tmpfsMessage
		end
		if tmpfsError then
			es = h:option(DummyValue, "_dummy", translate("Collected Errors"))
			es.template = "simple-adblock/error"
			es.value = ""
			local err, e, url
			for err in tmpfsError:gmatch("[%p%w]+") do
				if err:match("=") then
					e,url = err:match("(.+)=(.+)")
					es.value = es.value .. translate("Error") .. ": " .. errorTable[e] .. " " .. url .. ".\n"
				else
					es.value = es.value .. translate("Error") .. ": " .. errorTable[err] .. ".\n"
				end
			end
		end
	end
	if tmpfsVersion ~= "" then
		buttons = h:option(DummyValue, "_dummy")
		buttons.template = packageName .. "/buttons"
	end
end

s = m:section(NamedSection, "config", "simple-adblock", translate("Configuration"))
-- General options
s:tab("basic", translate("Basic Configuration"))

o2 = s:taboption("basic", ListValue, "verbosity", translate("Output Verbosity Setting"), translate("Controls system log and console output verbosity."))
o2:value("0", translate("Suppress output"))
o2:value("1", translate("Some output"))
o2:value("2", translate("Verbose output"))
o2.default = 2

o3 = s:taboption("basic", ListValue, "force_dns", translate("Force Router DNS"), translate("Forces Router DNS use on local devices, also known as DNS Hijacking."))
o3:value("0", translate("Let local devices use their own DNS servers if set"))
o3:value("1", translate("Force Router DNS server to all local devices"))
o3.default = 1

local sysfs_path = "/sys/class/leds/"
local leds = {}
if fs.access(sysfs_path) then
	leds = nutil.consume((fs.dir(sysfs_path)))
end
if #leds ~= 0 then
	o4 = s:taboption("basic", Value, "led", translate("LED to indicate status"), translate("Pick the LED not already used in")
		.. [[ <a href="]] .. dispatcher.build_url("admin", "system", "leds") .. [[">]]
		.. translate("System LED Configuration") .. [[</a>]] .. ".")
	o4.rmempty = false
	o4:value("", translate("none"))
	for k, v in ipairs(leds) do
		o4:value(v)
	end
end

s:tab("advanced", translate("Advanced Configuration"))

local dns_descr = translate("Pick the DNS resolution option to create the adblock list for, see the") .. " "
		.. [[<a href="]] .. readmeURL .. [[#dns-resolution-option" target="_blank">]]
		.. translate("README") .. [[</a>]] .. " " .. translate("for details.")

if not checkDnsmasq then
	dns_descr = dns_descr .. "<br />" .. translate("Please note that") .. " <i>dnsmasq.addnhosts</i> " .. translate("is not supported on this system.")
	dns_descr = dns_descr .. "<br />" .. translate("Please note that") .. " <i>dnsmasq.conf</i> " .. translate("is not supported on this system.")
	dns_descr = dns_descr .. "<br />" .. translate("Please note that") .. " <i>dnsmasq.ipset</i> " .. translate("is not supported on this system.")
	dns_descr = dns_descr .. "<br />" .. translate("Please note that") .. " <i>dnsmasq.servers</i> " .. translate("is not supported on this system.")
elseif not checkDnsmasqIpset then 
	dns_descr = dns_descr .. "<br />" .. translate("Please note that") .. " <i>dnsmasq.ipset</i> " .. translate("is not supported on this system.")
end
if not checkUnbound then 
	dns_descr = dns_descr .. "<br />" .. translate("Please note that") .. " <i>unbound.adb_list</i> " .. translate("is not supported on this system.")
end

dns = s:taboption("advanced", ListValue, "dns", translate("DNS Service"), dns_descr)
if checkDnsmasq then
	dns:value("dnsmasq.addnhosts", translate("DNSMASQ Additional Hosts"))
	dns:value("dnsmasq.conf", translate("DNSMASQ Config"))
	if checkDnsmasqIpset then
		dns:value("dnsmasq.ipset", translate("DNSMASQ IP Set"))
	end
	dns:value("dnsmasq.servers", translate("DNSMASQ Servers File"))
end
if checkUnbound then
	dns:value("unbound.adb_list", translate("Unbound AdBlock List"))
end
dns.default = "dnsmasq.servers"

ipv6 = s:taboption("advanced", ListValue, "ipv6_enabled", translate("IPv6 Support"), translate("Add IPv6 entries to block-list."))
ipv6:value("", translate("Do not add IPv6 entries"))
ipv6:value("1", translate("Add IPv6 entries"))
ipv6:depends({dns="dnsmasq.addnhosts"}) 
ipv6.default = ""
ipv6.rmempty = true

o5 = s:taboption("advanced", Value, "boot_delay", translate("Delay (in seconds) for on-boot start"), translate("Run service after set delay on boot."))
o5.default = 120
o5.datatype = "range(1,600)"

o6 = s:taboption("advanced", Value, "download_timeout", translate("Download time-out (in seconds)"), translate("Stop the download if it is stalled for set number of seconds."))
o6.default = 10
o6.datatype = "range(1,60)"

o7 = s:taboption("advanced", Value, "curl_retry", translate("Curl download retry"), translate("If curl is installed and detected, it would retry download this many times on timeout/fail."))
o7.default = 3
o7.datatype = "range(0,30)"

o8 = s:taboption("advanced", ListValue, "parallel_downloads", translate("Simultaneous processing"), translate("Launch all lists downloads and processing simultaneously, reducing service start time."))
o8:value("0", translate("Do not use simultaneous processing"))
o8:value("1", translate("Use simultaneous processing"))
o8.default = 1

o10 = s:taboption("advanced", ListValue, "compressed_cache", translate("Store compressed cache file on router"), translate("Attempt to create a compressed cache of block-list in the persistent memory."))
o10:value("0", translate("Do not store compressed cache"))
o10:value("1", translate("Store compressed cache"))
o10.default = "0"

o11 = s:taboption("advanced", ListValue, "debug", translate("Enable Debugging"), translate("Enables debug output to /tmp/simple-adblock.log."))
o11:value("0", translate("Disable Debugging"))
o11:value("1", translate("Enable Debugging"))
o11.default = "0"


s2 = m:section(NamedSection, "config", "simple-adblock", translate("Whitelist and Blocklist Management"))
-- Whitelisted Domains
d1 = s2:option(DynamicList, "whitelist_domain", translate("Whitelisted Domains"), translate("Individual domains to be whitelisted."))
d1.addremove = false
d1.optional = false

-- Blacklisted Domains
d3 = s2:option(DynamicList, "blacklist_domain", translate("Blacklisted Domains"), translate("Individual domains to be blacklisted."))
d3.addremove = false
d3.optional = false

-- Whitelisted Domains URLs
d2 = s2:option(DynamicList, "whitelist_domains_url", translate("Whitelisted Domain URLs"), translate("URLs to lists of domains to be whitelisted."))
d2.addremove = false
d2.optional = false

-- Blacklisted Domains URLs
d4 = s2:option(DynamicList, "blacklist_domains_url", translate("Blacklisted Domain URLs"), translate("URLs to lists of domains to be blacklisted."))
d4.addremove = false
d4.optional = false

-- Blacklisted Hosts URLs
d5 = s2:option(DynamicList, "blacklist_hosts_url", translate("Blacklisted Hosts URLs"), translate("URLs to lists of hosts to be blacklisted."))
d5.addremove = false
d5.optional = false

return m
