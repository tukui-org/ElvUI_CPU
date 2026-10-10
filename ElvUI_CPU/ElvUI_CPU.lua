local AddonName, Addon = ...

local E = LibStub("AceAddon-3.0"):GetAddon("ElvUI")
Addon.ElvUI = E

local print, type, pairs = print, type, pairs
local select, unpack = select, unpack
local string_find = string.find
local string_sub = string.sub
local string_gsub = string.gsub
local string_format = string.format
local string_byte = string.byte

local CreateFrame = CreateFrame
local GetCursorPosition = GetCursorPosition
local GetTime = GetTime

local CPU = { }
Addon.ElvUI_CPU = CPU
_G.ElvUI_CPU = CPU

CPU.events = CreateFrame("Frame")
CPU.events:RegisterEvent("ADDON_LOADED")
CPU.events:SetScript("OnEvent", function(self, event, ...)
	CPU[event](CPU, ...)
end)

CPU.functionRecords = { }
CPU.originalFunctions = { }
CPU.wrappedMarkers = { }
CPU.installedWrappers = { }
CPU.columnHeaders = { }
CPU.searchText = ""
CPU.sortColumnIndex = 7
CPU.sortDescending = true
CPU.refreshRunning = false
CPU.horizontalOffset = 0

CPU.columnDefinitions = {
	{ key = "name", title = "Function", width = 280, minimumWidth = 140, justify = "LEFT", tooltip = "Method name" },
	{ key = "calls", title = "Calls", width = 70, minimumWidth = 48, justify = "RIGHT", tooltip = "Calls" },
	{ key = "callsPerSecond", title = "Calls/sec", width = 90, minimumWidth = 48, justify = "RIGHT", tooltip = "Calls per second" },
	{ key = "peakMilliseconds", title = "Peak time", width = 90, minimumWidth = 48, justify = "RIGHT", tooltip = "Peak elapsedTicks" },
	{ key = "timePerCall", title = "Time/call", width = 90, minimumWidth = 48, justify = "RIGHT", tooltip = "Average elapsedTicks" },
	{ key = "recentTicksPerSecond", title = "Time/sec", width = 90, minimumWidth = 48, justify = "RIGHT", tooltip = "elapsedTicks added during the last refresh interval" },
	{ key = "totalMilliseconds", title = "Total time", width = 90, minimumWidth = 48, justify = "RIGHT", tooltip = "Total elapsedTicks" },
	{ key = "allocatedBytes", title = "Allocated", width = 100, minimumWidth = 64, justify = "RIGHT", tooltip = "allocatedBytes" },
	{ key = "deallocatedBytes", title = "Freed", width = 100, minimumWidth = 64, justify = "RIGHT", tooltip = "deallocatedBytes" },
	{ key = "retainedBytes", title = "Retained", width = 100, minimumWidth = 64, justify = "RIGHT", tooltip = "allocatedBytes minus deallocatedBytes" },
	{ key = "overallPercent", title = "Overall", width = 80, minimumWidth = 48, justify = "RIGHT", tooltip = "Share of all measured time" },
}

CPU.defaultFooterMetrics = {
	functionCount = true,
	lastTime = true,
	recentAverageTime = true,
	peakTime = true,
}

CPU.footerMetricDefinitions = {
	{ key = "functionCount", label = "Function count", column = 1 },
	{ key = "lastTime", label = "Last tick", footerLabel = "last", metric = Enum.AddOnProfilerMetric.LastTime, format = "time", column = 1 },
	{ key = "recentAverageTime", label = "Recent average", footerLabel = "recent", metric = Enum.AddOnProfilerMetric.RecentAverageTime, format = "time", column = 1 },
	{ key = "peakTime", label = "Peak tick", footerLabel = "peak", metric = Enum.AddOnProfilerMetric.PeakTime, format = "time", column = 1 },
	{ key = "sessionAverageTime", label = "Session average", footerLabel = "session", metric = Enum.AddOnProfilerMetric.SessionAverageTime, format = "time", column = 1 },
	{ key = "encounterAverageTime", label = "Encounter average", footerLabel = "encounter", metric = Enum.AddOnProfilerMetric.EncounterAverageTime, format = "time", column = 1 },
	{ key = "over1Ms", label = "Ticks over 1 ms", footerLabel = "over 1 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver1Ms, format = "count", column = 2 },
	{ key = "over5Ms", label = "Ticks over 5 ms", footerLabel = "over 5 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver5Ms, format = "count", column = 2 },
	{ key = "over10Ms", label = "Ticks over 10 ms", footerLabel = "over 10 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver10Ms, format = "count", column = 2 },
	{ key = "over50Ms", label = "Ticks over 50 ms", footerLabel = "over 50 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver50Ms, format = "count", column = 2 },
	{ key = "over100Ms", label = "Ticks over 100 ms", footerLabel = "over 100 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver100Ms, format = "count", column = 2 },
	{ key = "over500Ms", label = "Ticks over 500 ms", footerLabel = "over 500 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver500Ms, format = "count", column = 2 },
	{ key = "over1000Ms", label = "Ticks over 1000 ms", footerLabel = "over 1000 ms", metric = Enum.AddOnProfilerMetric.CountTimeOver1000Ms, format = "count", column = 2 },
}

local returnPackPool = { }

local function CaptureMeasuredReturns(callResults, ...)
	local packedReturns = returnPackPool[#returnPackPool]
	if packedReturns then
		returnPackPool[#returnPackPool] = nil
	else
		packedReturns = { }
	end

	local returnCount = select("#", ...)
	packedReturns.n = returnCount
	for returnIndex = 1, returnCount do
		packedReturns[returnIndex] = select(returnIndex, ...)
	end
	for returnIndex = returnCount + 1, (packedReturns.high or 0) do
		packedReturns[returnIndex] = nil
	end
	packedReturns.high = returnCount

	return callResults, packedReturns
end

local function RestorePackedReturns(packedReturns, ...)
	if packedReturns then
		returnPackPool[#returnPackPool + 1] = packedReturns
	end

	return ...
end

function CPU:Print(msg, ...)
	print("|cff1784d1ElvUI|r |cfffe7b2cCPU Analyzer|r: "..msg, ...)
end

function CPU:ADDON_LOADED(loadedAddonName)
	if loadedAddonName ~= AddonName then
		return
	end

	self:WrapElvUIFunctions()

	if type(_G.ElvUI_CPUSaved) ~= "table" then
		_G.ElvUI_CPUSaved = { }
	end

	if type(_G.ElvUI_CPUSaved.footerMetrics) ~= "table" then
		_G.ElvUI_CPUSaved.footerMetrics = self:GetFooterSettings()
	else
		self.footerMetrics = _G.ElvUI_CPUSaved.footerMetrics
	end

	self.showMicroseconds = _G.ElvUI_CPUSaved.showMicroseconds and true or false
	local microsecondsCheck = self.frame and self.frame.Toolbar and self.frame.Toolbar.MicrosecondsCheck
	if microsecondsCheck then
		microsecondsCheck:SetChecked(self.showMicroseconds)
	end

	self:SyncFooterDialog()
	self.refreshTimer:SetScript("OnUpdate", function(timer, elapsedSeconds)
		CPU:OnRefreshTimer(elapsedSeconds)
	end)
	self:UpdateFooter()
	self:Print("Addon loaded into the memory.")
end

function CPU:ToggleFrame()
	if not self.frame then
		return
	end

	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self.frame:Show()
	end
end

function CPU:GetAddonObjectName(addonObject)
	if type(addonObject) ~= "table" then
		return nil
	end

	if type(addonObject.GetName) == "function" then
		local addonObjectName = addonObject:GetName()
		if type(addonObjectName) == "string" and addonObjectName ~= "" then
			return addonObjectName
		end
	end

	if type(addonObject.moduleName) == "string" and addonObject.moduleName ~= "" then
		return addonObject.moduleName
	end

	if type(addonObject.name) == "string" and addonObject.name ~= "" then
		return addonObject.name
	end
end

function CPU:RegisterPlugin(plugin)
	local pluginName
	local pluginTable
	if type(plugin) == "string" then
		pluginName = plugin
	elseif type(plugin) == "table" then
		pluginTable = plugin
		pluginName = self:GetAddonObjectName(plugin)
	else
		return
	end

	if type(pluginName) ~= "string" or pluginName == "" then
		return
	end

	if not self.plugins then
		self.plugins = { }
	end

	self.plugins[pluginName] = true
	self:WrapPlugin(pluginName, pluginTable)
	self:PublishDirtyRecords()
end

function CPU:RegisterPluginModule(pluginName, moduleName, moduleTable)
	self:RegisterPlugin(pluginName)
	if not self:IsProfilerEnabled() or type(moduleName) ~= "string" then
		return
	end

	self:WrapOwnerFunctions("("..pluginName..") "..moduleName..":", moduleTable, false)
	self:PublishDirtyRecords()
end

function CPU:ResolvePluginOwner(pluginName, pluginTable)
	if type(pluginTable) == "table" then
		return pluginTable
	end

	local moduleOwner = E:GetModule(pluginName, true)
	if type(moduleOwner) == "table" then
		return moduleOwner
	end

	local addonOwner = E.Libs.AceAddon:GetAddon(pluginName, true)
	if type(addonOwner) == "table" then
		return addonOwner
	end

	local localAddonTable = C_AddOns.GetAddOnLocalTable(pluginName)
	if type(localAddonTable) == "table" then
		return localAddonTable
	end
end

function CPU:WrapPlugin(pluginName, pluginTable)
	if not self:IsProfilerEnabled() or type(pluginName) ~= "string" then
		return
	end

	if not self.measureStartedAt then
		self.measureStartedAt = GetTime()
	end

	local addon = self:ResolvePluginOwner(pluginName, pluginTable)
	if type(addon) ~= "table" then
		return
	end

	self:WrapOwnerFunctions(pluginName..":", addon, false)

	local function WrapModuleTable(moduleTable)
		if type(moduleTable) ~= "table" then
			return
		end

		for moduleName, moduleOwner in pairs(moduleTable) do
			if type(moduleName) == "string" and type(moduleOwner) == "table" then
				self:WrapOwnerFunctions("("..pluginName..") "..moduleName..":", moduleOwner, false)
			end
		end
	end

	WrapModuleTable(addon.modules)
	if addon.Modules ~= addon.modules then
		WrapModuleTable(addon.Modules)
	end
end

function CPU:WrapRegisteredPlugins()
	local pluginLibrary = E.Libs and E.Libs.EP
	local registeredPlugins = pluginLibrary and pluginLibrary.plugins
	if type(registeredPlugins) ~= "table" then
		return
	end

	for pluginName, pluginInfo in pairs(registeredPlugins) do
		if type(pluginName) == "string" and type(pluginInfo) == "table" and not pluginInfo.isLib then
			self.plugins = self.plugins or { }
			self.plugins[pluginName] = true
			self:WrapPlugin(pluginName)
		end
	end
end

function CPU:IsProfilerEnabled()
	return C_AddOnProfiler.IsEnabled()
end

function CPU:GetProfilerTickFrequency()
	if not self.profilerTickFrequency then
		self.profilerTickFrequency = C_AddOnProfiler.GetTicksPerSecond()
	end

	return self.profilerTickFrequency
end

function CPU:GetMillisecondsPerTick()
	if not self.millisecondsPerTick then
		self.millisecondsPerTick = 1000 / self:GetProfilerTickFrequency()
	end

	return self.millisecondsPerTick
end

function CPU:FormatElapsedTicks(elapsedTicks)
	local milliseconds = elapsedTicks * self:GetMillisecondsPerTick()
	if self.showMicroseconds and milliseconds < 1 then
		return string_format("%.1f µs", milliseconds * 1000)
	end

	return string_format("%.3f ms", milliseconds)
end

function CPU:GetAverageElapsedTicks(record)
	if record.calls <= 0 then
		return 0
	end

	return record.totalTicks / record.calls
end

function CPU:RecordMeasuredCall(record, callResults)
	local elapsedMilliseconds = callResults.elapsedMilliseconds
	local elapsedTicks = callResults.elapsedTicks
	record.calls = record.calls + 1
	record.totalMilliseconds = record.totalMilliseconds + elapsedMilliseconds
	record.totalTicks = record.totalTicks + elapsedTicks
	if elapsedMilliseconds > record.peakMilliseconds then
		record.peakMilliseconds = elapsedMilliseconds
	end
	if elapsedTicks > record.peakTicks then
		record.peakTicks = elapsedTicks
	end
	record.allocatedBytes = record.allocatedBytes + callResults.allocatedBytes
	record.deallocatedBytes = record.deallocatedBytes + callResults.deallocatedBytes
end

function CPU:RememberInstalledWrapper(owner, methodName, wrappedFunction)
	local ownerWrappers = self.installedWrappers[owner]
	if not ownerWrappers then
		ownerWrappers = { }
		self.installedWrappers[owner] = ownerWrappers
	end
	ownerWrappers[methodName] = wrappedFunction
end

function CPU:GetAceHookEmbedderName(hookedFunction)
	local aceHook = LibStub("AceHook-3.0", true)
	if type(aceHook) ~= "table" or type(aceHook.registry) ~= "table" then
		return nil
	end

	for embedder, embedderHooks in pairs(aceHook.registry) do
		if type(embedderHooks) == "table" then
			for hookedObject, hookValue in pairs(embedderHooks) do
				if hookValue == hookedFunction then
					return self:GetAddonObjectName(embedder)
				end
				if type(hookedObject) == "table" and type(hookValue) == "table" then
					for methodName, methodUid in pairs(hookValue) do
						if methodUid == hookedFunction and type(methodName) == "string" then
							return self:GetAddonObjectName(embedder)
						end
					end
				end
			end
		end
	end
end

function CPU:GetReplacementDisplayName(owner, methodName, currentFunction, displayName)
	local ownerWrappers = self.installedWrappers[owner]
	local installedWrapper = ownerWrappers and ownerWrappers[methodName]
	if type(installedWrapper) ~= "function" or installedWrapper == currentFunction then
		return displayName
	end

	local embedderName = self:GetAceHookEmbedderName(currentFunction)
	if type(embedderName) ~= "string" or embedderName == "" then
		embedderName = "hook"
	end

	return "("..embedderName..") "..displayName
end

function CPU:WrapFunction(displayName, owner, methodName, elvuiCodeSearch)
	if type(owner) ~= "table" or type(methodName) ~= "string" then
		return
	end

	local originalFunction = owner[methodName]
	if type(originalFunction) ~= "function" then
		return
	end

	if self.wrappedMarkers[originalFunction] then
		self:RememberInstalledWrapper(owner, methodName, originalFunction)
		return
	end

	local record = self.originalFunctions[originalFunction]
	if record then
		owner[methodName] = record.wrappedFunction
		self.wrappedMarkers[record.wrappedFunction] = true
		self:RememberInstalledWrapper(owner, methodName, record.wrappedFunction)
		return
	end

	displayName = self:GetReplacementDisplayName(owner, methodName, originalFunction, displayName)

	record = {
		name = displayName,
		methodName = methodName,
		elvuiCodeSearch = elvuiCodeSearch and true or false,
		calls = 0,
		totalMilliseconds = 0,
		peakMilliseconds = 0,
		totalTicks = 0,
		peakTicks = 0,
		recentTicksPerSecond = 0,
		allocatedBytes = 0,
		deallocatedBytes = 0,
	}

	local wrappedFunction
	wrappedFunction = function(...)
		local callResults, packedReturns = CaptureMeasuredReturns(C_AddOnProfiler.MeasureCall(originalFunction, ...))
		if callResults.elapsedTicks > record.peakTicks then
			record.peakCallStack = debugstack(2, 25, 2)
		end
		CPU:RecordMeasuredCall(record, callResults)
		return RestorePackedReturns(packedReturns, unpack(packedReturns, 1, packedReturns.n))
	end
	record.wrappedFunction = wrappedFunction
	self.wrappedMarkers[wrappedFunction] = true
	self.originalFunctions[originalFunction] = record
	self.functionRecords[#self.functionRecords + 1] = record
	owner[methodName] = wrappedFunction
	self:RememberInstalledWrapper(owner, methodName, wrappedFunction)
	self.displayDirty = true
end

function CPU:WrapOwnerFunctions(displayPrefix, owner, elvuiCodeSearch)
	if type(owner) ~= "table" then
		return
	end

	local methodNames = { }
	for methodName, methodFunction in pairs(owner) do
		if type(methodName) == "string" and type(methodFunction) == "function" then
			methodNames[#methodNames + 1] = methodName
		end
	end

	for methodIndex = 1, #methodNames do
		local methodName = methodNames[methodIndex]
		self:WrapFunction(displayPrefix..methodName, owner, methodName, elvuiCodeSearch)
	end
end

function CPU:WrapElvUIFunctions()
	if not self:IsProfilerEnabled() then
		if not self.profilerWarningPrinted then
			self.profilerWarningPrinted = true
			self:Print("AddOn profiler is not enabled.")
		end
			return
		end

	if not self.measureStartedAt then
		self.measureStartedAt = GetTime()
	end

	self:WrapOwnerFunctions("ElvUI:", E, true)

	if type(E.modules) == "table" then
		for moduleName, moduleTable in pairs(E.modules) do
			if type(moduleName) == "string" then
				self:WrapOwnerFunctions(moduleName..":", moduleTable, true)
			end
		end
	end

	self:WrapRegisteredPlugins()
	self:PublishDirtyRecords()
end

function CPU:GetMeasuredTotalMilliseconds()
	local totalMilliseconds = 0
	for recordIndex = 1, #self.functionRecords do
		totalMilliseconds = totalMilliseconds + self.functionRecords[recordIndex].totalMilliseconds
	end

	return totalMilliseconds
end

function CPU:GetCallsPerSecond(record)
	local elapsedSeconds = GetTime() - (self.measureStartedAt or GetTime())
	if elapsedSeconds <= 0 then
		elapsedSeconds = 1
	end

	return record.calls / elapsedSeconds
end

function CPU:GetTimePerCall(record)
	if record.calls <= 0 then
		return 0
	end

	return record.totalMilliseconds / record.calls
end

function CPU:GetOverallPercent(record, measuredTotalMilliseconds)
	if not measuredTotalMilliseconds or measuredTotalMilliseconds <= 0 then
		return 0
	end

	return (record.totalMilliseconds / measuredTotalMilliseconds) * 100
end

function CPU:GetRetainedBytes(record)
	return record.allocatedBytes - record.deallocatedBytes
end

local memorySizeUnitNames = { "B", "KB", "MB", "GB" }

function CPU:FormatByteCount(byteCount)
	local numericByteCount = tonumber(byteCount) or 0
	local signPrefix = ""
	if numericByteCount < 0 then
		signPrefix = "-"
		numericByteCount = -numericByteCount
	end

	local unitIndex = 1
	local scaledByteCount = numericByteCount
	while scaledByteCount >= 1024 and unitIndex < #memorySizeUnitNames do
		scaledByteCount = scaledByteCount / 1024
		unitIndex = unitIndex + 1
	end

	if unitIndex == 1 then
		return string.format("%s%.0f %s", signPrefix, scaledByteCount, memorySizeUnitNames[unitIndex])
	end

	return string.format("%s%.2f %s", signPrefix, scaledByteCount, memorySizeUnitNames[unitIndex])
end

function CPU:GetSortValue(record, key)
	if key == "name" then
		return record.name
	elseif key == "calls" then
		return record.calls
	elseif key == "callsPerSecond" then
		return self:GetCallsPerSecond(record)
	elseif key == "peakMilliseconds" then
		return record.peakMilliseconds
	elseif key == "timePerCall" then
		return self:GetTimePerCall(record)
	elseif key == "recentTicksPerSecond" then
		return record.recentTicksPerSecond
	elseif key == "totalMilliseconds" then
		return record.totalMilliseconds
	elseif key == "allocatedBytes" then
		return record.allocatedBytes
	elseif key == "deallocatedBytes" then
		return record.deallocatedBytes
	elseif key == "retainedBytes" then
		return self:GetRetainedBytes(record)
	elseif key == "overallPercent" then
		return self:GetOverallPercent(record, self.cachedMeasuredTotalMilliseconds or self:GetMeasuredTotalMilliseconds())
	end

	return 0
end

function CPU:CompareRecords(leftRecord, rightRecord)
	local definition = self.columnDefinitions[self.sortColumnIndex]
	local leftValue = self:GetSortValue(leftRecord, definition.key)
	local rightValue = self:GetSortValue(rightRecord, definition.key)
	if leftValue == rightValue then
		return false
	end

	if self.sortDescending then
		return leftValue > rightValue
	end

	return leftValue < rightValue
end

function CPU:ToggleSort(columnIndex)
	if self.sortColumnIndex == columnIndex then
		self.sortDescending = not self.sortDescending
	else
		self.sortColumnIndex = columnIndex
		self.sortDescending = false
	end

	if self.displayProvider then
		self.cachedMeasuredTotalMilliseconds = self:GetMeasuredTotalMilliseconds()
		self.displayProvider:SetSortComparator(function(leftRecord, rightRecord)
			return CPU:CompareRecords(leftRecord, rightRecord)
		end)
	end

	self:UpdateSortArrows()
end

function CPU:RecordMatchesSearch(record)
	local searchText = self.searchText
	if not searchText or searchText == "" then
		return true
	end

	return string_find(record.name, searchText, 1, true) ~= nil
end

function CPU:RebuildDisplay()
	if not self.displayProvider then
		return
	end

	local matches = { }
	for recordIndex = 1, #self.functionRecords do
		local record = self.functionRecords[recordIndex]
		if self:RecordMatchesSearch(record) then
			matches[#matches + 1] = record
		end
	end

	self.cachedMeasuredTotalMilliseconds = self:GetMeasuredTotalMilliseconds()
	self.displayProvider:Flush()
	self.displayProvider:InsertTable(matches)
	self:UpdateFooter()
end

function CPU:PublishDirtyRecords()
	if not self.displayDirty or not self.displayProvider then
		return
	end

	self.displayDirty = false
	self:RebuildDisplay()
end

function CPU:ResetMeasuredFunctions()
	for recordIndex = 1, #self.functionRecords do
		local record = self.functionRecords[recordIndex]
		record.calls = 0
		record.totalMilliseconds = 0
		record.peakMilliseconds = 0
		record.totalTicks = 0
		record.peakTicks = 0
		record.sampleTicks = nil
		record.recentTicksPerSecond = 0
		record.peakCallStack = nil
		record.allocatedBytes = 0
		record.deallocatedBytes = 0
	end

	self.measureStartedAt = GetTime()
end

function CPU:GetFooterSettings()
	if self.footerMetrics then
		return self.footerMetrics
	end

	local footerMetrics = { }
	for metricKey, enabled in pairs(self.defaultFooterMetrics) do
		footerMetrics[metricKey] = enabled
	end

	self.footerMetrics = footerMetrics
	return footerMetrics
end

function CPU:SyncFooterDialog()
	local dialog = self.footerDialog
	if not dialog or not dialog.footerCheckboxes then
		return
	end

	local settings = self:GetFooterSettings()
	for checkboxIndex = 1, #dialog.footerCheckboxes do
		local checkbox = dialog.footerCheckboxes[checkboxIndex]
		checkbox:SetChecked(settings[checkbox.footerMetricKey] and true or false)
	end
end

function CPU:FormatFooterMetric(definition, functionCount)
	if definition.key == "functionCount" then
		return string_format("%d functions", functionCount)
	end

	if not self:IsProfilerEnabled() then
		return definition.footerLabel..": --"
	end

	local metricValue = C_AddOnProfiler.GetAddOnMetric("ElvUI", definition.metric)
	if definition.format == "count" then
		return string_format("%s %d", definition.footerLabel, metricValue)
	end

	return string_format("%s %0.3f ms", definition.footerLabel, metricValue)
end

function CPU:UpdateFooter()
	if not self.frame or not self.displayProvider or not self.frame.FooterButton then
		return
	end

	local settings = self:GetFooterSettings()
	local functionCount = #self.displayProvider:GetCollection()
	local footerParts = { }
	for definitionIndex = 1, #self.footerMetricDefinitions do
		local definition = self.footerMetricDefinitions[definitionIndex]
		if settings[definition.key] then
			footerParts[#footerParts + 1] = self:FormatFooterMetric(definition, functionCount)
		end
	end

	local footerText = footerParts[1] or "Click to choose footer stats"
	for partIndex = 2, #footerParts do
		footerText = footerText.." · "..footerParts[partIndex]
	end

	self.frame.FooterButton.Text:SetText(footerText)
end

function CPU:CreateFooterDialog()
	local dialog = self.footerDialog or (self.frame and self.frame.FooterDialog)
	if not dialog or dialog.footerCheckboxes then
		self.footerDialog = dialog
		return dialog
	end

	local skinModule = E:GetModule("Skins")
	dialog.footerCheckboxes = { }
	dialog:SetTemplate("Transparent")
	dialog:CreateCloseButton()

	local settings = self:GetFooterSettings()
	for definitionIndex = 1, #self.footerMetricDefinitions do
		local definition = self.footerMetricDefinitions[definitionIndex]
		local checkbox = dialog[definition.key]
		checkbox.footerMetricKey = definition.key
		checkbox.Text:SetText(definition.label)
		checkbox:SetChecked(settings[definition.key] and true or false)
		checkbox:SetScript("OnClick", function(checkButton)
			local footerSettings = CPU:GetFooterSettings()
			footerSettings[checkButton.footerMetricKey] = checkButton:GetChecked() and true or false
			CPU:UpdateFooter()
		end)
		dialog.footerCheckboxes[#dialog.footerCheckboxes + 1] = checkbox
		skinModule:HandleCheckBox(checkbox)
	end

	self.frame:HookScript("OnHide", function()
		dialog:Hide()
	end)

	self.footerDialog = dialog
	return dialog
end

function CPU:ToggleFooterDialog()
	local dialog = self:CreateFooterDialog()
	dialog:SetShown(not dialog:IsShown())
end

function CPU:RefreshVisibleRows()
	if not self.frame or not self.frame.ScrollBox then
		return
	end

	self.cachedMeasuredTotalMilliseconds = self:GetMeasuredTotalMilliseconds()
	self.frame.ScrollBox:ForEachFrame(function(row)
		row:Refresh()
	end)
end

function CPU:GetColumnContentWidth()
	local contentWidth = 2
	for columnIndex = 1, #self.columnDefinitions do
		contentWidth = contentWidth + self.columnDefinitions[columnIndex].width
		if columnIndex > 1 then
			contentWidth = contentWidth - 2
		end
	end

	return contentWidth
end

function CPU:PositionColumnHeaders()
	local offset = self.horizontalOffset or 0
	local previousHeader = nil
	for columnIndex = 1, #self.columnHeaders do
		local header = self.columnHeaders[columnIndex]
		local definition = self.columnDefinitions[columnIndex]
		header:SetWidth(definition.width)
		header:ClearAllPoints()
		if columnIndex == 1 then
			header:SetPoint("BOTTOMLEFT", self.frame.Columns, "BOTTOMLEFT", 2 - offset, 1)
		else
			header:SetPoint("BOTTOMLEFT", previousHeader, "BOTTOMRIGHT", -2, 0)
		end
		previousHeader = header
	end
end

ElvUICpuColumnGripMixin = { }

function ElvUICpuColumnGripMixin:OnEnter()
	if SetCursor then
		SetCursor("UI_RESIZE_CURSOR")
	end
end

function ElvUICpuColumnGripMixin:OnLeave()
	if SetCursor and not CPU.columnDragging then
		SetCursor(nil)
	end
end

function ElvUICpuColumnGripMixin:OnMouseDown(buttonName)
	if buttonName ~= "LeftButton" then
		return
	end
	CPU:StartColumnDrag(self.columnIndex)
end

function CPU:ConfigureColumnHeader(header, columnIndex)
	header.tooltipText = self.columnDefinitions[columnIndex].tooltip
	if not header.Grip then
		header:HookScript("OnEnter", function(headerButton)
			if not headerButton.tooltipText then
				return
			end
			GameTooltip:SetOwner(headerButton, "ANCHOR_RIGHT")
			GameTooltip_SetTitle(GameTooltip, headerButton.tooltipText)
			GameTooltip:Show()
		end)
		header:HookScript("OnLeave", GameTooltip_Hide)

		local grip = CreateFrame("Button", nil, header, "ElvUICpuColumnGripTemplate")
		grip:SetFrameLevel(header:GetFrameLevel() + 5)
		header.Grip = grip
	end

	header.Grip.columnIndex = columnIndex

	if not header.SortArrow then
		local sortArrow = header:CreateTexture(nil, "OVERLAY")
		sortArrow:SetAtlas("auctionhouse-ui-sortarrow", true)
		sortArrow:SetPoint("LEFT", header:GetFontString(), "RIGHT", 3, 0)
		header.SortArrow = sortArrow
	end
end

function CPU:UpdateSortArrows()
	for columnIndex = 1, #self.columnHeaders do
		local header = self.columnHeaders[columnIndex]
		local sortArrow = header and header.SortArrow
		if sortArrow then
			local columnSelected = columnIndex == self.sortColumnIndex
			sortArrow:SetShown(columnSelected)
			if columnSelected then
				if self.sortDescending then
					sortArrow:SetTexCoord(0, 1, 0, 1)
				else
					sortArrow:SetTexCoord(0, 1, 1, 0)
				end
			end
		end
	end
end

function CPU:LayoutColumnHeaders()
	local columnInfo = { }
	for columnIndex, definition in ipairs(self.columnDefinitions) do
		columnInfo[columnIndex] = {
			title = definition.title,
			width = definition.width,
		}
	end

	self.frame.Columns:LayoutColumns(columnInfo)
	self.columnHeaders = { }
	local children = { self.frame.Columns:GetChildren() }
	for childIndex = 1, #children do
		local child = children[childIndex]
		if child:GetObjectType() == "Button" and child:GetID() > 0 then
			local columnIndex = child:GetID()
			self.columnHeaders[columnIndex] = child
			self:ConfigureColumnHeader(child, columnIndex)
			end
		end

	self:PositionColumnHeaders()
	self:UpdateSortArrows()
end

function CPU:ApplyHorizontalOffset(scrollPercentage)
	if not self.frame or not self.frame.ScrollBox then
		return
	end

	local contentWidth = self:GetColumnContentWidth()
	local viewWidth = self.frame.ScrollBox:GetWidth()
	local overflow = contentWidth - viewWidth
	if overflow < 0 then
		overflow = 0
	end

	self.horizontalOffset = (scrollPercentage or 0) * overflow
	self:PositionColumnHeaders()
	self.frame.ScrollBox:ForEachFrame(function(row)
		row:LayoutCells()
	end)
end

function CPU:OnHorizontalScroll(scrollPercentage)
	self:ApplyHorizontalOffset(scrollPercentage)
end

function CPU:AnchorScrollBox(showBar)
	local scrollBox = self.frame.ScrollBox
	local footerButton = self.frame.FooterButton
	local horizontalBar = self.frame.HorizontalScrollBar

	scrollBox:ClearAllPoints()
	scrollBox:SetPoint("TOPLEFT", self.frame.Columns, "BOTTOMLEFT", 0, -2)
	if showBar and horizontalBar then
		scrollBox:SetPoint("BOTTOMRIGHT", horizontalBar, "TOPRIGHT", 0, 4)
	else
		scrollBox:SetPoint("BOTTOMRIGHT", footerButton, "TOPRIGHT", 103, 8)
	end
end

function CPU:UpdateHorizontalExtent()
	if not self.frame or not self.frame.ScrollBox or self.updatingHorizontalExtent then
		return
	end

	self.updatingHorizontalExtent = true

	local contentWidth = self:GetColumnContentWidth()
	local viewWidth = self.frame.ScrollBox:GetWidth()
	if viewWidth < 1 then
		self.updatingHorizontalExtent = false
		return
	end

	local overflow = contentWidth - viewWidth
	local showBar = overflow > 1
	local horizontalBar = self.frame.HorizontalScrollBar
	if showBar ~= self.horizontalBarShown then
		self.horizontalBarShown = showBar
		horizontalBar:SetShown(showBar)
		self:AnchorScrollBox(showBar)
		viewWidth = self.frame.ScrollBox:GetWidth()
		overflow = contentWidth - viewWidth
	end

	if showBar and contentWidth > 0 then
		horizontalBar:SetVisibleExtentPercentage(viewWidth / contentWidth)
		self:ApplyHorizontalOffset(horizontalBar:GetScrollPercentage())
	else
		self:ApplyHorizontalOffset(0)
	end

	self.updatingHorizontalExtent = false
end

function CPU:StartColumnDrag(columnIndex)
	local definition = self.columnDefinitions[columnIndex]
	if not definition then
		return
	end

	local frameScale = self.frame:GetEffectiveScale()
	self.columnDragging = true
	self.dragColumnIndex = columnIndex
	self.dragStartWidth = definition.width
	self.dragStartCursorX = GetCursorPosition() / frameScale
	self.frame:SetScript("OnUpdate", function()
		CPU:UpdateColumnDrag()
	end)
end

function CPU:UpdateColumnDrag()
	if not self.columnDragging then
		return
	end

	if not IsMouseButtonDown("LeftButton") then
		self:StopColumnDrag()
		return
	end

	local frameScale = self.frame:GetEffectiveScale()
	local cursorX = GetCursorPosition() / frameScale
	local definition = self.columnDefinitions[self.dragColumnIndex]
	local newWidth = self.dragStartWidth + (cursorX - self.dragStartCursorX)
	if newWidth < definition.minimumWidth then
		newWidth = definition.minimumWidth
	end
	if newWidth == definition.width then
		return
	end

	definition.width = newWidth
	self:UpdateHorizontalExtent()
end

function CPU:StopColumnDrag()
	self.columnDragging = false
	if self.frame then
		self.frame:SetScript("OnUpdate", nil)
	end
	if SetCursor then
		SetCursor(nil)
				end
			end

function CPU:SampleRecentCost(intervalSeconds)
	if not intervalSeconds or intervalSeconds <= 0 then
		intervalSeconds = 1
	end

	for recordIndex = 1, #self.functionRecords do
		local record = self.functionRecords[recordIndex]
		if record.sampleTicks then
			record.recentTicksPerSecond = (record.totalTicks - record.sampleTicks) / intervalSeconds
		else
			record.recentTicksPerSecond = 0
		end
		record.sampleTicks = record.totalTicks
	end
end

function CPU:OnRefreshTimer(elapsedSeconds)
	self.refreshElapsed = (self.refreshElapsed or 0) + elapsedSeconds
	if self.refreshElapsed < 1 then
		return
	end

	local intervalSeconds = self.refreshElapsed
	self.refreshElapsed = 0
	self:WrapElvUIFunctions()
	self:SampleRecentCost(intervalSeconds)

	if not self.refreshRunning or not self.frame or not self.frame:IsShown() then
		return
	end

	if self.frame.ResizeButton.isActive or self.columnDragging then
		return
	end

	if self.displayProvider then
		self.cachedMeasuredTotalMilliseconds = self:GetMeasuredTotalMilliseconds()
		self.displayProvider:Sort()
	end
	self:RefreshVisibleRows()
	self:UpdateFooter()
end

CPU.refreshTimer = CreateFrame("Frame")

function CPU:GetSearchMethodName(record)
	if type(record.methodName) == "string" and record.methodName ~= "" then
		return record.methodName
	end

	local displayName = record.name
	if type(displayName) ~= "string" or displayName == "" then
		return ""
	end

	local colonIndex = string_find(displayName, ":[^:]*$")
	if not colonIndex then
		return displayName
	end

	return string_sub(displayName, colonIndex + 1)
end

function CPU:EncodeSearchTerm(text)
	return (string_gsub(text, "([^%w_%-%.])", function(character)
		return string_format("%%%02X", string_byte(character))
	end))
end

function CPU:GetElvUICodeSearchURL(methodName)
	return string_format("https://github.com/search?q=repo%%3Atukui-org%%2FElvUI+%s&type=code", self:EncodeSearchTerm(methodName))
end

StaticPopupDialogs["ELVUI_CPU_GITHUB_SEARCH"] = {
	text = "Press Ctrl+C to copy the ElvUI search URL.",
	button1 = OKAY,
	hasEditBox = 1,
	editBoxWidth = 350,
	maxLetters = 512,
	OnShow = function(dialog, data)
		local editBox = dialog:GetEditBox()
		editBox:SetText(data)
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	EditBoxOnEnterPressed = function(editBox)
		editBox:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = StaticPopup_StandardEditBoxOnEscapePressed,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local peakCallStackBorderNames = {
	"TopLeftTex",
	"TopRightTex",
	"TopTex",
	"BottomLeftTex",
	"BottomRightTex",
	"BottomTex",
	"LeftTex",
	"RightTex",
	"MiddleTex",
}

ElvUICpuPeakCallStackMixin = { }

function ElvUICpuPeakCallStackMixin:OnLoad()
	self:SetResizeBounds(640, 320, 1400, 900)
	self:RegisterForDrag("LeftButton")
	self:SetTemplate("Transparent")
	self:CreateCloseButton()

	local scrollFrame = self.ScrollFrame
	scrollFrame.CharCount:Hide()
	for borderIndex = 1, #peakCallStackBorderNames do
		local borderRegion = scrollFrame[peakCallStackBorderNames[borderIndex]]
		if borderRegion then
			borderRegion:Hide()
		end
	end
	scrollFrame:CreateBackdrop("Transparent")

	local editBox = scrollFrame.EditBox
	editBox:SetMaxLetters(0)
	editBox:ClearAllPoints()
	editBox:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT")
	editBox:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -18, 0)
	editBox:SetScript("OnEscapePressed", function(pressedEditBox)
		pressedEditBox:ClearFocus()
		self:Hide()
	end)

	self.ResizeButton:Init(self, 640, 320, 1400, 900)

	local skinModule = E:GetModule("Skins")
	skinModule:HandleTrimScrollBar(scrollFrame.ScrollBar)

	if UISpecialFrames then
		UISpecialFrames[#UISpecialFrames + 1] = "ElvUI_CPUPeakCallStackDialog"
	end

	CPU.peakCallStackDialog = self
end

function ElvUICpuPeakCallStackMixin:OnDragStart()
	self:StartMoving()
end

function ElvUICpuPeakCallStackMixin:OnDragStop()
	self:StopMovingOrSizing()
end

function ElvUICpuPeakCallStackMixin:OnSizeChanged()
	local scrollFrame = self.ScrollFrame
	local editBox = scrollFrame and scrollFrame.EditBox
	if not editBox then
		return
	end
	ScrollingEdit_OnTextChanged(editBox, scrollFrame)
end

function CPU:CreatePeakCallStackDialog()
	local dialog = self.peakCallStackDialog or ElvUI_CPUPeakCallStackDialog
	self.peakCallStackDialog = dialog
	return dialog
end

function CPU:FormatPeakCallStack(stackText)
	local formattedLines = { }
	local heldCallBoundary = false
	for stackLine in string.gmatch(stackText, "[^\n]+") do
		if string_find(stackLine, "in function 'MeasureCall'", 1, true) then
			heldCallBoundary = false
		elseif stackLine == "[C]: ?" then
			if heldCallBoundary then
				formattedLines[#formattedLines + 1] = stackLine
			end
			heldCallBoundary = true
		else
			if heldCallBoundary then
				formattedLines[#formattedLines + 1] = "[C]: ?"
				heldCallBoundary = false
			end
			if string_find(stackLine, "ElvUI_CPU/ElvUI_CPU.lua", 1, true) then
				local wrapperName = string.match(stackLine, "in function '(.-)'")
				if wrapperName then
					formattedLines[#formattedLines + 1] = wrapperName
				end
			else
				formattedLines[#formattedLines + 1] = stackLine
			end
		end
	end
	if heldCallBoundary then
		formattedLines[#formattedLines + 1] = "[C]: ?"
	end
	local formattedCallStack = table.concat(formattedLines, "\n")
	if formattedCallStack == "" then
		return stackText
	end
	return formattedCallStack
end

function CPU:GetPeakCallStackText(record)
	return string_format("%s\n\n%s", self:FormatElapsedTicks(record.peakTicks), self:FormatPeakCallStack(record.peakCallStack))
end

function CPU:ShowCallStackDialog(titleText, stackText)
	local dialog = self:CreatePeakCallStackDialog()
	dialog.Title:SetText(titleText)
	local editBox = dialog.ScrollFrame.EditBox
	editBox:SetText(stackText)
	editBox:HighlightText()
	editBox:SetFocus()
	dialog:Show()
end

function CPU:ShowPeakCallStack(record)
	self:ShowCallStackDialog("Slowest call stack", self:GetPeakCallStackText(record))
end

function CPU:ShowFunctionMenu(row, record)
	local methodName = self:GetSearchMethodName(record)
	MenuUtil.CreateContextMenu(row, function(owner, rootDescription)
		if methodName ~= "" then
			rootDescription:CreateTitle(methodName)
		else
			rootDescription:CreateTitle(record.name)
		end
		if record.elvuiCodeSearch and methodName ~= "" then
			rootDescription:CreateButton("Copy GitHub search URL", function()
				StaticPopup_Show("ELVUI_CPU_GITHUB_SEARCH", nil, nil, CPU:GetElvUICodeSearchURL(methodName))
			end)
		end
		if record.peakCallStack then
			rootDescription:CreateButton("Slowest call stack", function()
				CPU:ShowPeakCallStack(record)
			end)
		end
	end)
end

ElvUICpuRowMixin = { }

function ElvUICpuRowMixin:OnLoad()
	self.cells = { }
	for columnIndex = 1, #CPU.columnDefinitions do
		self.cells[columnIndex] = self["Cell"..columnIndex]
	end
end

function ElvUICpuRowMixin:OnMouseUp(button)
	if button ~= "RightButton" or not self.record then
		return
	end
	CPU:ShowFunctionMenu(self, self.record)
end

function ElvUICpuRowMixin:LayoutCells()
	local offset = CPU.horizontalOffset or 0
	local cellX = 2 - offset
	for columnIndex, cell in ipairs(self.cells) do
		local definition = CPU.columnDefinitions[columnIndex]
		cell:ClearAllPoints()
		cell:SetPoint("LEFT", self, "LEFT", cellX, 0)
		cell:SetSize(definition.width - 2, 20)
		cell.Text:SetJustifyH(definition.justify)
		cellX = cellX + definition.width - 2
	end
end

function ElvUICpuRowMixin:Init(record)
	self.record = record
	self:LayoutCells()
	self:Refresh()
end

function ElvUICpuRowMixin:Refresh()
	local record = self.record
	if not record then
		return
	end

	local measuredTotalMilliseconds = CPU.cachedMeasuredTotalMilliseconds
	if not measuredTotalMilliseconds then
		measuredTotalMilliseconds = CPU:GetMeasuredTotalMilliseconds()
	end

	self.cells[1].Text:SetText(record.name)
	self.cells[2].Text:SetText(record.calls)
	self.cells[3].Text:SetFormattedText("%.3f", CPU:GetCallsPerSecond(record))
	self.cells[4].Text:SetText(CPU:FormatElapsedTicks(record.peakTicks))
	self.cells[5].Text:SetText(CPU:FormatElapsedTicks(CPU:GetAverageElapsedTicks(record)))
	self.cells[6].Text:SetText(CPU:FormatElapsedTicks(record.recentTicksPerSecond))
	self.cells[7].Text:SetText(CPU:FormatElapsedTicks(record.totalTicks))
	self.cells[8].Text:SetText(CPU:FormatByteCount(record.allocatedBytes))
	self.cells[9].Text:SetText(CPU:FormatByteCount(record.deallocatedBytes))
	self.cells[10].Text:SetText(CPU:FormatByteCount(CPU:GetRetainedBytes(record)))
	self.cells[11].Text:SetFormattedText("%.2f%%", CPU:GetOverallPercent(record, measuredTotalMilliseconds))
end

function CPU:SetSkinnedArrowDirection(button, rotation)
	if not button or not rotation then
		return
	end

	local normalTexture = button:GetNormalTexture()
	local pushedTexture = button:GetPushedTexture()
	local disabledTexture = button:GetDisabledTexture()
	if normalTexture then
		normalTexture:SetRotation(rotation)
	end
	if pushedTexture then
		pushedTexture:SetRotation(rotation)
	end
	if disabledTexture then
		disabledTexture:SetRotation(rotation)
	end
end

function CPU:SetupMicrosecondsCheck(microsecondsCheck)
	local skinModule = E:GetModule("Skins")
	microsecondsCheck.Text:SetText("Microseconds")
	microsecondsCheck.tooltipText = "Values under 1 ms show as µs. Off keeps every time in milliseconds."
	microsecondsCheck:SetChecked(self.showMicroseconds and true or false)
	microsecondsCheck:SetScript("OnClick", function(checkButton)
		CPU.showMicroseconds = checkButton:GetChecked() and true or false
		if type(_G.ElvUI_CPUSaved) ~= "table" then
			_G.ElvUI_CPUSaved = { }
		end
		_G.ElvUI_CPUSaved.showMicroseconds = CPU.showMicroseconds
		CPU:RefreshVisibleRows()
	end)
	microsecondsCheck:HookScript("OnEnter", function(checkButton)
		GameTooltip:SetOwner(checkButton, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, checkButton.tooltipText)
		GameTooltip:Show()
	end)
	microsecondsCheck:HookScript("OnLeave", GameTooltip_Hide)
	skinModule:HandleCheckBox(microsecondsCheck)
end

function CPU:SkinToolbarButton(button)
	button:HookScript("OnEnter", function(toolbarButton)
		if toolbarButton.MouseoverOverlay then
			toolbarButton.MouseoverOverlay:Show()
		end
		if not toolbarButton.tooltipText then
			return
		end
		GameTooltip:SetOwner(toolbarButton, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, toolbarButton.tooltipText)
		GameTooltip:Show()
	end)
	button:HookScript("OnLeave", function(toolbarButton)
		if toolbarButton.MouseoverOverlay then
			toolbarButton.MouseoverOverlay:Hide()
		end
		GameTooltip_Hide()
	end)
end

function CPU:ApplyElvUISkin()
	local skinModule = E:GetModule("Skins")
	local frame = self.frame

	if frame.NineSlice then
		frame.NineSlice:Hide()
	end
	if frame.PortraitContainer then
		frame.PortraitContainer:Hide()
	end

	skinModule:HandlePortraitFrame(frame)

	self:SkinToolbarButton(frame.Toolbar.PlayButton)
	self:SkinToolbarButton(frame.Toolbar.RefreshButton)
	self:SkinToolbarButton(frame.Toolbar.ResetButton)
	self:SetupMicrosecondsCheck(frame.Toolbar.MicrosecondsCheck)
	self:CreateFooterDialog()
	skinModule:HandleEditBox(frame.Toolbar.SearchBox)

	frame.ScrollBox:DisableDrawLayer("BACKGROUND")
	frame.ScrollBox:CreateBackdrop("Transparent")

	skinModule:HandleTrimScrollBar(frame.ScrollBar)
	skinModule:HandleTrimScrollBar(frame.HorizontalScrollBar)
	self:SetSkinnedArrowDirection(frame.HorizontalScrollBar.Back, skinModule.ArrowRotation.left)
	self:SetSkinnedArrowDirection(frame.HorizontalScrollBar.Forward, skinModule.ArrowRotation.right)

	frame.Columns:StripTextures()
	local headerCount = #self.columnHeaders
	for columnIndex = 1, headerCount do
		local header = self.columnHeaders[columnIndex]
		if not header.IsSkinned then
			header:DisableDrawLayer("BACKGROUND")
			header:CreateBackdrop("Transparent")
			header.IsSkinned = true
		end

		local rightInset = 0
		if columnIndex < headerCount then
			rightInset = -5
		end
		header.backdrop:Point("BOTTOMRIGHT", rightInset, -2)
	end
end

ElvUICpuPanelMixin = { }

function ElvUICpuPanelMixin:OnLoad()
	ButtonFrameTemplate_HidePortrait(self)
	self:SetTitle("|cff1784d1ElvUI|r |cfffe7b2cCPU Analyzer|r")
	self.TitleBar:Init(self)
	self:SetScript("OnSizeChanged", function()
		CPU:UpdateHorizontalExtent()
	end)
	self.ResizeButton:Init(self, 640, 280, 1400, 900)
	self:SetResizeBounds(640, 280, 1400, 900)
	self:SetClampedToScreen(true)

	if UISpecialFrames then
		UISpecialFrames[#UISpecialFrames + 1] = "ElvUI_CPUFrame"
	end

	CPU.frame = self
	CPU.displayProvider = CreateDataProvider()
	CPU.displayProvider:SetSortComparator(function(leftRecord, rightRecord)
		return CPU:CompareRecords(leftRecord, rightRecord)
	end, true)

	local view = CreateScrollBoxListLinearView()
	view:SetElementInitializer("ElvUICpuRowTemplate", function(row, record)
		row:Init(record)
	end)
	view:SetElementExtent(20)
	self.ScrollBox:SetClipsChildren(true)
	ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)
	ScrollUtil.RegisterAlternateRowBehavior(self.ScrollBox, function(row, alternate)
		row.Alternate:SetShown(alternate)
	end)
	CPU:AnchorScrollBox(false)
	self.ScrollBox:SetDataProvider(CPU.displayProvider)

	self.Columns.sortingFunction = function(columnDisplay, columnIndex)
		CPU:ToggleSort(columnIndex)
	end
	self.Columns:SetClipsChildren(true)
	CPU:LayoutColumnHeaders()

	self.HorizontalScrollBar:RegisterCallback(ScrollBarMixin.Event.OnScroll, CPU.OnHorizontalScroll, CPU)

	local searchBox = self.Toolbar.SearchBox
	searchBox.Instructions:SetText("Function name")
	searchBox:HookScript("OnTextChanged", function(editBox)
		CPU.searchText = editBox:GetText() or ""
		CPU:RebuildDisplay()
	end)
	searchBox:HookScript("OnEnter", function(editBox)
		if not editBox.tooltipText then
					return
				end
		GameTooltip:SetOwner(editBox, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, editBox.tooltipText)
		GameTooltip:Show()
	end)
	searchBox:HookScript("OnLeave", GameTooltip_Hide)

	self.Toolbar.PlayButton:SetScript("OnClick", function(playButton)
		CPU.refreshRunning = not CPU.refreshRunning
		if CPU.refreshRunning then
			playButton:SetText("Pause")
		else
			playButton:SetText("Play")
		end
	end)
	self.Toolbar.RefreshButton:SetScript("OnClick", function()
		CPU:WrapElvUIFunctions()
		CPU:RefreshVisibleRows()
		CPU:UpdateFooter()
	end)
	self.Toolbar.ResetButton:SetScript("OnClick", function()
		CPU:ResetMeasuredFunctions()
		CPU:RefreshVisibleRows()
		CPU:UpdateFooter()
	end)

	self.FooterButton:SetFrameLevel(self:GetFrameLevel() + 20)
	self.FooterButton:SetScript("OnClick", function()
		CPU:ToggleFooterDialog()
	end)
	self.FooterButton:HookScript("OnEnter", function(footerButton)
		GameTooltip:SetOwner(footerButton, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, "Choose footer stats")
		GameTooltip:Show()
	end)
	self.FooterButton:HookScript("OnLeave", GameTooltip_Hide)

	self.Version:SetText(C_AddOns.GetAddOnMetadata("ElvUI", "Version"))
	CPU:ApplyElvUISkin()
	CPU:PublishDirtyRecords()
	CPU:UpdateHorizontalExtent()
end

function ElvUICpuPanelMixin:OnShow()
	CPU:WrapElvUIFunctions()
	CPU:UpdateHorizontalExtent()
	CPU:RefreshVisibleRows()
	CPU:UpdateFooter()
end

local function ToggleCPUFrame()
    CPU:ToggleFrame()
end

SLASH_ELVUCPU1 = "/elvucpu"
SLASH_ELVUCPU2 = "/cpu"
SLASH_ELVUCPU3 = "/ecpu"

SlashCmdList["ELVUCPU"] = ToggleCPUFrame

CPU:WrapElvUIFunctions()
