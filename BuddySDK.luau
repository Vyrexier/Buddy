local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local SDK = {}
SDK.__index = SDK

local InstanceCache = {}
local ActiveToolCategories = {}

SDK.Permission = {
	Read = 0,
	Safe = 1,
	Restricted = 2,
	Dangerous = 3,
}

local CurrentCheckpoint = game

local function GetTimeStamp()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function ResolvePath(path)
	local Current = game
	for name in string.gmatch(path, "[^%.]+") do
		if name ~= "game" then
			Current = Current:FindFirstChild(name)
			if not Current then return nil end
		end
	end
	return Current
end

local function RecursiveSearch(root, name, depth)
	if depth <= 0 then return nil end
	for _, child in root:GetChildren() do
		if child.Name == name then
			return HttpService:JSONEncode({
				Name = child.Name,
				ClassName = child.ClassName,
				Path = child:GetFullName(),
			})
		end
		local found = RecursiveSearch(child, name, depth - 1)
		if found then return found end
	end
	return "Instance not found: " .. name
end

local ToolCategories = {
	-- Roblox: Read-only information
	roblox_read = {
		"roblox_get_instances_in_radius",
		"roblox_get_timestamp",
		"roblox_find_instance",
		"roblox_search_instances",
		"roblox_set_checkpoint",
		"roblox_get_local_player",
		"roblox_list_children",
	},

	-- Roblox: Instance cache
	roblox_cache = {
		"roblox_cache_instance",
		"roblox_get_cached",
		"roblox_clear_cache",
		"roblox_list_cache",
	},

	-- Roblox: Interaction / simulation
	roblox_interaction = {
		"roblox_fire_click_detector",
		"roblox_fire_proximity_prompt",
		"roblox_fire_touch_interest",
	},

	-- Roblox: Code execution / inspection
	roblox_execution = {
		"roblox_execute_code",
		"roblox_decompile_script",
	},

	-- Executor filesystem
	filesystem = {
		"fs_read_file",
		"fs_write_file",
		"fs_append_file",
		"fs_delete_file",
		"fs_list_files",
		"fs_make_folder",
		"fs_delete_folder",
		"fs_is_file",
		"fs_is_folder",
		"fs_load_file",
		"fs_get_custom_asset",
	},
}

local Tools = {
	buddy_request_tools = {
		Permission = -1,

		Description = "Request tool categories needed for the current task. " ..
			"Call this FIRST before any task that needs tools. " ..
			"Pick only what you need. " ..
			"Available categories: " ..
			"roblox_read (find, search, list children, get player info, get instances in radius, get timestamp), " ..
			"roblox_cache (cache, retrieve, clear, list cached instances), " ..
			"roblox_interaction (fire click detector, proximity prompt, touch interest), " ..
			"roblox_execution (execute Luau code, decompile scripts), " ..
			"filesystem (read, write, append, delete files and folders).",

		Parameters = {
			type = "object",
			properties = {
				categories = {
					type = "array",
					items = {
						type = "string",
						enum = {
							"roblox_read",
							"roblox_cache",
							"roblox_interaction",
							"roblox_execution",
							"filesystem"
						}
					}
				}
			},
			required = {"categories"}
		},

		Function = function(args)
			local result = {}

			for _, category in ipairs(args.categories or {}) do
				if ToolCategories[category] then
					table.insert(result, category)
				end
			end

			if #result == 0 then
				return "No valid tool categories requested"
			end

			SDK.SetActiveToolCategories(result)

			return "Enabled tool categories: " .. table.concat(result, ", ")
		end
	},
	roblox_get_instances_in_radius = {
		Permission = SDK.Permission.Read,
		Description = "Get Roblox instances whose BaseParts are within a radius of a position",
		Parameters = {
			type = "object",
			properties = {
				position = {
					type = "object",
					description = "World position with X, Y, and Z coordinates",
					properties = {
						X = {
							type = "number",
							description = "X coordinate"
						},
						Y = {
							type = "number",
							description = "Y coordinate"
						},
						Z = {
							type = "number",
							description = "Z coordinate"
						}
					},
					required = {"X", "Y", "Z"}
				},
				radius = {
					type = "number",
					description = "Search radius in studs"
				},
				max_parts = {
					type = "number",
					description = "Maximum number of parts to return"
				}
			},
			required = {"position", "radius"}
		},
		Function = function(args)
			local position = Vector3.new(
				args.position.X,
				args.position.Y,
				args.position.Z
			)

			local radius = math.max(args.radius, 0)
			local maxParts = args.max_parts or 100

			local overlapParams = OverlapParams.new()
			overlapParams.MaxParts = maxParts

			local parts = workspace:GetPartBoundsInRadius(
				position,
				radius,
				overlapParams
			)

			local results = {}

			for _, part in ipairs(parts) do
				table.insert(results, {
					Name = part.Name,
					ClassName = part.ClassName,
					Path = part:GetFullName(),
					Position = {
						X = part.Position.X,
						Y = part.Position.Y,
						Z = part.Position.Z
					}
				})
			end

			if #results == 0 then
				return "No instances found within radius"
			end

			return HttpService:JSONEncode(results)
		end
	},
	roblox_get_timestamp = {
		Permission = SDK.Permission.Read,
		Description = "Get the current UTC timestamp in ISO 8601 format",
		Parameters = {
			type = "object",
			properties = {
				_placeholder = {
					type = "string",
					description = "Unused placeholder parameter"
				}
			},
			required = {}
		},
		Function = function()
			return GetTimeStamp()
		end
	},
	roblox_execute_code = {
		Permission = SDK.Permission.Dangerous,
		Description = "Execute Luau code locally in Roblox",
		Parameters = {
			type = "object",
			properties = {
				code = {
					type = "string",
					description = "Luau code to execute"
				}
			},
			required = {"code"}
		},
		Function = function(args)
			local fn, err = loadstring(args.code)
			if not fn then return "Syntax Error: " .. err end
			local ok, result = pcall(fn)
			if not ok then return "Runtime Error: " .. result end
			return tostring(result) or "Executed successfully"
		end
	},

	roblox_find_instance = {
		Permission = SDK.Permission.Read,
		Description = "Recursively find a Roblox Instance by name from a root path with depth limit",
		Parameters = {
			type = "object",
			properties = {
				root = {
					type = "string",
					description = "Starting Instance path. Example: Workspace or Players.LocalPlayer.PlayerGui"
				},
				name = {
					type = "string",
					description = "Instance name to search for"
				},
				depth = {
					type = "number",
					description = "Maximum recursive search depth"
				}
			},
			required = {"root", "name"}
		},
		Function = function(args)
			local root = ResolvePath(args.root) or CurrentCheckpoint
			return RecursiveSearch(root, args.name, args.depth or 3)
		end
	},
	
	roblox_search_instances = {
		Permission = SDK.Permission.Read,
		Description = "Search instances by name or ClassName recursively from a root path",
		Parameters = {
			type = "object",
			properties = {
				root = {
					type = "string",
					description = "Root path to search from"
				},
				name = {
					type = "string",
					description = "Instance name to match (optional)"
				},
				class_name = {
					type = "string",
					description = "ClassName to match e.g. Part, Script, RemoteEvent (optional)"
				},
				depth = {
					type = "number",
					description = "Max search depth"
				},
				limit = {
					type = "number",
					description = "Max results to return"
				}
			},
			required = {"root"}
		},
		Function = function(args)
			local root = ResolvePath(args.root)
			if not root then return "Root not found: " .. args.root end

			local results = {}
			local limit = args.limit or 20

			local function Search(instance, depth)
				if depth <= 0 or #results >= limit then return end
				for _, child in instance:GetChildren() do
					local matchName = not args.name or child.Name == args.name
					local matchClass = not args.class_name or child.ClassName == args.class_name
					if matchName and matchClass then
						table.insert(results, {
							Name = child.Name,
							ClassName = child.ClassName,
							Path = child:GetFullName()
						})
					end
					Search(child, depth - 1)
				end
			end

			Search(root, args.depth or 5)

			if #results == 0 then return "No instances found" end
			return HttpService:JSONEncode(results)
		end
	},

	roblox_set_checkpoint = {
		Permission = SDK.Permission.Read,
		Description = "Set the current search checkpoint to a Roblox Instance path",
		Parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Instance path to set as checkpoint"
				}
			},
			required = {"path"}
		},
		Function = function(args)
			local instance = ResolvePath(args.path)
			if not instance then return "Instance not found: " .. args.path end
			CurrentCheckpoint = instance
			return "Checkpoint set: " .. instance:GetFullName()
		end
	},

	roblox_get_local_player = {
		Permission = SDK.Permission.Read,
		Description = "Get information about the local player including character, health, and position",
		Parameters = {
			type = "object",
			properties = {
				include_character = {
					type = "boolean",
					description = "Include character information"
				}
			},
			required = {}
		},
		Function = function(args)
			local Player = Players.LocalPlayer
			if not Player then return "LocalPlayer not available" end

			local Data = {
				Name = Player.Name,
				DisplayName = Player.DisplayName,
				UserId = Player.UserId,
				Path = Player:GetFullName(),
			}

			if args.include_character then
				local Char = Player.Character
				if Char then
					Data.Character = { Name = Char.Name, Path = Char:GetFullName() }
					local Humanoid = Char:FindFirstChildOfClass("Humanoid")
					local Root = Char:FindFirstChild("HumanoidRootPart")
					if Humanoid then
						Data.Character.Humanoid = {
							Health = Humanoid.Health,
							MaxHealth = Humanoid.MaxHealth
						}
					end
					if Root then
						Data.Character.Position = {
							X = Root.Position.X,
							Y = Root.Position.Y,
							Z = Root.Position.Z
						}
					end
				end
			end

			return HttpService:JSONEncode(Data)
		end
	},

	roblox_list_children = {
		Permission = SDK.Permission.Read,
		Description = "List all children of a Roblox Instance by path",
		Parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Instance path to list children from"
				}
			},
			required = {"path"}
		},
		Function = function(args)
			local instance = ResolvePath(args.path)
			if not instance then return "Instance not found: " .. args.path end
			local result = {}
			for _, child in instance:GetChildren() do
				table.insert(result, child.ClassName .. " " .. child.Name)
			end
			return #result > 0 and table.concat(result, "\n") or "No children found"
		end
	},
	roblox_cache_instance = {
		Permission = SDK.Permission.Read,
		Description = "Save a Roblox Instance into cache with a key and description for later use",
		Parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Instance path to cache"
				},
				key = {
					type = "string",
					description = "Key name to store the instance under"
				},
				description = {
					type = "string",
					description = "Your own note about what this instance is or why you saved it"
				}
			},
			required = {"path", "key"}
		},
		Function = function(args)
			local instance = ResolvePath(args.path)
			if not instance then return "Instance not found: " .. args.path end
			InstanceCache[args.key] = {
				Instance = instance,
				Path = instance:GetFullName(),
				Description = args.description or ""
			}
			return "Cached: " .. args.key .. " → " .. instance:GetFullName()
		end
	},

	roblox_get_cached = {
		Permission = SDK.Permission.Read,
		Description = "Get a cached Roblox Instance by key and return its info",
		Parameters = {
			type = "object",
			properties = {
				key = {
					type = "string",
					description = "Cache key to retrieve"
				}
			},
			required = {"key"}
		},
		Function = function(args)
			local cached = InstanceCache[args.key]
			if not cached then return "No cache found for key: " .. args.key end
			local instance = cached.Instance
			if not instance or not instance.Parent then
				InstanceCache[args.key] = nil
				return "Cached instance no longer exists: " .. args.key
			end
			return HttpService:JSONEncode({
				Key = args.key,
				Path = instance:GetFullName(),
				ClassName = instance.ClassName,
				Name = instance.Name,
				Description = cached.Description
			})
		end
	},

	roblox_clear_cache = {
		Permission = SDK.Permission.Read,
		Description = "Clear a specific cache key or all cached instances",
		Parameters = {
			type = "object",
			properties = {
				key = {
					type = "string",
					description = "Key to clear. Leave empty to clear all"
				}
			},
			required = {}
		},
		Function = function(args)
			if args.key and args.key ~= "" then
				if not InstanceCache[args.key] then
					return "Key not found: " .. args.key
				end
				InstanceCache[args.key] = nil
				return "Cleared: " .. args.key
			end
			local count = 0
			for _ in pairs(InstanceCache) do count += 1 end
			InstanceCache = {}
			return "Cleared all cache (" .. count .. " entries)"
		end
	},

	roblox_list_cache = {
		Permission = SDK.Permission.Read,
		Description = "List all currently cached instances with their keys and descriptions",
		Parameters = {
			type = "object",
			properties = {
				_placeholder = {
					type = "string",
					description = "unused"
				}
			},
			required = {}
		},
		Function = function(args)
			local entries = {}
			for key, data in pairs(InstanceCache) do
				local alive = data.Instance and data.Instance.Parent ~= nil
				table.insert(entries, {
					Key = key,
					Path = data.Path,
					Description = data.Description,
					Alive = alive
				})
			end
			if #entries == 0 then return "Cache is empty" end
			return HttpService:JSONEncode(entries)
		end
	},
	roblox_fire_click_detector = {
		Permission = SDK.Permission.Restricted,
		Description = "Trigger a ClickDetector event on an instance found by path",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Path to the ClickDetector instance" },
				distance = { type = "number", description = "Simulated click distance. Default infinite" },
				event = { type = "string", description = "Event name: MouseClick, RightMouseClick, MouseHoverEnter, MouseHoverLeave" }
			},
			required = {"path"}
		},
		Function = function(args)
			local inst = ResolvePath(args.path)
			if not inst then return "Instance not found: " .. args.path end
			fireclickdetector(inst, args.distance or 0, args.event or "MouseClick")
			return "Fired ClickDetector: " .. args.path
		end
	},

	roblox_fire_proximity_prompt = {
		Permission = SDK.Permission.Restricted,
		Description = "Trigger a ProximityPrompt instantly, bypassing HoldDuration and distance",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Path to the ProximityPrompt instance" }
			},
			required = {"path"}
		},
		Function = function(args)
			local inst = ResolvePath(args.path)
			if not inst then return "Instance not found: " .. args.path end
			fireproximityprompt(inst)
			return "Fired ProximityPrompt: " .. args.path
		end
	},

	roblox_fire_touch_interest = {
		Permission = SDK.Permission.Restricted,

		Description = "Simulate a touch event between two BaseParts. Use toggle 1 to begin touching and 0 to end touching.",

		Parameters = {
			type = "object",
			properties = {
				part1 = {
					type = "string",
					description = "Path to the initiating BasePart"
				},

				part2 = {
					type = "string",
					description = "Path to the BasePart to be touched"
				},

				toggle = {
					type = "number",
					enum = {0, 1},
					description = "Touch state: 1 = touch start, 0 = touch end"
				}
			},

			required = {
				"part1",
				"part2",
				"toggle"
			}
		},

		Function = function(args)
			local p1 = ResolvePath(args.part1)
			local p2 = ResolvePath(args.part2)

			if not p1 then
				return "Part1 not found: " .. args.part1
			end

			if not p2 then
				return "Part2 not found: " .. args.part2
			end

			if typeof(args.toggle) ~= "number" then
				return "Invalid toggle: expected 0 or 1"
			end

			firetouchinterest(p1, p2, args.toggle)

			return string.format(
				"Fired touch: %s -> %s (toggle=%d)",
				args.part1,
				args.part2,
				args.toggle
			)
		end
	},

	-- Filesystem (Dangerous)
	fs_read_file = {
		Permission = SDK.Permission.Dangerous,
		Description = "Read content of a file from executor filesystem",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path to read" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, result = pcall(readfile, args.path)
			if not ok then return "Error: " .. result end
			return result
		end
	},

	fs_write_file = {
		Permission = SDK.Permission.Dangerous,
		Description = "Write content to a file in executor filesystem",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path to write" },
				content = { type = "string", description = "Content to write" }
			},
			required = {"path", "content"}
		},
		Function = function(args)
			local ok, err = pcall(writefile, args.path, args.content)
			if not ok then return "Error: " .. err end
			return "Written: " .. args.path
		end
	},

	fs_append_file = {
		Permission = SDK.Permission.Dangerous,
		Description = "Append content to an existing file",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path" },
				content = { type = "string", description = "Content to append" }
			},
			required = {"path", "content"}
		},
		Function = function(args)
			local ok, err = pcall(appendfile, args.path, args.content)
			if not ok then return "Error: " .. err end
			return "Appended: " .. args.path
		end
	},

	fs_delete_file = {
		Permission = SDK.Permission.Dangerous,
		Description = "Delete a file from executor filesystem",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path to delete" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, err = pcall(delfile, args.path)
			if not ok then return "Error: " .. err end
			return "Deleted: " .. args.path
		end
	},

	fs_list_files = {
		Permission = SDK.Permission.Dangerous,
		Description = "List all files and folders in a directory",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Folder path to list" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, result = pcall(listfiles, args.path)
			if not ok then return "Error: " .. result end
			return HttpService:JSONEncode(result)
		end
	},

	fs_make_folder = {
		Permission = SDK.Permission.Dangerous,
		Description = "Create a new folder in executor filesystem",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Folder path to create" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, err = pcall(makefolder, args.path)
			if not ok then return "Error: " .. err end
			return "Created folder: " .. args.path
		end
	},

	fs_delete_folder = {
		Permission = SDK.Permission.Dangerous,
		Description = "Delete a folder from executor filesystem",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Folder path to delete" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, err = pcall(delfolder, args.path)
			if not ok then return "Error: " .. err end
			return "Deleted folder: " .. args.path
		end
	},

	fs_is_file = {
		Permission = SDK.Permission.Dangerous,
		Description = "Check if a file exists",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path to check" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, result = pcall(isfile, args.path)
			if not ok then return "Error: " .. result end
			return tostring(result)
		end
	},

	fs_is_folder = {
		Permission = SDK.Permission.Dangerous,
		Description = "Check if a folder exists",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "Folder path to check" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, result = pcall(isfolder, args.path)
			if not ok then return "Error: " .. result end
			return tostring(result)
		end
	},

	fs_load_file = {
		Permission = SDK.Permission.Dangerous,
		Description = "Load and execute a Lua file from executor filesystem",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path to load and execute" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, fn, err = pcall(loadfile, args.path)
			if not ok then return "Error: " .. fn end
			if not fn then return "Load error: " .. tostring(err) end
			local ok2, result = pcall(fn)
			if not ok2 then return "Runtime Error: " .. result end
			return tostring(result) or "Executed: " .. args.path
		end
	},

	fs_get_custom_asset = {
		Permission = SDK.Permission.Dangerous,
		Description = "Get a rbxasset:// content ID from a file in executor filesystem for use in Roblox APIs",
		Parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File path to get asset URL for" }
			},
			required = {"path"}
		},
		Function = function(args)
			local ok, result = pcall(getcustomasset, args.path)
			if not ok then return "Error: " .. result end
			return result
		end
	},
	roblox_decompile_script = {
		Permission = SDK.Permission.Restricted,
		Description = "Decompile a Script, LocalScript, or ModuleScript into readable Lua source code",
		Parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Path to the script instance"
				},
				cache_key = {
					type = "string",
					description = "Cache key of a previously cached script instance"
				}
			},
			required = {}
		},
		Function = function(args)
			if not decompile then return "decompile() not supported by this executor" end

			local inst

			if args.cache_key and InstanceCache[args.cache_key] then
				inst = InstanceCache[args.cache_key].Instance
			else
				inst = ResolvePath(args.path)
			end

			if not inst then return "Instance not found" end

			local ok, result = pcall(decompile, inst)
			if not ok then return "Decompile error: " .. result end
			return result or "-- No source recovered"
		end
	},
}

function SDK.GetToolList(permissionLevel)
	local result = {}

	-- Always available: meta-tool
	local requestTool = Tools.buddy_request_tools

	if requestTool and requestTool.Permission <= permissionLevel then
		table.insert(result, {
			type = "function",
			["function"] = {
				name = "buddy_request_tools",
				description = requestTool.Description,
				parameters = requestTool.Parameters
			}
		})
	end

	for category in pairs(ActiveToolCategories) do
		for _, name in ipairs(ToolCategories[category]) do
			local data = Tools[name]

			if data and data.Permission <= permissionLevel then
				table.insert(result, {
					type = "function",
					["function"] = {
						name = name,
						description = data.Description,
						parameters = data.Parameters
					}
				})
			end
		end
	end

	return result
end

function SDK.GetToolSummary(permissionLevel)
	local available = {}
	local locked = {}

	for name, data in pairs(Tools) do
		if name ~= "buddy_request_tools" then
			if data.Permission <= permissionLevel then
				table.insert(available, name)
			else
				table.insert(locked, name)
			end
		end
	end
	
	table.sort(available)
	table.sort(locked)

	return string.format(
		"Available tools (%d): %s\nLocked tools (%d): %s",
		#available,
		table.concat(available, ", "),
		#locked,
		table.concat(locked, ", ")
	)
end

function SDK.HandleToolCall(toolCall, permissionLevel)
	local name = toolCall["function"].name
	local tool = Tools[name]

	if not tool then
		return "Unknown tool: " .. name
	end

	if tool.Permission > permissionLevel then
		return "Permission denied: " .. name .. " requires level " .. tool.Permission
	end

	local ok, args = pcall(HttpService.JSONDecode, HttpService, toolCall["function"].arguments)
	if not ok then return "Invalid arguments" end

	local success, result = pcall(tool.Function, args)
	if not success then return "Tool Error: " .. tostring(result) end

	return tostring(result) .. "\nTimestamp: " .. GetTimeStamp()
end

function SDK.GetToolDocs(permissionLevel)
	local docs = {}
	for name, data in pairs(Tools) do
		local locked = data.Permission > permissionLevel
		local entry = {
			Name = name,
			Description = data.Description,
			Permission = data.Permission,
			Locked = locked,
			Parameters = {}
		}
		if data.Parameters and data.Parameters.properties then
			for paramName, paramData in pairs(data.Parameters.properties) do
				table.insert(entry.Parameters, {
					Name = paramName,
					Type = paramData.type,
					Description = paramData.description
				})
			end
		end
		table.insert(docs, entry)
	end
	table.sort(docs, function(a, b)
		if a.Permission ~= b.Permission then
			return a.Permission < b.Permission
		end
		return a.Name < b.Name
	end)
	return docs
end

function SDK.GetToolsByCategories(permissionLevel, categories)
	local selected = {}

	for _, category in ipairs(categories) do
		local tools = ToolCategories[category]

		if tools then
			for _, toolName in ipairs(tools) do
				selected[toolName] = true
			end
		end
	end

	local result = {}

	for name, data in pairs(Tools) do
		if selected[name] and data.Permission <= permissionLevel then
			table.insert(result, {
				type = "function",
				["function"] = {
					name = name,
					description = data.Description,
					parameters = data.Parameters
				}
			})
		end
	end

	return result
end

function SDK.SetActiveToolCategories(categories)
	ActiveToolCategories = {}

	for _, category in ipairs(categories) do
		if ToolCategories[category] then
			ActiveToolCategories[category] = true
		end
	end
end

function SDK.GetActiveToolCategories()
	return ActiveToolCategories
end

function SDK.ClearActiveToolCategories()
	ActiveToolCategories = {}
end

return SDK
