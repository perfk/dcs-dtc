local tcpServer = nil
local udpSpeaker = nil
package.path  = package.path..";"..lfs.currentdir().."/LuaSocket/?.lua"
package.cpath = package.cpath..";"..lfs.currentdir().."/LuaSocket/?.dll"
package.path  = package.path..";"..lfs.currentdir().."/Scripts/?.lua"
local socket = require("socket")

local JSON = loadfile("Scripts\\JSON.lua")()

local needDelay = false
local keypressinprogress = false
local data
local delay = 0
local delayNeeded = 0
local delayStart = 0
local code = ""
local device = ""
local nextIndex = 1

local skipCondition
local skip = false

local tcpPort = 43001
local udpPort = 43000

local upstreamLuaExportStart = LuaExportStart
local upstreamLuaExportAfterNextFrame = LuaExportAfterNextFrame
local upstreamLuaExportBeforeNextFrame = LuaExportBeforeNextFrame

local function parse_indication(indicator_id)  -- Thanks to [FSF]Ian code
	local t = {}
	local li = list_indication(indicator_id)
	local m = li:gmatch("-----------------------------------------\n([^\n]+)\n([^\n]*)\n")
	while true do
    	local name, value = m()
    	if not name then 
			break 
		elseif string.find(name, "_1__id:31") then
			name = "140_1__id:31" -- mitigate lua gsub not liking the degree symbol
		end
   		t[name]=value
	end
	return t
end

local function serializeTable(val, name, skipnewlines, depth)
    skipnewlines = skipnewlines or false
    depth = depth or 0

    local tmp = string.rep(" ", depth)

    if name then tmp = tmp .. name .. " = " end

    if type(val) == "table" then
        tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")

        for k, v in pairs(val) do
            tmp =  tmp .. serializeTable(v, k, skipnewlines, depth + 1) .. "," .. (not skipnewlines and "\n" or "")
        end

        tmp = tmp .. string.rep(" ", depth) .. "}"
    elseif type(val) == "number" then
        tmp = tmp .. tostring(val)
    elseif type(val) == "string" then
        tmp = tmp .. string.format("%q", val)
    elseif type(val) == "boolean" then
        tmp = tmp .. (val and "true" or "false")
    else
        tmp = tmp .. "\"[inserializeable datatype:" .. type(val) .. "]\""
    end

    return tmp
end

function LuaExportStart()
    if upstreamLuaExportStart ~= nil then
        successful, err = pcall(upstreamLuaExportStart)
        if not successful then
            log.write("DCS-DTC", log.ERROR, "Error in upstream LuaExportStart function"..tostring(err))
        end
    end
    
	udpSpeaker = socket.udp()
	udpSpeaker:settimeout(0)
	tcpServer = socket.tcp()
    successful, err = tcpServer:bind("127.0.0.1", tcpPort)
    tcpServer:listen(1)
    tcpServer:settimeout(0)
	if not successful then
		log.write("DCS-DTC", log.ERROR, "Error opening tcp socket - "..tostring(err))
	else
		log.write("DCS-DTC", log.INFO, "Opened connection")
	end
end

local function checkConditionHTSAllNotSelected(mfd)
	local mfdTable;

	if mfd == "left" then
		mfdTable = parse_indication(4);
	else
		mfdTable = parse_indication(5);
	end

	local str = mfdTable["ALL Table. Root. Unic ID: _id:178. Text"];
	if str == "ALL" then
		return true
	end
	return false
end

local function checkConditionHARM()
	local table = parse_indication(6);
	local str = table["Misc Item 0 Name"];
	if str == "HARM" then
		return true
	end
	return false
end

local function checkConditionNotInAAMode()
	local table = parse_indication(6);
	local str = table["Master_mode"];
	if str == "A-A" then
		return true
	end
	return false
end

local function checkConditionNotInAGMode()
	local table = parse_indication(6);
	local str = table["Master_mode"];
	if str == "A-G" then
		return true
	end
	return false
end

local function checkConditionHTSOnDED()
	local table = parse_indication(6);
	local str = table["Misc Item E Name"];
	if str == "HTS" then
		return true
	end
	return false
end

local function checkConditionBullseyeNotSelected()
	local table = parse_indication(6);
	local str = table["BULLSEYE LABEL"];
	if str == "BULLSEYE" then
		return true
	end
	return false
end

local function checkConditionBullseyeSelected()
	local table = parse_indication(6);
	local str = table["BULLSEYE LABEL_inv"];
	if str == "BULLSEYE" then
		return true
	end
	return false
end

local function checkConditionTACANBandX()
	local table = parse_indication(6);
	local str = table["TCN BAND XY"];
	if str == "X" then
		return true
	end
	return false
end

local function checkConditionTACANBandY()
	local table = parse_indication(6);
	local str = table["TCN BAND XY"];
	if str == "Y" then
		return true
	end
	return false
end

local function checkConditionAtWp0()
	local table =parse_indication(4);
	local str = table["WYPT_Page_Number"]
	if str == "0" then
		return true
	end 
	return false
end

local function checkConditionNotAtWp0()
	local table =parse_indication(4);
	local str = table["WYPT_Page_Number"]
	if str == "0" then
		return false
	end 
	return true
end

local function checkConditionWpLTE34()
	local table = parse_indication(4);
	local str = table["WYPT_Page_Number"]
	local num = tonumber(str)
	if num and num <= 34 then
		return true
	end
	return false
end

local function checkConditionWpGTE35()
	local table = parse_indication(4);
	local str = table["WYPT_Page_Number"]
	local num = tonumber(str)
	if num and num <= 34 then
		return false
	end
	return true
end

local function checkConditionNotCMS()
	local table = parse_indication(2);
	local str = table["ARM_1__id:1"]
	if str == "ARM" then
		return false
	end
	return true
end

local function checkConditionRWROff()
	local table = parse_indication(2);
	local str = table["HUD_1__id:1"]
	if str == "H" then
		return false
	end
	return true
end

local function checkConditionEWHUD()
	local table = parse_indication(2);
	local str = table["HUD_1_box__id:2"]
	if str then
		return false
	end
	return true
end

local function checkConditionUFCIFFOff()
	local table = parse_indication(6);
	local str = table["UFC_ScratchPadString1Display"]
	if str == "X" then
		return false
	end
	return true
end

local function checkConditionUFCDLOff()
	local table = parse_indication(6);
	local str = table["UFC_ScratchPadString1Display"]
	if str == "O" then
		return false
	end
	return true
end

local function checkConditionHornetNotRadar()
	local table = parse_indication(3);
	local str = table["Radar_mode"]
	if str == "RWS" then
		return false
	end
	return true
end

local function checkConditionHornetNotAutoIFF()
	local table = parse_indication(2);
	local str = table["AUTO_1_box__id:2"]
	if str then
		return false
	end
	return true
end

local function checkConditionHornetBars(bars)
	local table = parse_indication(3);
	local str = table["1B_1__id:3"]
	if str == bars then
		return true
	end
	return false
end

local function checkConditionHornetRange(range)
	local table = parse_indication(3);
	local str = table["RadarRange_VS_scaleMax"]
	if str == range then
		return true
	end
	return false
end

local function checkConditionHornetAz(az)
	local table = parse_indication(3);
	log.write("DCS-DTC", 2, serializeTable(table))
	local str = table["140_1__id:31"] -- lua gsub doesnt like the degree symbol
	local a,i = string.find(str, "%d+")
	str = string.sub(str, a, i)
	if str == az then
		return true
	end
	return false
end

local function checkConditionHornetPRF(prf)
	local table = parse_indication(3);
	local str = table["PDI_1__id:1"]
	if str == prf then
		return true
	end
	return false
end

local function checkConditionHornetTimeout(timeout)
	local table = parse_indication(3);
	local str = table[" _1__id:7"]
	if str == timeout then
		return true
	end
	return false
end

local function checkConditionBingoIsZero()
	local table =parse_indication(5);
	local str = table["txt_BINGO"]
	if str == "0" then
		return true
	end 
	return false
end

local function checkConditionInSequence(i)
	local table =parse_indication(3);
	local str = table["WYPT_SequenceData"]
	local noSpaces = str:gsub("%s+", "")
	for token in string.gmatch(noSpaces, "[^-]+") do
		if token == i then 
			return true
		end
	end
	return false
end

local function checkConditionIsJdam(i, n)
	local table =parse_indication(2);
	local str = table["STA".. i .. "_Label_TYPE"]
	if str == "J-" .. n then 
		return true 
	end
	return false
end

local function checkConditionIsSlam(i)
	local table =parse_indication(2);
	local str = table["STA".. i .. "_Label_TYPE"]
	if str == "SLAM" then 
		return true 
	end
	return false
end

local function checkConditionIsSlamER(i)
	local table =parse_indication(2);
	local str = table["STA".. i .. "_Label_TYPE"]
	if str == "SLMR" then 
		return true 
	end
	return false
end

local function checkConditionIsJsowA(i)
	local table =parse_indication(2);
	local str = table["STA".. i .. "_Label_TYPE"]
	if str == "JSA" then 
		return true 
	end
	return false
end

local function checkConditionIsJsowC(i)
	local table =parse_indication(2);
	local str = table["STA".. i .. "_Label_TYPE"]
	if str == "JSC" then 
		return true 
	end
	return false
end

local function checkConditionHTSOnMFD(mfd)
	local mfdTable;

	if mfd == "left" then
		mfdTable = parse_indication(4);
	else
		mfdTable = parse_indication(5);
	end
	local str = table["HAD_OFF_Lable_name"];
	if str == "HAD" then
		return false
	end
	return true
end

local function checkConditionLmfdNotTac()
	local table = parse_indication(2);
	local str = table["TAC_id:23"]
	if str == "TAC" then
		return false
	end 
	return true
end

local function checkConditionRmfdNotSupt()
	local table = parse_indication(3);
	local str = table["SUPT_id:13"]
	if str == "SUPT" then
		return false
	end 
	return true
end

local function checkCondition(condition)
	if condition == "NOT_IN_AA" then
		return checkConditionNotInAAMode();
	elseif condition == "NOT_IN_AG" then
		return checkConditionNotInAGMode();
	elseif condition == "NOT_AT_WP0" then
		return checkConditionNotAtWp0();
	elseif condition == "AT_WP0" then
		return  checkConditionAtWp0();

	elseif condition == "WP_LTE_34" then
		return checkConditionWpLTE34();
	elseif condition == "WP_GTE_35" then
		return checkConditionWpGTE35();

	elseif condition == "CMS_NOT_STBY" then
		return checkConditionNotCMS();
	elseif condition == "RWR_OFF" then
		return checkConditionRWROff();
	elseif condition == "EWHUD_OFF" then
		return checkConditionEWHUD();
	elseif condition == "IFF_OFF" then
		return checkConditionUFCIFFOff();
	elseif condition == "DL_OFF" then
		return checkConditionUFCDLOff();
	elseif condition == "18_NOT_IN_AA" then
		return checkConditionHornetNotRadar();
	elseif condition == "AUTOIFF_OFF" then
		return checkConditionHornetNotAutoIFF();

	elseif condition == "BARS_1B" then
		return checkConditionHornetBars("1B");
	elseif condition == "BARS_2B" then
		return checkConditionHornetBars("2B");
	elseif condition == "BARS_4B" then
		return checkConditionHornetBars("4B");
	elseif condition == "BARS_6B" then
		return checkConditionHornetBars("6B");

	elseif condition == "RANGE_5" then
		return checkConditionHornetRange("5");
	elseif condition == "RANGE_10" then
		return checkConditionHornetRange("10");
	elseif condition == "RANGE_20" then
		return checkConditionHornetRange("20");
	elseif condition == "RANGE_40" then
		return checkConditionHornetRange("40");
	elseif condition == "RANGE_80" then
		return checkConditionHornetRange("80");
	elseif condition == "RANGE_160" then
		return checkConditionHornetRange("160");

	elseif condition == "AZ_20" then
		return checkConditionHornetAz("20");
	elseif condition == "AZ_40" then
		return checkConditionHornetAz("40");
	elseif condition == "AZ_60" then
		return checkConditionHornetAz("60");
	elseif condition == "AZ_80" then
		return checkConditionHornetAz("80");
	elseif condition == "AZ_140" then
		return checkConditionHornetAz("140");

	elseif condition == "PRF_INTL" then
		return checkConditionHornetPRF("INTL");
	elseif condition == "PRF_PDI" then
		return checkConditionHornetPRF("PDI");
	elseif condition == "PRF_MED" then
		return checkConditionHornetPRF("MED");
	elseif condition == "PRF_HI" then
		return checkConditionHornetPRF("HI");

	elseif condition == "Timeout_2" then
		return checkConditionHornetTimeout("2");
	elseif condition == "Timeout_4" then
		return checkConditionHornetTimeout("4");
	elseif condition == "Timeout_8" then
		return checkConditionHornetTimeout("8");
	elseif condition == "Timeout_16" then
		return checkConditionHornetTimeout("16");
	elseif condition == "Timeout_32" then
		return checkConditionHornetTimeout("32");

	elseif condition == "BINGO_ZERO" then
		return  checkConditionBingoIsZero();
	elseif condition:find("^IN_SEQ_") ~= nil then
		return  checkConditionInSequence(string.match(condition, "%d+"));
	elseif condition:find("^STA_IS_GBUTE_") ~= nil then -- GBU38
		return  checkConditionIsJdam(string.match(condition, "%d+"), 82);
	elseif condition:find("^STA_IS_GBUTO_") ~= nil then -- GBU31
		return  checkConditionIsJdam(string.match(condition, "%d+"), 84);
	elseif condition:find("^STA_IS_GBUTOP_") ~= nil then -- GBU31 - Penetrating
		return  checkConditionIsJdam(string.match(condition, "%d+"), 109);
	elseif condition:find("^STA_IS_GBUTT_") ~= nil then -- GBU32
		return  checkConditionIsJdam(string.match(condition, "%d+"), 83);
	elseif condition:find("^STA_IS_JSOWA_") ~= nil then
		return  checkConditionIsJsowA(string.match(condition, "%d+"));
	elseif condition:find("^STA_IS_JSOWC_") ~= nil then
		return  checkConditionIsJsowC(string.match(condition, "%d+"));
	elseif condition:find("^STA_IS_SLAM_") ~= nil then
		return  checkConditionIsSlam(string.match(condition, "%d+"));
	elseif condition:find("^STA_IS_SLAMER_") ~= nil then
		return  checkConditionIsSlamER(string.match(condition, "%d+"));
	elseif condition == "HARM" then
		return checkConditionHARM();
	elseif condition == "HTS_DED" then
		return checkConditionHTSOnDED();	
	elseif condition == "LMFD_HTS" then
		return checkConditionHTSOnMFD("left");	
	elseif condition == "RMFD_HTS" then
		return checkConditionHTSOnMFD("right");	
	elseif condition == "LMFD_HTS_ALL_NOT_SELECTED" then
		return checkConditionHTSAllNotSelected("left");
	elseif condition == "RMFD_HTS_ALL_NOT_SELECTED" then
		return checkConditionHTSAllNotSelected("right");
	elseif condition == "BULLS_NOT_SELECTED" then
		return checkConditionBullseyeNotSelected();
	elseif condition == "BULLS_SELECTED" then
		return checkConditionBullseyeSelected();
	elseif condition == "TACAN_BAND_X" then
		return checkConditionTACANBandX();
	elseif condition == "TACAN_BAND_Y" then
		return checkConditionTACANBandY();
	elseif condition == "LMFD_NOT_TAC" then
		return checkConditionLmfdNotTac();
	elseif condition == "RMFD_NOT_SUPT" then
		return checkConditionRmfdNotSupt();
	else
		return false
	end
end

function LuaExportBeforeNextFrame()
    if upstreamLuaExportBeforeNextFrame ~= nil then
        successful, err = pcall(upstreamLuaExportBeforeNextFrame)
        if not successful then
           log.write("DCS-DTC", log.ERROR, "Error in upstream LuaExportBeforeNextFrame function"..tostring(err))
        end
    end

    if needDelay then
		local currentTime = socket.gettime()
		if ((currentTime - delayStart) > delayNeeded) then
			needDelay = false
			if device ~= "wait" then
				GetDevice(device):performClickableAction(code, 0)
			end
		end
	else
		if keypressinprogress then
			local keys = JSON:decode(data)
			for i=nextIndex, #keys do
				local keyObj = keys[i]
				local startCondition = keyObj["start_condition"]
				local endCondition = keyObj["end_condition"]
				
				if endCondition then
					if endCondition == skipCondition then
						skipCondition = nil
						skip = false
						nextIndex = i+1
					end
				elseif skip then
					nextIndex = i+1	
				elseif startCondition then
					log.write("DCS-DTC", log.ERROR, "startCondition: "..startCondition)
					skipCondition = startCondition
					skip = not checkCondition(startCondition)
					nextIndex = i+1
				else

					device = keyObj["device"]
					code = keyObj["code"]
					delay = tonumber(keyObj["delay"])

					local activate = tonumber(keyObj["activate"])

					if delay > 0 then
						needDelay = true
						delayNeeded = delay / 1000
						delayStart = socket.gettime()
						if device ~= "wait" then
							GetDevice(device):performClickableAction(code, activate)
						end
						nextIndex = i+1
						break
					else
						GetDevice(device):performClickableAction(code, activate)
						if delay == 0 then
							GetDevice(device):performClickableAction(code, 0)
						end
					end
				end
			end
			if not needDelay then
				keypressinprogress = false
				nextIndex = 1
			end
		else
		    local client, err = tcpServer:accept()

            if client ~= nil then
                client:settimeout(10)
			    data, err = client:receive()
			    if err then
				    log.write("DCS-DTC", log.ERROR, "Error at receiving: "..err)  
			    end

			    if data then 
				    keypressinprogress = true
			    end
            end
		end
	end
end

function LuaExportAfterNextFrame()
    if upstreamLuaExportAfterNextFrame ~= nil then
        successful, err = pcall(upstreamLuaExportAfterNextFrame)
        if not successful then
            log.write("DCS-DTC", log.ERROR, "Error in upstream LuaExportAfterNextFrame function"..tostring(err))
        end
    end

    local camPos = LoGetCameraPosition()
	local loX = camPos['p']['x']
	local loZ = camPos['p']['z']
	local elevation = LoGetAltitude(loX, loZ)
	local coords = LoLoCoordinatesToGeoCoordinates(loX, loZ)
	local model = LoGetSelfData()["Name"];
	
	local toSend = "{"..
		"\"model\": ".."\""..model.."\""..
		", ".."\"latitude\": ".."\""..coords.latitude.."\""..
		", ".."\"longitude\": ".."\""..coords.longitude.."\""..
		", ".."\"elevation\": ".."\""..elevation.."\""..
		"}"

	if pcall(function()
		socket.try(udpSpeaker:sendto(toSend, "127.0.0.1", udpPort)) 
	end) then
	else
		log.write("DCS-DTC", log.ERROR, "Unable to send data")
	end
end