-- Settings for our FTP client
local ip = "0.0.0.0"
local port = 21
local user = ""
local pass = ""
local tls = true

-- Local variables used by the homebrew
local data_port = 22
local skt = nil
local data_skt = nil
local cns = nil
local timeout = 8000
local console_lines = 16
local timeout_retries = 3
local last_response
local need_refresh = true
local server_dir
local client_dir = "/"
local p = {1, 1}
local master_index = {0, 0}
local mode = 2
local oldpad = KEY_A
local files_table = {nil, nil}
local menu_color = Color.new(255, 255, 255)
local selected_color = Color.new(0,255,0)
local is_ssl = false

-- Internal functions used by the filebrowser
function TableConcat(t1,t2)
    for i=1,#t2 do
        t1[#t1+1] = t2[i]
    end
    return t1
end
function SortDirectory(dir)
	local folders_table = {}
	local int_table = {}
	for i,file in pairs(dir) do
		if file.directory then
			table.insert(folders_table,file)
		else
			table.insert(int_table,file)
		end
	end
	table.sort(int_table, function (a, b) return (a.name:lower() < b.name:lower() ) end)
	table.sort(folders_table, function (a, b) return (a.name:lower() < b.name:lower() ) end)
	return_table = TableConcat(folders_table,int_table)
	return return_table
end

-- Debug console writing function
function consoleWrite(text)
	if console_lines > 15 then
		Screen.refresh()
		Screen.clear(BOTTOM_SCREEN)
		Screen.waitVblankStart()
		Screen.flip()
		Screen.refresh()
		Screen.clear(BOTTOM_SCREEN)
		Console.clear(cns)
		console_lines = 0
	end
	i = 0
	Screen.refresh()
	old_w = Console.show(cns)
	Console.append(cns, text)
	new_w = Console.show(cns)
	if new_w == old_w then
		console_lines = 16
		consoleWrite(text)
	end
	while i < 2 do
		Screen.refresh()
		Console.show(cns)
		Screen.waitVblankStart()
		Screen.flip()
		i = i + 1
	end
	console_lines = console_lines + 1
end

-- Generic FTP command sender function
function sendCommand(cmd, args)
	if skt == nil then
		error("An error occurred during command sending.")
	end
	local query = cmd .. " " .. args .. "\r"
	if args == "" then
		query = cmd .. "\r"
	end
	tot_len = string.len(query)
	len = 0
	while len < tot_len do
		len = len + Socket.send(skt, string.sub(query,len+1), is_ssl)
	end
	if cmd == "PASS" then
		query = cmd .. " ********"
	end
	consoleWrite("Client: " .. query .. "\n")
end

-- FTP Data socket opener function
function openDataSocket()
	consoleWrite("Opening data channel on port " ..data_port.. "...\n")
	data_skt = Socket.connect(ip, data_port, is_ssl)
end

-- FTP Data sender function
function sendData(data)
	if data_skt == nil then
		error("An error occurred during data sending.")
	end
	return Socket.send(data_skt, data)
end

-- FTP Data receiver function
function recvData()
	if data_skt == nil then
		error("An error occurred during data sending.")
	end
	return Socket.receive(data_skt, 32768)
end

-- FTP Data closer function
function closeDataSocket()
	Socket.close(data_skt)
	data_skt = nil
end

-- Command socket connector function
function initServer(ip, port)
	skt = Socket.connect(ip, port)
	data_port = port + 1
end

-- Command socket closer function
function termServer()
	Socket.close(skt)
	skt = nil
end

-- Function to wait for a response by the server
function recvResponse()
	local timer = Timer.new()
	local response = ""
	local rsp = ""
	while string.len(response) < 3 do
		if Timer.getTime(timer) > timeout then
			consoleWrite("Server timed out... retrying...\n")
			Timer.destroy(timer)
			return false
		end
		rsp = Socket.receive(skt, 32768, is_ssl)
		response = response .. rsp
	end
	last_response = response
	consoleWrite("Server: " .. response)
	return true
end

-- Function to send a command and wait for a response
function sendResponsiveCommand(cmd, args)
	local result = false
	local attempt = 0
	while not result do
		if attempt < timeout_retries then
			sendCommand(cmd, args)
			result = recvResponse()
			attempt = attempt + 1
		else
			consoleWrite("Connection timed out...\n")
			break
		end
	end
	return result
end

-- PHP explode porting for LUA developing
function explode(div,str)
	pos = 0
	arr = {}
	for st,sp in function() return string.find(str,div,pos,true) end do
		table.insert(arr,string.sub(str,pos,st-1))
		pos = sp + 1
	end
	table.insert(arr,string.sub(str,pos))
	return arr
end

-- Gets return code of last response of the server
function getReturnCode()
	local tmp = explode(" ",last_response)
	return math.tointeger(tonumber(tmp[1]))
end

-- FTP login function
function estabilishConnection(ip, port, user, pass)
	consoleWrite("Connecting to " .. ip .. ":" .. port .. "...\n")
	initServer(ip, port)
	consoleWrite("Connected, waiting for welcome message.\n")
	recvResponse()
	if tls then
		sendCommand("AUTH","TLS")
		if recvResponse() then
			if getReturnCode() <= 300 then
				is_ssl = true
			end
		else
			consoleWrite("Normal connection will be performed...\n")
			termServer()
			consoleWrite("Connecting to " .. ip .. ":" .. port .. "...\n")
			initServer(ip, port)
			consoleWrite("Connected, waiting for welcome message.\n")
			recvResponse()
		end
	end
	if sendResponsiveCommand("USER",user) then
		if sendResponsiveCommand("PASS",pass) then
			if is_ssl then
				sendResponsiveCommand("PBSZ","0")
				sendResponsiveCommand("PROT","P")
			end
			return true
		end
		return false
	end
	return false
end

-- Gets working directory from the server
function getWorkingDirectory()
	sendResponsiveCommand("PWD","")
	offs = string.find(last_response, "\"")
	tmp = string.sub(last_response, offs+1)
	offs2 = string.find(tmp, "\"")
	return string.sub(tmp, 0, offs2-1)
end

-- Directory opener function
function OpenDirectory(text,mode)
	if text == "." then
		return
	end
	need_refresh = true
	if mode == 2 then
		i=0
		if text == ".." then
			j=-2
			while string.sub(client_dir,j,j) ~= "/" do
				j=j-1
			end
			client_dir = string.sub(client_dir, 1, j)
		else
			client_dir = client_dir .. text .. "/"
		end
		files_table[2] = System.listDirectory(client_dir)
		if System.currentDirectory() ~= "/" then
			local extra = {}
			extra.name = ".."
			extra.size = 0
			extra.directory = true
			table.insert(files_table[2],extra)
		end
		files_table[2] = SortDirectory(files_table[2])
	else
		sendResponsiveCommand("CWD", server_dir .. text .. "/")
		server_dir = getWorkingDirectory()
		enterPassiveMode()
		if string.sub(server_dir,-1,-1) ~= "/" then
			server_dir = server_dir .. "/"
		end
		listServerDirectory()
	end
end

-- Store file function
function storeFile(filename)
	sendResponsiveCommand("TYPE", "I")
	enterPassiveMode()
	sendCommand("STOR", filename)
	openDataSocket()
	recvResponse()
	consoleClear()
	consoleWrite("Transfering " .. filename .. "...\n")
	input = io.open(client_dir..filename,FREAD)
	local filesize = io.size(input)
	local i = 0
	while i < filesize do
		packet_size = math.min(524288,filesize-i)
		i = i + sendData(io.read(input,i,packet_size))
	end
	closeDataSocket()
	io.close(input)
	recvResponse()
	recvResponse()
	enterPassiveMode()
	listServerDirectory()
	need_refresh = true
end

-- Retrieve file function
function retrieveFile(filename)
	sendResponsiveCommand("TYPE", "I")
	enterPassiveMode()
	sendCommand("RETR", filename)
	openDataSocket()
	recvResponse()
	consoleWrite("Retrieving " .. filename .. "...\n")
	output = io.open(client_dir..filename,FCREATE)
	local i = 0
	local packet_size = 3
	local tmp = Timer.new()
	Timer.pause(tmp)
	while packet_size > 2 or Timer.getTime(tmp) < 1000 do
		if packet_size <= 2 then
			Timer.resume(tmp)
		else
			Timer.pause(tmp)
		end
		packet = recvData()
		packet_size = string.len(packet)
		io.write(output, i, packet, packet_size)
		i = i + packet_size
	end
	Timer.destroy(tmp)
	closeDataSocket()
	io.close(output)
	recvResponse()
	recvResponse()
	files_table[2] = System.listDirectory(client_dir)
	if System.currentDirectory() ~= "/" then
		local extra = {}
		extra.name = ".."
		extra.size = 0
		extra.directory = true
		table.insert(files_table[2],extra)
	end
	files_table[2] = SortDirectory(files_table[2])
	need_refresh = true
end

-- Gets files list from the server
function listServerDirectory()
	sendCommand("LIST","")
	openDataSocket()
	recvResponse()
	local data = ""
	local packet_size = 3
	consoleWrite("Receiving data from the server...\n")
	local tmp = Timer.new()
	Timer.pause(tmp)
	while packet_size > 2 or Timer.getTime(tmp) < 1000 do
		if packet_size <= 2 then
			Timer.resume(tmp)
		else
			Timer.pause(tmp)
		end
		packet = recvData()
		packet_size = string.len(packet)
		data = data .. packet
	end
	Timer.destroy(tmp)
	consoleWrite("Closing data channel...\n")
	closeDataSocket()
	local entries = explode("\r",data)
	server_files = {}
	for i, entry in pairs(entries) do
		if string.len(entry) < 20 then
			break
		end
		local tmp = explode(" ",entry)
		table.insert(server_files, {["name"] = tmp[#tmp], ["directory"] = (not (string.find(tmp[1],"d") == nil))})
	end
	files_table[1] = SortDirectory(server_files)
	recvResponse()
end

-- Passive Mode func
function enterPassiveMode()
	sendResponsiveCommand("PASV","")
	local tmp = explode(",",last_response)
	local offs_last = string.find(tmp[6],")")
	if offs_last == nil then
		offs_last = -1
	end
	local last_val = string.sub(tmp[6],1,offs_last-1)
	data_port = (math.tointeger(tonumber(tmp[5]))<<8) + math.tointeger(tonumber(last_val))
end

-- File lister functions
function CropPrint(x, y, text, color, screen)
	if string.len(text) > 15 then
		Screen.debugPrint(x, y, string.sub(text,1,15) .. "...", color, screen)
	else
		Screen.debugPrint(x, y, text, color, screen)
	end
end
function FileLister(mode_int)
	x = (mode_int - 1) * 200 + 2
	base_y = 17
	for l, file in pairs(files_table[mode_int]) do
		if (base_y > 230) then
			break
		end
		if (l >= master_index[mode_int]) then
			if (l==p[mode_int]) then
				color = selected_color
			else
				color = menu_color
			end
			CropPrint(x,base_y,file.name,color,TOP_SCREEN)
			base_y = base_y + 15
		end
	end
end

-- Delete file function
function DeleteFile(filename, mode)
	if mode == 2 then
		System.deleteFile(client_dir..files_table[mode][p[mode]].name)
		while (#files_table[2] > 0) do
			table.remove(files_table[2])
		end
		files_table[2] = System.listDirectory(client_dir)
		if System.currentDirectory() ~= "/" then
			local extra = {}
			extra.name = ".."
			extra.size = 0
			extra.directory = true
			table.insert(files_table[2],extra)
		end
		files_table[2] = SortDirectory(files_table[2])
		if (p[2] > #files_table[2]) then
			p[2] = p[2] - 1
		end
	else
		sendResponsiveCommand("DELE",filename)
	end	
	need_refresh = true
end

-- Local recursive delete dir function
function DeleteDir(dir)
	files = System.listDirectory(dir)
	for z, file in pairs(files) do
		if (file.directory) then
			DeleteDir(dir.."/"..file.name)
		else
			System.deleteFile(dir.."/"..file.name)
		end
	end
	System.deleteDirectory(dir)
end

-- Server recursive delete dir function
function DeleteServerDir(dir)
	local old_dir = server_dir
	sendResponsiveCommand("CWD", server_dir .. dir .. "/")
	server_dir = getWorkingDirectory()
	enterPassiveMode()
	server_dir = server_dir .. "/"
	listServerDirectory()
	local local_table = {}
	for i, file in pairs(files_table[1]) do
		table.insert(local_table, file)
	end
	for i, file in pairs(local_table) do
		if file.directory and (not (file.name == "." or file.name == "..")) then
			DeleteServerDir(file.name)
		else
			DeleteFile(file.name, 1)
		end
	end
	sendResponsiveCommand("CWD", old_dir)
	sendResponsiveCommand("RMD", dir)
end

-- Delete dir function
function DeleteDirectory(filename, mode)
	if mode == 2 then
		DeleteDir(client_dir..filename)
		while (#files_table[2] > 0) do
			table.remove(files_table[2])
		end
		files_table[2] = System.listDirectory(client_dir)
		if System.currentDirectory() ~= "/" then
			local extra = {}
			extra.name = ".."
			extra.size = 0
			extra.directory = true
			table.insert(files_table[2],extra)
		end
		files_table[2] = SortDirectory(files_table[2])
		if (p[2] > #files_table[2]) then
			p[2] = p[2] - 1
		end
	else
		DeleteServerDir(filename)
		server_dir = getWorkingDirectory()
		enterPassiveMode()
		listServerDirectory()
	end	
	need_refresh = true
end

-- Top screen UI
function drawUI()
	if need_refresh then
		i = 0
		while i < 2 do
			Screen.refresh()
			Screen.clear(TOP_SCREEN)
			Screen.fillRect(0,399,0,15,Color.new(255,255,0), TOP_SCREEN)
			Screen.debugPrint(2,2,server_dir, Color.new(255,0,0),TOP_SCREEN)
			Screen.drawLine(200,200,0,239,menu_color, TOP_SCREEN)
			Screen.debugPrint(202,2,client_dir, Color.new(255,0,0),TOP_SCREEN)
			FileLister(2)
			FileLister(1)
			Screen.flip()
			Screen.waitVblankStart()
			i = i + 1
		end
		need_refresh = false
	end
end

-- CODE STARTS HERE
local j = 1
local voices = {"IP: " .. ip, "Port: " .. port, "Username: " .. user, "Password: " .. pass, "TLS: ON", "Connect"}
while true do
	pad = Controls.read()
	Screen.refresh()
	Screen.clear(BOTTOM_SCREEN)
	Screen.clear(TOP_SCREEN)
	Screen.debugPrint(3, 3, "FileKong v.0.1 - Config", selected_color, BOTTOM_SCREEN)
	for i, voice in pairs(voices) do
		if i == j then
			Screen.debugPrint(3, 53 + (i-1) * 15, voice, selected_color, BOTTOM_SCREEN)
		else
			Screen.debugPrint(3, 53 + (i-1) * 15, voice, menu_color, BOTTOM_SCREEN)
		end
	end
	if Controls.check(pad, KEY_DUP) and not Controls.check(oldpad, KEY_DUP) then
		j = j - 1
		if j < 1 then
			j = #voices
		end
	elseif Controls.check(pad, KEY_DDOWN) and not Controls.check(oldpad, KEY_DDOWN) then
		j = j + 1
		if j > #voices then
			j = 1
		end
	elseif Controls.check(pad, KEY_A) and not Controls.check(oldpad, KEY_A) then
		if j == #voices then
			break
		elseif j == #voices - 1 then
			tls = not tls
			if tls then
				voices[#voices - 1] = "TLS: ON"
			else
				voices[#voices - 1] = "TLS: OFF"
			end
		else
			new_val = System.startKeyboard("")
			if j == 1 then
				t = "IP: "
				ip = new_val
			elseif j == 2 then
				t = "Port: "
				port = math.tointeger(tonumber(new_val))
			elseif j == 3 then
				t = "Username: "
				user = new_val
			else
				t = "Password: "
				pass = new_val
			end
			voices[j] = t .. new_val
		end
	elseif Controls.check(pad, KEY_START) then
		System.exit()
	end
	Screen.waitVblankStart()
	Screen.flip()
	oldpad = pad
end
cns = Console.new(BOTTOM_SCREEN)
while not Network.isWifiEnabled() do
	Screen.refresh()
	Screen.debugPrint(1,2,"Please enable WiFi...",menu_color,BOTTOM_SCREEN)
	Screen.waitVblankStart()
	Screen.flip()
end
Socket.init()
consoleWrite("FileKong v.0.1 - Debug Console\n")
consoleWrite("Client has IP " .. Network.getIPAddress().."\n")
estabilishConnection(ip, port, user, pass)
server_dir = getWorkingDirectory()
sendResponsiveCommand("TYPE", "I")
enterPassiveMode()
listServerDirectory()
files_table[2] = SortDirectory(System.listDirectory("/"))
while true do
	pad = Controls.read()
	Screen.refresh()
	drawUI()
	Console.show(cns)
	Screen.waitVblankStart()
	Screen.flip()
	if Controls.check(pad, KEY_START) then
		termServer()
		Socket.term()
		Console.destroy(cns)
		System.exit()
	elseif Controls.check(pad,KEY_DUP) and not Controls.check(oldpad,KEY_DUP) then
		need_refresh = true
		p[mode] = p[mode] - 1
		if (p[mode] >= 15) then
			master_index[mode] = p[mode] - 14
		end
	elseif Controls.check(pad,KEY_DDOWN) and not Controls.check(oldpad,KEY_DDOWN) then
		need_refresh = true
		p[mode] = p[mode] + 1
		if (p[mode] >= 16) then
			master_index[mode] = p[mode] - 14
		end
	elseif Controls.check(pad, KEY_X) and not Controls.check(oldpad, KEY_X) then
		if files_table[mode][p[mode]].directory then
			DeleteDirectory(files_table[mode][p[mode]].name,mode)
		else
			DeleteFile(files_table[mode][p[mode]].name,mode)
			if mode == 1 then
				enterPassiveMode()
				listServerDirectory()
			end
		end
	elseif Controls.check(pad, KEY_A) and not Controls.check(oldpad, KEY_A) then
		if files_table[mode][p[mode]].directory then
			OpenDirectory(files_table[mode][p[mode]].name,mode)
		else
			if mode == 1 then
				retrieveFile(files_table[mode][p[mode]].name)
			else
				storeFile(files_table[mode][p[mode]].name)
			end
		end
	elseif Controls.check(pad,KEY_DLEFT) and not Controls.check(oldpad,KEY_DLEFT) then
		mode = 1
	elseif Controls.check(pad,KEY_DRIGHT) and not Controls.check(oldpad,KEY_DRIGHT) then
		mode = 2
	elseif Controls.check(pad,KEY_SELECT) and not Controls.check(oldpad,KEY_SELECT) then
		System.takeScreenshot("/filekong.jpg",true)
	end
	if (p[mode] < 1) then
		p[mode] = #files_table[mode]
		if (p[mode] >= 16) then
			master_index[mode] = p[mode] - 14
		end
	elseif (p[mode] > #files_table[mode]) then
		master_index[mode] = 0
		p[mode] = 1
	end
	oldpad = pad
end