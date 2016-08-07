--- Device and queue configuration

local mod = {}

local phobos     = require "phobos"
local ffi        = require "ffi"
local dpdkc      = require "dpdkc"
local dpdk       = require "dpdk"
local memory     = require "memory"
local serpent    = require "Serpent"
local log        = require "log"
local namespaces = require "namespaces"
local pciIds     = require "pci-ids"
local drivers    = require "drivers"
require "headers"

function mod.init()
	dpdkc.rte_pmd_init_all_export();
	dpdkc.rte_eal_pci_probe();
end

function mod.numDevices()
	return dpdkc.rte_eth_dev_count();
end

local dev = {}
dev.__index = dev

function dev:__tostring()
	return ("[Device: id=%d]"):format(self.id)
end

function dev:__serialize()
    return "require 'device' local dev = " .. serpent.addMt(serpent.dumpRaw(self), "require('device').__devicePrototype") .. " dev:checkSocket() return dev", true
end

local txQueue = {}
txQueue.__index = txQueue

function txQueue:__tostring()
	return ("[TxQueue: id=%d, qid=%d]"):format(self.id, self.qid)
end

function txQueue:__serialize()
	return ('local dev = require "device" return dev.get(%d):getTxQueue(%d)'):format(self.id, self.qid), true
end

local rxQueue = {}
rxQueue.__index = rxQueue

function rxQueue:__tostring()
	return ("[RxQueue: id=%d, qid=%d]"):format(self.id, self.qid)
end

function rxQueue:__serialize()
	return ('local dev = require "device" return dev.get(%d):getRxQueue(%d)'):format(self.id, self.qid), true
end


local devices = namespaces:get()

--- Configure a device
--- @param args A table containing the following named arguments
---   port Port to configure
---   mempools optional (default = create new mempools) RX mempools to associate with the queues
---   rxQueues optional (default = 1) Number of RX queues to configure 
---   txQueues optional (default = 1) Number of TX queues to configure 
---   rxDescs optional (default = 512)
---   txDescs optional (default = 1024)
---   speed optional (default = 0/max) Speed in Mbit to negotiate (currently disabled due to DPDK changes)
---   dropEnable optional (default = true) Drop rx packets directly if no rx descriptors are available
---   rssQueues optional (default = 0) Number of queues to use for RSS
---   rssBaseQueue optional (default = 0) The first queue to use for RSS, packets will go to queues rssBaseQueue up to rssBaseQueue + rssQueues - 1
---   rssFunctions optional (default = all supported functions) Table with hash functions specified in dpdk.ETH_RSS_*
---	  disableOffloads optional (default = false) Disable all offloading features, this significantly speeds up some drivers (e.g. ixgbe)
---   stripVlan (default = true) Strip the VLAN tag on the NIC.
function mod.config(args)
	if not args or not args.port then
		log:fatal("usage: device.config({ port = x, ... })")
	end
	if args.port >= dpdkc.dpdk_get_max_ports() then
		log:fatal("maximum number of supported ports is %d, this can be changed with the DPDK compile-time configuration variable RTE_MAX_ETHPORTS\n", dpdkc.dpdk_get_max_ports())
	end
	if args.port >= dpdkc.rte_eth_dev_count() then
		log:fatal("there are only %d ports, tried to configure port id %d", dpdkc.rte_eth_dev_count(), args.port)
	end
	if mod.get(args.port) and mod.get(args.port).initialized then
		log:warn("Device %d already configured, skipping initilization", args.port)
		return mod.get(args.port)
	end
	args.rxQueues = args.rxQueues or 1
	args.txQueues = args.txQueues or 1
	args.rxDescs = args.rxDescs or 512
	args.txDescs = args.txDescs or 1024
	args.rssQueues = args.rssQueues or 0
	args.rssFunctions = args.rssFunctions or {
		dpdk.ETH_RSS_IPV4,
		dpdk.ETH_RSS_FRAG_IPV4,
		dpdk.ETH_RSS_NONFRAG_IPV4_TCP,
		dpdk.ETH_RSS_NONFRAG_IPV4_UDP,
		dpdk.ETH_RSS_NONFRAG_IPV4_SCTP,
		dpdk.ETH_RSS_NONFRAG_IPV4_OTHER,
		dpdk.ETH_RSS_IPV6,
		dpdk.ETH_RSS_FRAG_IPV6,
		dpdk.ETH_RSS_NONFRAG_IPV6_TCP,
		dpdk.ETH_RSS_NONFRAG_IPV6_UDP,
		dpdk.ETH_RSS_NONFRAG_IPV6_SCTP,
		dpdk.ETH_RSS_NONFRAG_IPV6_OTHER,
		dpdk.ETH_RSS_L2_PAYLOAD,
		dpdk.ETH_RSS_IPV6_EX,
		dpdk.ETH_RSS_IPV6_TCP_EX,
		dpdk.ETH_RSS_IPV6_UDP_EX
	}
	local rssMask = 0
	for i, v in ipairs(args.rssFunctions) do
		rssMask = bit.bor(rssMask, v)
	end
	if args.stripVlan == nil then
		args.stripVlan = true
	end
	if args.dropEnable == nil then
		args.dropEnable = true
	end
	-- create mempools for rx queues
	if not args.mempools then
		args.mempools = {}
		for i = 1, args.rxQueues do
			table.insert(args.mempools, memory.createMemPool{n = 2047, socket = dpdkc.dpdk_get_socket(args.port)})
		end
	elseif #args.mempools ~= args.rxQueues then
		log:fatal("number of mempools must equal number of rx queues")
	end
	args.speed = args.speed or 0
	if args.rxQueues == 0 or args.txQueues == 0 then
		-- dpdk does not like devices without rx/tx queues :(
		log:fatal("Cannot initialize device without %s queues", args.rxQueues == 0 and args.txQueues == 0 and "rx and tx" or args.rxQueues == 0 and "rx" or "tx")
	end
	local mempools = ffi.new("struct mempool*[?]", args.rxQueues)
	for i, v in ipairs(args.mempools) do
		mempools[i - 1] = v
	end
	local rc = dpdkc.dpdk_configure_device(ffi.new("struct phobos_device_config", {
		port = args.port,
		mempools = mempools,
		rx_queues = args.rxQueues,
		tx_queues = args.txQueues,
		rx_descs = args.rxDescs,
		tx_descs = args.txDescs,
		drop_enable = args.dropEnable,
		enable_rss = args.rssQueues > 1,
		rss_mask = rssMask,
		disable_offloads = args.disableOffloads,
		strip_vlan = args.stripVlan
	}))
	if rc ~= 0 then
	    log:fatal("Could not configure device %d: error %d", args.port, rc)
	end
	local dev = mod.get(args.port)
	dev.initialized = true
	dev:store()
	if args.rssQueues > 1 then
		dev:setRssQueues(args.rssQueues, args.rssBaseQueue)
	end
	dev:setPromisc(true)
	return dev
end

ffi.cdef[[
struct rte_eth_rss_reta_entry64 {
	uint64_t mask;
	uint16_t reta[64];
};

int rte_eth_dev_rss_reta_update(uint8_t port, struct rte_eth_rss_reta_entry64* reta_conf, uint16_t reta_size);
uint16_t dpdk_get_reta_size(int port);
]]

--- Setup RSS RETA table.
function dev:setRssQueues(n, baseQueue)
	baseQueue = baseQueue or 0
	assert(n > 0)
	if bit.band(n, n - 1) ~= 0 then
		log:warn("RSS distribution to queues will not be balanced as the number of queues (%d) is not a power of two.", n)
	end
	local retaSize = ffi.C.dpdk_get_reta_size(self.id)
	if retaSize % 64 ~= 0 then
		log:fatal("NYI: number of RETA entries is not a multiple of 64", retaSize)
	end
	local entries = ffi.new("struct rte_eth_rss_reta_entry64[?]", retaSize / 64)
	local queue = baseQueue
	for i = 0, retaSize / 64 - 1 do
		entries[i].mask = 0xFFFFFFFFFFFFFFFFULL
		for j = 0, 63 do
			entries[i].reta[j] = queue
			queue = queue + 1
			if queue == baseQueue + n then
				queue = baseQueue
			end
		end
	end
	local ret = ffi.C.rte_eth_dev_rss_reta_update(self.id, entries, retaSize)
	if ret ~= 0 then
		log:fatal("Error setting up RETA table: " .. errors.getstr(-ret))
	end
end

function mod.get(id)
	if type(id) ~= "number" then
		log:fatal("bad argument #1, expected number, got " .. type(id))
	end
	local obj
	local idStr = tostring(id)
	if devices[idStr] then
		obj = devices[idStr]
	else
		obj = setmetatable({id = id, rxQueues = {}, txQueues = {}}, dev)
		devices[idStr] = obj
	end
	local driver = drivers[obj:getDriverName()]
	if driver then
		driver.initDriver(obj)
	end
	return obj
end

function dev:store()
	local idStr = tostring(self.id)
	devices[idStr] = self
end

function dev:getTxQueue(id)
	local tbl = self.txQueues
	if tbl[id] then
		return tbl[id]
	end
	tbl[id] = setmetatable({id = self.id, qid = id, dev = self}, txQueue)
	return tbl[id]
end

function dev:getRxQueue(id)
	local tbl = self.rxQueues
	if tbl[id] then
		return tbl[id]
	end
	tbl[id] = setmetatable({id = self.id, qid = id, dev = self}, rxQueue)
	return tbl[id]
end

local warningShown = {} -- per-core
function dev:checkSocket()
	if MOONGEN_TASK_NAME ~= "master" and not MOONGEN_IGNORE_BAD_NUMA_MAPPING then
		-- check the NUMA association if we are running in a worker thread
		-- (it's okay to do the initial config from the wrong socket, but sending packets from it is a bad idea)
		local devSocket = self:getSocket()
		local core, threadSocket = phobos.getCore()
		if devSocket ~= threadSocket then
			if not warningShown[self.id] then
				warningShown[self.id] = true
				log:warn("You are trying to use %s (attached to CPU socket %d) from a thread on core %d on socket %d!",
					self, devSocket, core, threadSocket)
				log:warn("This can significantly impact the performance or even not work at all")
				log:warn("You can change the used CPU cores in dpdk-conf.lua or by using dpdk.startTaskOnCore(core, ...)")
			end
			return false
		end
	end
	return true
end


--- Waits until all given devices are initialized by calling wait() on them.
function mod.waitForLinks(...)
	local ports
	if select("#", ...) == 0 then
		ports = {}
		devices:forEach(function(key, dev)
			if dev.initialized then
				ports[#ports + 1] = dev
			end
		end)
	else
		ports = { ... }
	end
	log:info("Waiting for devices to come up...")
	local portsUp = 0
	local portsSeen = {} -- do not wait twice if a port occurs more than once (e.g. if rx == tx)
	for i, port in ipairs(ports) do
		if not portsSeen[port] then
			portsSeen[port] = true
			portsUp = portsUp + (port:wait() and 1 or 0)
		end
	end
	log:info(green("%d devices are up.", portsUp))
end


--- Wait until the device is fully initialized and up to maxWait seconds to establish a link.
--- Logs the current link state.
-- @param maxWait maximum number of seconds to wait for the link, default = 9
function dev:wait(maxWait)
	maxWait = maxWait or 9
	local link
	repeat
		link = self:getLinkStatus()
		if maxWait > 0 then
			phobos.sleepMillisIdle(1000)
			maxWait = maxWait - 1
		else
			break
		end
	until link.status
	self.speed = link.speed
	log:info("Device %d (%s) is %s: %s%s MBit/s", self.id, self:getMacString(), link.status and "up" or "DOWN", link.duplexAutoneg and "" or link.duplex and "full-duplex " or "half-duplex ", link.speed)
	return link.status
end


function dev:getLinkStatus()
	local link = ffi.new("struct rte_eth_link")
	dpdkc.rte_eth_link_get_nowait(self.id, link)
	return {status = link.link_status == 1, duplexAutoneg = link.link_duplex == 0, duplex = link.link_duplex == 2, speed = link.link_speed}
end

function dev:getMacString()
	local buf = ffi.new("char[20]")
	dpdkc.dpdk_get_mac_addr(self.id, buf)
	return ffi.string(buf)
end

function dev:getMac(number)
	return parseMacAddress(self:getMacString(), number)
end

function dev:setPromisc(enable)
	if enable then
		dpdkc.rte_eth_promiscuous_enable(self.id)
	else
		dpdkc.rte_eth_promiscuous_disable(self.id)
	end
end

function dev:addMac(mac)
	local rc = dpdkc.rte_eth_dev_mac_addr_add(self.id, parseMacAddress(mac), 0)
	if rc ~= 0 then
		log:fatal("could not add mac: %d", rc)
	end
end

function dev:removeMac(mac)
	local rc = dpdkc.rte_eth_dev_mac_addr_remove(self.id, parseMacAddress(mac))
	if rc ~= 0 then
		log:fatal("could not remove mac: %d", rc)
	end
end

function dev:getPciId()
	return dpdkc.dpdk_get_pci_id(self.id)
end

function dev:getSocket()
	return dpdkc.dpdk_get_socket(self.id)
end

function dev:getName()
	return pciIds.getName(self:getPciId())
end

function dev:getDriverName()
	return ffi.string(dpdkc.dpdk_get_driver_name(self.id))
end

function mod.getDevices()
	local result = {}
	for i = 0, dpdkc.rte_eth_dev_count() - 1 do
		local dev = mod.get(i)
		result[#result + 1] = { id = i, mac = dev:getMacString(i), name = dev:getName(i) }
	end
	return result
end




ffi.cdef[[

   struct rte_eth_xstat_name {
           char name[64];
   };
   
int rte_eth_xstats_get_names(uint8_t port_id, struct rte_eth_xstat_name* names, uint32_t size);


]]

local ethStatsType

local function buildEthStatsStruct(n)
	return ffi.typeof(([[
	struct {
		uint64_t ipackets;  
		uint64_t opackets;  
		uint64_t ibytes;    
		uint64_t obytes;    
		uint64_t imissed;
		uint64_t ierrors;   
		uint64_t oerrors;   
		uint64_t rx_nombuf; 
		uint64_t q_ipackets[%d];
		uint64_t q_opackets[%d];
		uint64_t q_ibytes[%d];
		uint64_t q_obytes[%d];
		uint64_t q_errors[%d];
	}
	]]):format(n, n, n, n, n))
end

--- Get ethernet statistics.
--- Warning: the exact meaning of the results may vary between NICs, especially when packets are dropped due to full rx queues.
--- Also, they may sometimes be clear-on-read and sometimes running totals; stats are just wildly inconsistent in DPDK.
--- Counting packets at the application-level might be a good idea if you want to support different NICs.
function dev:getStats()
	if not ethStatsType then
		ethStatsType = buildEthStatsStruct(dpdkc.dpdk_get_rte_queue_stat_cntrs_num())
	end
	local stats = ethStatsType()
	dpdkc.rte_eth_stats_get(self.id, stats)
	return stats
end

do
	local stats
	--- Get the total number of packets and bytes transmitted successfully.
	--- This does not include packets that were queued but not yet sent by the NIC.
	--- @return packets, bytes
	function dev:getTxStats()
		if not ethStatsType then
			ethStatsType = buildEthStatsStruct(dpdkc.dpdk_get_rte_queue_stat_cntrs_num())
		end
		if not stats then
			stats = ethStatsType()
		end
		dpdkc.rte_eth_stats_get(self.id, stats)
		-- in case you are wondering: the precision of a double starts the become a minor problem after 4.17 days at 100 gbit/s
		return tonumber(stats.opackets), tonumber(stats.obytes)
	end
	
	--- Get the number packets and bytes received at the physical layer regardless whether they were received by the driver.
	--- The drivers may be inconsistent regarding counting of packets dropped due to insufficient buffer space, tested with
	--- ixgbe, igb, and i40e NICs.
	--- Use dev:getStats() to distinguish between packets delivered to the driver and packets dropped by the NIC.
	--- @return packets, bytes
	function dev:getRxStats()
		if not ethStatsType then
			ethStatsType = buildEthStatsStruct(dpdkc.dpdk_get_rte_queue_stat_cntrs_num())
		end
		if not stats then
			stats = ethStatsType()
		end
		dpdkc.rte_eth_stats_get(self.id, stats)
		return tonumber(stats.ipackets + stats.imissed + stats.rx_nombuf), tonumber(stats.ibytes)
	end
end


--- Set the tx rate of a queue in Mbit/s.
--- This sets the payload rate, not to the actual wire rate, i.e. preamble, SFD, and IFG are ignored.
function txQueue:setRate(rate)
	local rc = dpdkc.rte_eth_set_queue_rate_limit(self.id, self.qid, rate)
	if rc == -ERR_NOTSUP then
		-- fails if doing this from multiple threads
		-- but that's okay since this is just a crude work-around and the app should be updated for the NIC
		local dev = self.dev
		dev.totalRate = dev.totalRate or 0
		dev.totalRate = dev.totalRate + rate
		log:warn("Per-queue rate limit is not supported on this device, setting per-device rate limit to %d Mbit/s instead (note: this may fail as well if the NIC doesn't support any rate limiting).", dev.totalRate)
		dev:setRate(dev.totalRate)
	elseif rc ~= 0 then
		log:warn("Failed to set rate limiter on queue %s: %s", self, strError(rc))
	end
end



function txQueue:send(bufs)
	self.used = true
	dpdkc.dpdk_send_all_packets(self.id, self.qid, bufs.array, bufs.size)
	return bufs.size
end

function txQueue:sendN(bufs, n)
	self.used = true
	dpdkc.dpdk_send_all_packets(self.id, self.qid, bufs.array, n)
	return n
end

function txQueue:start()
	assert(dpdkc.rte_eth_dev_tx_queue_start(self.id, self.qid) == 0)
end

function txQueue:stop()
	assert(dpdkc.rte_eth_dev_tx_queue_stop(self.id, self.qid) == 0)
end

--- Restarts all tx queues that were actively used by this task.
--- 'Actively used' means that :send() was called from the current task.
function mod.reclaimTxBuffers()
	devices:forEach(function(_, dev)
		for _, queue in pairs(dev.txQueues) do
			if queue.used then
				queue:stop()
				queue:start()
			end
		end
	end)
end

--- Receive packets from a rx queue.
--- Returns as soon as at least one packet is available.
function rxQueue:recv(bufArray, numpkts)
	numpkts = numpkts or bufArray.size
	while phobos.running() do
		local rx = dpdkc.rte_eth_rx_burst_export(self.id, self.qid, bufArray.array, math.min(bufArray.size, numpkts))
		if rx > 0 then
			return rx
		end
	end
	return 0
end

--- Receive packets from a rx queue and save timestamps in the udata64 field.
--- Returns as soon as at least one packet is available.
function rxQueue:recvWithTimestamps(bufArray, numpkts)
	numpkts = numpkts or bufArray.size
	return dpdkc.dpdk_receive_with_timestamps_software(self.id, self.qid, bufArray.array, math.min(bufArray.size, numpkts))
end

function rxQueue:getMacAddr()
  return ffi.cast("union mac_address", ffi.C.rte_eth_macaddr_get(self.id))
end

function txQueue:getMacAddr()
  return ffi.cast("union mac_address", ffi.C.rte_eth_macaddr_get(self.id))
end

--- Receive packets from a rx queue with a timeout.
function rxQueue:tryRecv(bufArray, maxWait)
	maxWait = maxWait or math.huge
	while maxWait >= 0 do
		local rx = dpdkc.rte_eth_rx_burst_export(self.id, self.qid, bufArray.array, bufArray.size)
		if rx > 0 then
			return rx
		end
		maxWait = maxWait - 1
		-- don't sleep pointlessly
		if maxWait < 0 then
			break
		end
		phobos.sleepMicros(1)
	end
	return 0
end

--- Receive packets from a rx queue with a timeout.
--- Does not perform a busy wait, this is not suitable for high-throughput applications.
function rxQueue:tryRecvIdle(bufArray, maxWait)
	maxWait = maxWait or math.huge
	while maxWait >= 0 do
		local rx = dpdkc.rte_eth_rx_burst_export(self.id, self.qid, bufArray.array, bufArray.size)
		if rx > 0 then
			return rx
		end
		maxWait = maxWait - 1
		-- don't sleep pointlessly
		if maxWait < 0 then
			break
		end
		phobos.sleepMicrosIdle(1)
	end
	return 0
end

-- export prototypes to extend them in other modules
mod.__devicePrototype = dev
mod.__txQueuePrototype = txQueue
mod.__rxQueuePrototype = rxQueue

return mod

