-- originally taken from: https://gist.github.com/woodrow/cb1496975e131e37d5dd716127a250a4
-- (which itself was started based on https://gist.github.com/z4yx/218116240e2759759b239d16fed787ca)
--
-- modifications:
-- - ties request into response and (displaying message type on response)
-- - supports decoding of u2f messages into fields
-- - correctly show position of status code
-- - display some fields also as base64

cbor = Dissector.get("cbor")
iso7816 = Dissector.get("iso7816")

ctaphid_proto = Proto("CTAPHID","FIDO Client to Authenticator Protocol over USB HID")
ctaphidfield_cid  = ProtoField.uint32("ctaphid.cid", "Channel ID", base.HEX)
ctaphidfield_cmd  = ProtoField.uint8("ctaphid.cmd", "Command", base.HEX)
ctaphidfield_bcnt = ProtoField.uint16("ctaphid.bcnt", "Payload Length", base.DEC_HEX)
ctaphidfield_seq  = ProtoField.uint8("ctaphid.seq", "Packet Sequence", base.HEX)
ctaphidfield_data = ProtoField.bytes("ctaphid.data", "Data")
ctaphid_proto.fields = { ctaphidfield_cid, ctaphidfield_cmd, ctaphidfield_bcnt, ctaphidfield_seq, ctaphidfield_data }

u2f_proto = Proto("u2f","FIDO CTAP1/U2F Protocol")
u2ffield_cla = ProtoField.uint8("u2f.request.cla", "Class", base.HEX)
u2ffield_ins = ProtoField.uint8("u2f.request.ins", "U2F command code", base.HEX)
u2ffield_p1 = ProtoField.uint8("u2f.request.p1", "U2F command parameter 1", base.HEX)
u2ffield_p2 = ProtoField.uint8("u2f.request.p2", "U2F command parameter 2", base.HEX)
u2ffield_reqlen = ProtoField.uint24("u2f.request.length", "U2F request data length", base.HEX)
u2ffield_reqdata = ProtoField.bytes("u2f.request.data", "U2F request data")
u2ffield_status = ProtoField.uint16("u2f.response.status", "U2F response status", base.HEX)
u2ffield_respdata = ProtoField.bytes("u2f.response.data", "U2F response data")
u2f_proto.fields = { u2ffield_cla, u2ffield_ins, u2ffield_p1, u2ffield_p2, u2ffield_reqlen, u2ffield_reqdata, u2ffield_status, u2ffield_respdata }


-- Field Extractor
field_usb_bus = Field.new("usb.bus_id")
field_usb_device = Field.new("usb.device_address")
field_usb_endpoint = Field.new("usb.endpoint_address")
field_usb_endpointdir = Field.new("usb.endpoint_address.direction")
field_usb_datalen = Field.new("usb.data_len")
field_iso7816_ins = Field.new("iso7816.apdu.ins")
field_iso7816_p1 = Field.new("iso7816.apdu.p1")
field_iso7816_p2 = Field.new("iso7816.apdu.p2")
field_iso7816_sw1 = Field.new("iso7816.apdu.sw1")
field_iso7816_sw2 = Field.new("iso7816.apdu.sw2")
field_iso7816_lc = Field.new("iso7816.apdu.lc")
field_iso7816_le = Field.new("iso7816.apdu.le")
field_iso7816_data = Field.new("iso7816.application_data")

CTAPHID_COMMANDS = {
	CTAPHID_MSG          = 0x03,
	CTAPHID_CBOR         = 0x10,
	CTAPHID_INIT         = 0x06,
	CTAPHID_PING         = 0x01,
	CTAPHID_CANCEL       = 0x11,
	CTAPHID_ERROR        = 0x3F,
	CTAPHID_KEEPALIVE    = 0x3B,
	CTAPHID_WINK         = 0x08,
	CTAPHID_LOCK         = 0x04,
	CTAPHID_VENDOR_FIRST = 0x40,
	CTAPHID_VENDOR_LAST  = 0x7F
}

CTAPHID_COMMAND_STRINGS = {
    [0x03] = 'CTAPHID_MSG',
    [0x10] = 'CTAPHID_CBOR',
    [0x06] = 'CTAPHID_INIT',
    [0x01] = 'CTAPHID_PING',
    [0x11] = 'CTAPHID_CANCEL',
    [0x3F] = 'CTAPHID_ERROR',
    [0x3B] = 'CTAPHID_KEEPALIVE',
    [0x08] = 'CTAPHID_WINK',
    [0x04] = 'CTAPHID_LOCK',
	[0x40] = 'VENDOR_FIRST',
	[0x7F] = 'VENDOR_LAST',
}

U2F_STATUS_STRINGS = {
    [0x9000] = 'SW_NO_ERROR',
    [0x6985] = 'SW_CONDITIONS_NOT_SATISFIED',
    [0x6A80] = 'SW_WRONG_DATA',
	[0x6700] = 'SW_WRONG_LENGTH',
	[0x6E00] = 'SW_CLA_NOT_SUPPORTED',
	[0x6D00] = 'SW_INS_NOT_SUPPORTED'
}

CTAP_COMMAND_CODE = {
    [0x01]='authenticatorMakeCredential',
    [0x02]='authenticatorGetAssertion',
    [0x04]='authenticatorGetInfo',
    [0x06]='authenticatorClientPIN',
    [0x07]='authenticatorReset',
    [0x08]='authenticatorGetNextAssertion',
    [0x40]='authenticatorVendorFirst',
    [0xBF]='authenticatorVendorLast'
}
CTAP_RESPONSE_CODE = {
    [0x00]='CTAP1_ERR_SUCCESS',
    [0x01]='CTAP1_ERR_INVALID_COMMAND',
    [0x02]='CTAP1_ERR_INVALID_PARAMETER',
    [0x03]='CTAP1_ERR_INVALID_LENGTH',
    [0x04]='CTAP1_ERR_INVALID_SEQ',
    [0x05]='CTAP1_ERR_TIMEOUT',
    [0x06]='CTAP1_ERR_CHANNEL_BUSY',
    [0x0A]='CTAP1_ERR_LOCK_REQUIRED',
    [0x0B]='CTAP1_ERR_INVALID_CHANNEL',
    [0x11]='CTAP2_ERR_CBOR_UNEXPECTED_TYPE',
    [0x12]='CTAP2_ERR_INVALID_CBOR',
    [0x14]='CTAP2_ERR_MISSING_PARAMETER',
    [0x15]='CTAP2_ERR_LIMIT_EXCEEDED',
    [0x16]='CTAP2_ERR_UNSUPPORTED_EXTENSION',
    [0x19]='CTAP2_ERR_CREDENTIAL_EXCLUDED',
    [0x21]='CTAP2_ERR_PROCESSING',
    [0x22]='CTAP2_ERR_INVALID_CREDENTIAL',
    [0x23]='CTAP2_ERR_USER_ACTION_PENDING',
    [0x24]='CTAP2_ERR_OPERATION_PENDING',
    [0x25]='CTAP2_ERR_NO_OPERATIONS',
    [0x26]='CTAP2_ERR_UNSUPPORTED_ALGORITHM',
    [0x27]='CTAP2_ERR_OPERATION_DENIED',
    [0x28]='CTAP2_ERR_KEY_STORE_FULL',
    [0x29]='CTAP2_ERR_NOT_BUSY',
    [0x2A]='CTAP2_ERR_NO_OPERATION_PENDING',
    [0x2B]='CTAP2_ERR_UNSUPPORTED_OPTION',
    [0x2C]='CTAP2_ERR_INVALID_OPTION',
    [0x2D]='CTAP2_ERR_KEEPALIVE_CANCEL',
    [0x2E]='CTAP2_ERR_NO_CREDENTIALS',
    [0x2F]='CTAP2_ERR_USER_ACTION_TIMEOUT',
    [0x30]='CTAP2_ERR_NOT_ALLOWED',
    [0x31]='CTAP2_ERR_PIN_INVALID',
    [0x32]='CTAP2_ERR_PIN_BLOCKED',
    [0x33]='CTAP2_ERR_PIN_AUTH_INVALID',
    [0x34]='CTAP2_ERR_PIN_AUTH_BLOCKED',
    [0x35]='CTAP2_ERR_PIN_NOT_SET',
    [0x36]='CTAP2_ERR_PIN_REQUIRED',
    [0x37]='CTAP2_ERR_PIN_POLICY_VIOLATION',
    [0x38]='CTAP2_ERR_PIN_TOKEN_EXPIRED',
    [0x39]='CTAP2_ERR_REQUEST_TOO_LARGE',
    [0x3A]='CTAP2_ERR_ACTION_TIMEOUT',
    [0x3B]='CTAP2_ERR_UP_REQUIRED',
    [0x7F]='CTAP1_ERR_OTHER',
    [0xDF]='CTAP2_ERR_SPEC_LAST',
    [0xE0]='CTAP2_ERR_EXTENSION_FIRST',
    [0xEF]='CTAP2_ERR_EXTENSION_LAST',
    [0xF0]='CTAP2_ERR_VENDOR_FIRST',
    [0xFF]='CTAP2_ERR_VENDOR_LAST'
}




-- from https://lua-users.org/wiki/BaseSixtyFour
-- Lua 5.1+ base64 v3.0 (c) 2009 by Alex Kloss <alexthkloss@web.de>
-- licensed under the terms of the LGPL2

local b64='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

-- encoding
function b64enc(data)
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b64:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end


-- decoding
function b64dec(data)
    data = string.gsub(data, '[^'..b64..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b64:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end











function dissect_ctaphid_payload(cmd, buffer, pinfo, tree)
	if buffer:len() == 0 then return end -- && usb.function == 0x0008 && select correct endpoint/etc.
	if cmd == CTAPHID_COMMANDS.CTAPHID_MSG then
		 local isotree = tree:add("iso")
		 iso7816:call(buffer, pinfo, isotree)
		 isotree.hidden = true
		-- print(field_iso7816_ins().value, field_iso7816_p1().value, field_iso7816_p2().value)
		Dissector.get("u2f"):call(buffer, pinfo, tree)
		-- pinfo.cols.protocol = u2f_proto.name
		-- local subtree = tree:add(ctaphid_proto,buffer(),"CTAP1/U2F")
		-- local is_request = (field_usb_endpointdir().value == 0)
		-- print(field_usb_endpointdir().value)
		-- print(is_request)
		-- print(Dissector.get("u2f"))
		-- if is_request then -- this is a request
			-- local u2f_command = buffer(1,1):uint()
			-- subtree:append_text(" Request")
			-- pinfo.cols.info = "U2F Request (" .. u2f_command_label(u2f_command, true) .. ")"
			-- subtree:add(u2ffield_cla, buffer(0,1))
			-- subtree:add(u2ffield_ins, buffer(1,1), u2f_command, "Command: " .. u2f_command_label(u2f_command))			
			-- subtree:add(u2ffield_p1, buffer(2,1))
			-- subtree:add(u2ffield_p2, buffer(3,1))
			-- local request_length = buffer(4,3):uint()
			-- subtree:add(u2ffield_reqlen, buffer(4,3))
			-- subtree:add(u2ffield_reqdata, buffer(7, request_length))
		-- else -- response
			-- local u2f_status = buffer(buffer:len()-2,2):uint()
			-- subtree:append_text(" Response")
			-- pinfo.cols.info = "U2F Response (" .. u2f_status_label(u2f_status, true) .. ")"
			-- subtree:add(u2ffield_status, u2f_status, u2f_status, "Status: " .. u2f_status_label(u2f_status))
			-- if buffer:len() > 2 then
			-- subtree:add(u2ffield_respdata, buffer(0, buffer:len()-2))
			-- end
		-- end		
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_CBOR then
        local subtree = tree:add(buffer(0),"FIDO2 Payload")
        local ctap_cmd = buffer(0,1):uint()
		local text = nil
		if is_request then
			text = CTAP_COMMAND_CODE[ctap_cmd]
		else
			text = CTAP_RESPONSE_CODE[ctap_cmd]
		end
        pinfo.cols.protocol = "CTAP " .. text
        subtree:add(buffer(0,1),string.format('CTAP CMD/Status: %s (0x%02x)', text, ctap_cmd))
        if buffer(1):len() > 0 then
            cbor:call(buffer(1):tvb(), pinfo, subtree)
        end
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_INIT then
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_PING then
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_CANCEL then
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_ERROR then
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_KEEPALIVE then
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_WINK then
	elseif cmd == CTAPHID_COMMANDS.CTAPHID_LOCK then
	elseif cmd >= CTAPHID_COMMANDS.CTAPHID_VENDOR_FIRST and cmd <= CTAPHID_COMMANDS.CTAPHID_VENDOR_LAST then
	else
		tree:add(ctaphidfield_data, buffer(0)):prepend_text("Unknown payload ")
	end
end

function u2f_command_label(cmd, abbrev)
	if abbrev ~= true then
		abbrev = false
	end
	local command_string = U2F_INS_STRINGS[cmd]
	if command_string ~= nil then
		command_string = command_string[1]
	end
	if command_string ~= nil and not abbrev then
		command_string = command_string .. string.format(" (0x%02x)", cmd)
	elseif command_string == nil then
		command_string =  string.format("0x%02x", cmd)
	end
	return command_string
end

function u2f_payload_decoder(cmd, is_request)
	local command = U2F_INS_STRINGS[cmd]
	if command == nil then
		return nil
	end
	if is_request then
		return command[2]
	end
	return command[3]
end

function u2f_status_label(status, abbrev)
	if abbrev ~= true then
		abbrev = false
	end
	local status_string = U2F_STATUS_STRINGS[status]
	if status_string ~= nil and not abbrev then
		status_string = status_string .. string.format(" (0x%02x)", status)
	elseif status_string == nil then
		status_string =  string.format("0x%02x", status)
	end
	return status_string
end

function ctaphid_command_label(cmd)
	local command_string = CTAPHID_COMMAND_STRINGS[cmd]
	if command_string ~= nil then
		command_string = command_string .. string.format(" (0x%02x)", cmd)
	else
		command_string =  string.format("0x%02x", cmd)
		if cmd >= CTAPHID_COMMANDS.CTAPHID_VENDOR_FIRST and cmd <= CTAPHID_COMMANDS.CTAPHID_VENDOR_LAST then
			command_string = command_string .. " [Vendor specific]"
		end
	end
	return command_string
end

function channel_state_key(channel_id)
	local key = Struct.pack(">I2I2I1", field_usb_bus().value, field_usb_device().value, field_usb_endpoint().value) .. channel_id:bytes():raw()
	return Struct.tohex(key)
end

packet_state = {} -- { packet_number => { cmd = uint, buffer = bytearray, complete = bool } }
channel_state = {} -- { channel_state_key => { cmd = uint, payload_length = uint, buffer = bytearray } }

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

command_state = {}
function lookup_command_state(pinfo)
	-- lua dissectors have no conversation! what a pain
	-- nasty hack
	-- TODO: include channel_id / channel state key

	local pos = pinfo.number
	while true
	do
		pos = pos - 1
		if pos == 0 then
			return nil
		end
		local c = command_state[pos]
		if c ~= nil then
			return c
		end
		
	end
end

function create_command_state(pinfo)
--	print(packet_state[pinfo.number].channel_id)
	local cstate = command_state[pinfo.number]
	if cstate == nil then
		cstate = {}
		command_state[pinfo.number] = cstate
	end
	return cstate
end

function u2f_proto.dissector(buffer,pinfo,tree)
	if buffer:len() == 0 then return end -- && usb.function == 0x0008 && select correct endpoint/etc.
	print("u2f_before", pinfo.curr_proto)
	pinfo.cols.protocol = u2f_proto.name -- FIXME why can't I filter against this?
	print("u2f_after", pinfo.curr_proto)
	local subtree = tree:add(ctaphid_proto,buffer(),"CTAP1/U2F")
	local is_request = (field_usb_endpointdir().value == 0)
	if is_request then -- this is a request
		local cmdstate = create_command_state(pinfo)
		local u2f_command = buffer(1,1):uint()
		cmdstate.u2f_command = u2f_command
		subtree:append_text(" Request")
		pinfo.cols.info = "U2F Request (" .. u2f_command_label(u2f_command, true) .. ")"
		subtree:add(u2ffield_cla, buffer(0,1))
		subtree:add(u2ffield_ins, buffer(1,1), u2f_command, "Command: " .. u2f_command_label(u2f_command))			
		subtree:add(u2ffield_p1, buffer(2,1))
		subtree:add(u2ffield_p2, buffer(3,1))
		local request_length = buffer(4,3):uint()
		subtree:add(u2ffield_reqlen, buffer(4,3))
		local payload = buffer(7, request_length)
		subtree:add(u2ffield_reqdata, payload)

		local payload_decoder = u2f_payload_decoder(u2f_command, true)
		if payload_decoder then
			payload_decoder(payload, pinfo, tree)
		end
	else -- response
		local cmdstate = lookup_command_state(pinfo)
		local u2f_status = buffer(buffer:len()-2,2):uint()
		subtree:append_text(" Response")
		pinfo.cols.info = "U2F Response (" .. u2f_status_label(u2f_status, true) .. ") [" .. u2f_command_label(cmdstate.u2f_command)  .. "]"
		subtree:add(u2ffield_status, buffer(buffer:len()-2,2), u2f_status, "Status: " .. u2f_status_label(u2f_status))
		if buffer:len() > 2 then
			local payload = buffer(0, buffer:len()-2)
			subtree:add(u2ffield_respdata, payload)

			local payload_decoder = u2f_payload_decoder(cmdstate.u2f_command, false)
			if payload_decoder then
				payload_decoder(payload, pinfo, tree)
			end
		end
	end
	return true
end

function ctaphid_proto.init()
	packet_state = {}
	channel_state = {}
end

function ctaphid_proto.dissector(buffer,pinfo,tree)
    if buffer:len() == 0 then return end -- && usb.function == 0x0008 && select correct endpoint/etc.
	print("hid_before", pinfo.curr_proto)
	pinfo.cols.protocol = ctaphid_proto.name
	print("hid_after", pinfo.curr_proto)
	
	local channel_id = buffer(0,4)
	local payload = nil
	local cmd_or_seq = buffer(4,1):uint()
	local is_init_packet = (bit.band(cmd_or_seq, 0x80) == 0x80)
	local cmd = nil
	local payload_length = nil
	local sequence = nil
	
	-- extract relevant fields for each packet type
	if is_init_packet then
		cmd = bit.band(cmd_or_seq, 0x7f) -- ignore first bit of command field on initialization packets
		payload_length = buffer(5,2):uint()
		payload = buffer(7)
	else
		sequence = cmd_or_seq
		payload = buffer(5)
	end
	
	-- keep track of state across packets to combine segmented packets
	local pstate = packet_state[pinfo.number]
	local cstate = nil
	if pstate == nil then
		pstate = {}
		pstate.channel_id = channel_id
		cstate = channel_state[channel_state_key(channel_id)]
		if cstate == nil then
			assert(is_init_packet)
			cstate = {}
			cstate.buffer = payload:bytes()
			cstate.cmd = cmd
			cstate.payload_length = payload_length
			channel_state[channel_state_key(channel_id)] = cstate
		else
			cstate.buffer:append(payload:bytes())
			--buffer = ByteArray.tvb(cstate.buffer, "Command") -- create new tvb for packet
		end
		
		if cstate.payload_length > cstate.buffer:len() then -- packet incomplete
			pstate.complete = false
			pstate.cmd = cstate.cmd
		else
			cstate.buffer:set_size(cstate.payload_length) -- usbpcap always returns full packets so we need to truncate them
			pstate.complete = true
			pstate.cmd = cstate.cmd
			pstate.buffer = cstate.buffer
			channel_state[channel_state_key(channel_id)] = nil
		end
		packet_state[pinfo.number] = pstate
	end
	
	-- generate CTAPHID subtree
	local subtree = tree:add(ctaphid_proto,buffer())

	if is_init_packet then
		local packet_text = "CTAPHID Initialization Packet"
		pinfo.cols.info = packet_text
		subtree:set_text(packet_text)
		subtree:add(ctaphidfield_cid, channel_id)
		subtree:add(ctaphidfield_cmd, buffer(4,1), cmd, "Command: " .. ctaphid_command_label(cmd))
		subtree:add(ctaphidfield_bcnt, buffer(5,2))
		subtree:add(ctaphidfield_data, payload)
	else
		local packet_text ="CTAPHID Continuation Packet"
		pinfo.cols.info = packet_text
		subtree:set_text(packet_text)
		subtree:add(ctaphidfield_cid, channel_id)
		subtree:add("Command: " .. ctaphid_command_label(pstate.cmd)):set_generated(true)
		subtree:add(ctaphidfield_seq, buffer(4,1))
		subtree:add(ctaphidfield_data, payload)
	end
		
	if pstate.complete then
		dissect_ctaphid_payload(pstate.cmd, pstate.buffer:tvb("CTAPHID data"), pinfo, tree)
	end
	return
end

u2f_register_request_proto = Proto("u2f_register_request","Register Request")
u2f_register_request_proto_challenge_param = ProtoField.bytes("u2f_register_request.challenge_param", "Challenge parameter")
u2f_register_request_proto_application_param = ProtoField.bytes("u2f_register_request.application_param", "Application parameter")
u2f_register_request_proto.fields = { u2f_register_request_proto_challenge_param, u2f_register_request_proto_application_param }

u2f_register_response_proto = Proto("u2f_register_response","Register Response")
u2f_register_response_proto_reserved_byte = ProtoField.bytes("u2f_register_response.challenge_param", "Reserved byte")
u2f_register_response_proto_user_public_key = ProtoField.bytes("u2f_register_response.user_public_key", "User public key")
u2f_register_response_proto_key_handle_length = ProtoField.uint8("u2f_register_response.key_handle_length", "Key handle length")
u2f_register_response_proto_key_handle = ProtoField.bytes("u2f_register_response.key_handle", "Key handle")
u2f_register_response_proto_key_handle_base64 = ProtoField.string("u2f_register_response.key_handle_base64", "As base64")
u2f_register_response_proto_attestation_certificate = ProtoField.bytes("u2f_register_response_proto_attestation_certificate", "Attestation certificate") -- asn.1 (der) encoded
u2f_register_response_proto_signature = ProtoField.bytes("u2f_register_response.signature", "Signature") -- asn.1 (der) encoded
u2f_register_response_proto.fields = { u2f_register_response_proto_reserved_byte, u2f_register_response_proto_user_public_key, u2f_register_response_proto_key_handle_length, u2f_register_response_proto_key_handle, u2f_register_response_proto_key_handle_base64, u2f_register_response_proto_attestation_certificate, u2f_register_response_proto_signature }

u2f_authenticate_request_proto = Proto("u2f_authenticate_request","Authenticate Request")
u2f_authenticate_request_proto_challenge_param = ProtoField.bytes("u2f_authenticate_request.challenge_param", "Challenge parameter")
u2f_authenticate_request_proto_application_param = ProtoField.bytes("u2f_authenticate_request.application_param", "Application parameter")
u2f_authenticate_request_proto_key_handle_length = ProtoField.uint8("u2f_authenticate_request.key_handle_length", "Key handle length")
u2f_authenticate_request_proto_key_handle = ProtoField.bytes("u2f_authenticate_request.key_handle", "Key handle")
u2f_authenticate_request_proto_key_handle_base64 = ProtoField.string("u2f_authenticate_request.key_handle", "As base64")
u2f_authenticate_request_proto.fields = { u2f_authenticate_request_proto_challenge_param, u2f_authenticate_request_proto_application_param, u2f_authenticate_request_proto_key_handle_length, u2f_authenticate_request_proto_key_handle, u2f_authenticate_request_proto_key_handle_base64 }

u2f_authenticate_response_proto = Proto("u2f_authenticate_response","Authenticate Response")
u2f_authenticate_response_proto_user_presence = ProtoField.uint8("u2f_authenticate_response.user_presence", "User presence")
u2f_authenticate_response_proto_counter = ProtoField.uint32("u2f_authenticate_response.counter", "Counter")
u2f_authenticate_response_proto_signature = ProtoField.bytes("u2f_authenticate_response.signature", "Signature") -- asn.1 (der) encoded
u2f_authenticate_response_proto.fields = { u2f_authenticate_response_proto_user_presence, u2f_authenticate_response_proto_counter, u2f_authenticate_response_proto_signature }

-- includes the sequence header size
function decode_asn1_sequence_length(buffer, pos)
	if buffer(pos,1):uint() ~= 48 then
		return false, "not asn.1 sequence"
	end
	-- https://docs.microsoft.com/en-us/windows/win32/seccertenroll/about-encoded-length-and-value-bytes
	local fb = buffer(pos+1,1):uint()
	if fb <= 127 then
		return true, fb + 2
	end
	-- we only handle 1 and 2 (easy enough to expand to more if needed)
	if fb == 130 then -- 0x82 (meaning 0x80 | 2 length bytes)
		return true, buffer(pos+2,2):uint() + 4
	end
	return false, "unknown length of bits"
end

function decode_u2f_register_request(buffer,pinfo,tree)
	local subtree = tree:add(u2f_register_request_proto, buffer())
	subtree:set_text("U2F Register Request")
	subtree:add(u2f_register_request_proto_challenge_param, buffer(0,32))
	subtree:add(u2f_register_request_proto_application_param, buffer(32,32))
end

function decode_u2f_register_response(buffer,pinfo,tree)
	local subtree = tree:add(u2f_register_response_proto, buffer())
	subtree:set_text("U2F Register Response")
	subtree:add(u2f_register_response_proto_reserved_byte, buffer(0,1))
	subtree:add(u2f_register_response_proto_user_public_key, buffer(1,65))
	subtree:add(u2f_register_response_proto_key_handle_length, buffer(66,1))
	local key_handle_length = buffer(66,1):uint()

	local key_handle_tree = subtree:add(u2f_register_response_proto_key_handle, buffer(67,key_handle_length))
	key_handle_tree:add(u2f_register_response_proto_key_handle_base64, buffer(67,key_handle_length), b64enc(buffer:raw(67, key_handle_length)))

	local att_start = 67+key_handle_length
	local success, att_len = decode_asn1_sequence_length(buffer, att_start)
	if not success then
		subtree:set_text("FAILED DECODING " .. att_len)
		return
	end
	subtree:add(u2f_register_response_proto_attestation_certificate, buffer(att_start,att_len))
	local sig_start = att_start+att_len
	local success, sig_len = decode_asn1_sequence_length(buffer, sig_start)
	if not success or sig_len ~= buffer:len()-sig_start then
		subtree:set_text("FAILED DECODING (2) " .. sig_len)
		return
	end
	subtree:add(u2f_register_response_proto_signature, buffer(sig_start,sig_len))
end

function decode_u2f_auth_request(buffer,pinfo,tree)
	local subtree = tree:add(u2f_authenticate_request_proto, buffer())
	subtree:set_text("U2F Authenticate Request")
	subtree:add(u2f_authenticate_request_proto_challenge_param, buffer(0,32))
	subtree:add(u2f_authenticate_request_proto_application_param, buffer(32,32))
	subtree:add(u2f_authenticate_request_proto_key_handle_length, buffer(64,1))
	local key_handle_length = buffer(64,1):uint()

	local key_handle_tree = subtree:add(u2f_authenticate_request_proto_key_handle, buffer(65,key_handle_length))
	key_handle_tree:add(u2f_authenticate_request_proto_key_handle_base64, buffer(65,key_handle_length), b64enc(buffer:raw(65+7, key_handle_length)))
end

function decode_u2f_auth_response(buffer,pinfo,tree)
	local subtree = tree:add(u2f_authenticate_response_proto, buffer())
	subtree:set_text("U2F Authenticate Response")
	subtree:add(u2f_authenticate_response_proto_user_presence, buffer(0,1))
	subtree:add(u2f_authenticate_response_proto_counter, buffer(1,4))
	local sig_start = 5
	local success, sig_len = decode_asn1_sequence_length(buffer, sig_start)
	if not success or sig_len ~= buffer:len()-sig_start then
		subtree:set_text("FAILED DECODING " .. sig_len)
		return
	end

	subtree:add(u2f_authenticate_response_proto_signature, buffer(sig_start, sig_len))
end

U2F_INS_STRINGS = {
    [0x01] = {'U2F_REGISTER', decode_u2f_register_request, decode_u2f_register_response},
    [0x02] = {'U2F_AUTHENTICATE', decode_u2f_auth_request, decode_u2f_auth_response},
    [0x03] = {'U2F_VERSION', nil, nil},
    [0x40] = {'VENDOR_FIRST', nil, nil},
    [0xBF] = {'VENDOR_LAST', nil, nil},
}

usb_table = DissectorTable.get("usb.product")
usb_table:add(0x10500407,ctaphid_proto) -- VID/PID of Yubikey
usb_table:add(0x096e0858,ctaphid_proto) -- VID/PID of Feitian key
usb_table:add(0x10500406,ctaphid_proto) -- VID/PID of Yubikey
usb_table:add_for_decode_as(u2f_proto)
