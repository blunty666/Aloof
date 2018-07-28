local ALIASES = {
	static_variable = "static_variables",
	static_getter = "static_getters",
	static_setter = "static_setters",
	static_method = "static_methods",

	variable = "variables",
	getter = "getters",
	setter = "setters",
	method = "methods",
}
local METHOD_DUPLICATES = {"static_variables", "static_getters", "static_setters", "static_methods", "variables", "getters", "setters", "methods"}
local STATIC_DUPLICATES = {"static_methods", "variables", "getters", "setters", "methods"}
local INSTANCE_DUPLICATES = {"static_variables", "static_getters", "static_setters", "static_methods", "methods"}

local NIL, environmentFrom, mainClassEnvironment, mainEnvironment = nil, nil, nil, nil -- set through init function
local propertyFrom, metatables, _checkers, checkers = setmetatable({}, {__mode = "k"}), {}, {}, {}

--===== UTILS =====--
local function invalidInterfaceProperty(property)
	return false, "cannot define property '"..property.."' in interface"
end

local function typeError(expectedType, actualType, additionalInfo)
	local exception = "expected <"..expectedType..">, got: <"..actualType..">"
	if additionalInfo then
		exception = exception.." - "..additionalInfo
	end
	return exception
end

local function checkArray(array, expectedTypeChecker)
	if type(array) ~= "table" then return false, typeError("table", type(array)) end
	local output = {}
	for index, value in ipairs(array) do
		local ok, _value = expectedTypeChecker(value)
		if ok then
			output[index] = _value
		else
			return false, "invalid value at index "..tostring(index).." - ".._value
		end
	end
	return true, output
end

local function checkTable(table, expectedKeyTypeChecker, expectedValueTypeChecker)
	if type(table) ~= "table" then return false, typeError("table", type(table)) end
	local output = {}
	for key, value in pairs(table) do
		local ok, _key = expectedKeyTypeChecker(key)
		if not ok then return false, "invalid key "..tostring(key).." - ".._key end
		local ok, _value = expectedValueTypeChecker(value)
		if not ok then return false, "invalid value at key "..tostring(key).." - ".._value end
		output[_key] = _value
	end
	return true, output
end

local function splitFullName(full_name)
	return full_name:match("(.*)%.") or "", full_name:match("([^%.]*)$")
end

local propertyProperties = {
	imports = {
		metatableType = "array",
		valueType = "imports_string",
		duplicates = {},
	},
	static_methods = {
		metatableType = "stringIndexedTable",
		valueType = "function",
		duplicates = METHOD_DUPLICATES,
	},
	methods = {
		metatableType = "stringIndexedTable",
		valueType = "function",
		duplicates = METHOD_DUPLICATES,
	},
	implements = {
		metatableType = "array",
		valueType = "full_interface_string",
		duplicates = {},
	},
	static_variables = {
		metatableType = "stringIndexedTable",
		valueType = "any",
		duplicates = STATIC_DUPLICATES,
	},
	static_getters = {
		metatableType = "stringIndexedTable",
		valueType = "function",
		duplicates = STATIC_DUPLICATES,
	},
	static_setters = {
		metatableType = "stringIndexedTable",
		valueType = "function",
		duplicates = STATIC_DUPLICATES,
	},
	variables = {
		metatableType = "stringIndexedTable",
		valueType = "any",
		duplicates = INSTANCE_DUPLICATES,
	},
	getters = {
		metatableType = "stringIndexedTable",
		valueType = "function",
		duplicates = INSTANCE_DUPLICATES,
	},
	setters = {
		metatableType = "stringIndexedTable",
		valueType = "function",
		duplicates = INSTANCE_DUPLICATES,
	},
}

local function newEnvironment()
	local environment = {
		-- class + interface
		package = "",
		imports = {},
		extends = false,
		static_methods = {},
		methods = {},

		-- class
		class = false,
		implements = {},
		static_variables = {},
		static_getters = {},
		static_setters = {},
		variables = {},
		getters = {},
		setters = {},
		constructor = false,

		-- interface
		interface = false,
	}

	-- set up tracking table
	local tracking = {}
	for propertyName in pairs(environment) do
		tracking[propertyName] = false
	end

	-- set up property proxies
	local proxies = {}
	for propertyName, property in pairs(environment) do
		local propProps = propertyProperties[propertyName]
		if propProps then
			local proxy = setmetatable({}, metatables[propProps.metatableType])
			local propertyInfo = {
				property = property,
				propertyName = propertyName,
				valueType = propProps.valueType,
				duplicates = propProps.duplicates,
			}
			environmentFrom[proxy], propertyFrom[proxy] = environment, propertyInfo
			proxies[propertyName] = proxy
		end
	end

	environment.tracking = tracking
	environment.proxies = proxies

	return environment
end

local function checkPropertyArray(value, arrayType, duplicates, propertyName, environment)
	-- check is correct array type
	local ok, _value = _checkers[arrayType](value)
	if not ok then return false, _value end
	-- check for duplicates in other properties
	for _, object in ipairs(_value) do
		for _, objectType in ipairs(duplicates) do
			for _, otherObject in ipairs(environment[objectType]) do
				if object == otherObject then
					return false, "cannot set '"..object.."' in '"..propertyName.."', it is already defined in "..objectType
				end
			end
		end
	end
	-- copy into environment property
	local property = environment[propertyName]
	for objectIndex, objectValue in ipairs(_value) do
		property[objectIndex] = objectValue
	end
	return true, property
end

local function checkPropertyTable(value, tableType, duplicates, propertyName, environment)
	-- check is correct table type
	local ok, _value = _checkers[tableType](value)
	if not ok then return false, _value end
	-- check for duplicates in other properties
	for objectKey in pairs(_value) do
		for _, objectType in ipairs(duplicates) do
			if environment[objectType][objectKey] then
				return false, "cannot set '"..objectKey.."' for '"..propertyName.."', it is already defined in "..objectType
			end
		end
	end
	-- copy into environment property
	local property = environment[propertyName]
	for objectKey, objectValue in pairs(_value) do
		property[objectKey] = objectValue
	end
	return true, property
end

--===== METATABLES =====--
metatables.environment = {
	__index = function(proxy, alias)
		local key = ALIASES[alias] or alias
		return environmentFrom[proxy].proxies[key] or environmentFrom[proxy][key] or mainClassEnvironment[key] or mainEnvironment[key]
	end,
	__newindex = function(proxy, alias, value)
		local environment = environmentFrom[proxy]
		local key = ALIASES[alias] or alias
		if environment[key] ~= nil then
			local tracking = environment.tracking
			if tracking then
				-- check if property has already been set
				if tracking[key] == true then
					local err = "class property '"..alias.."' has already been set"
					if key ~= alias then err = err.." through property '"..key.."'" end
					return error(err)
				end

				-- check if property value is valid
				local checker = checkers[key]
				local ok, _value = checker(value, environment, tracking)
				if not ok then return error("error setting property '"..alias.."': ".._value) end

				-- set property value in environment and add to tracked properties
				environment[key], tracking[key] = _value, true
				return
			end
			return error("attempt to set class property '"..tostring(alias).."' after class loading has completed")
		elseif alias == "_ENV" then
			environment._ENV = value
			return
		end
		return error("attempt to set non-local variable '"..tostring(alias).."'")
	end,
}
metatables.array = {
	__index = function(proxy, index)
		return propertyFrom[proxy].property[index]
	end,
	__newindex = function(proxy, index, value)
		local environment = environmentFrom[proxy]
		local tracking = environment.tracking
		if tracking then
			local propertyInfo = propertyFrom[proxy]
			local property = propertyInfo.property
			-- check index is valid type
			local ok, err = _checkers.index(index)
			if not ok then return false, err end
			-- check index is valid for property
			if index ~= #property + 1 then return error("expected index '"..tostring(#property + 1).."', got '"..tostring(index).."'") end
			-- check value is valid type
			local ok, err = _checkers[propertyInfo.valueType](value)
			if not ok then return false, err end
			-- check not already defined in property
			for _index, _value in ipairs(property) do
				if value == _value then return error("property value '"..value.."' is already defined at index '"..tostring(_index).."'") end
			end
			-- check not already defined in duplicates
			for _, objectType in ipairs(propertyInfo.duplicates) do
				for _, otherObject in ipairs(environment[objectType]) do
					if _value == otherObject then
						return error("cannot set '".._value.."' in '"..propertyInfo.propertyName.."', it is already defined in "..objectType)
					end
				end
			end
			-- add value to environment property
			table.insert(property, value)
			-- mark tracking as true
			tracking[propertyInfo.propertyName] = true
			return
		end
		return error("attempt to set class property '"..tostring("TEST").."' after class loading has completed")
	end,
}
metatables.stringIndexedTable = {
	__index = function(proxy, key)
		local value = propertyFrom[proxy].property[key]
		return (value == NIL and nil) or value
	end,
	__newindex = function(proxy, key, value)
		local environment = environmentFrom[proxy]
		local tracking = environment.tracking
		if tracking then
			local propertyInfo = propertyFrom[proxy]
			local property = propertyInfo.property
			-- check key is valid type
			local ok, err = _checkers.string(key)
			if not ok then return false, err end
			-- check value is valid type
			local ok, err = _checkers[propertyInfo.valueType](value)
			if not ok then return false, err end
			-- check not already defined in property
			for _key in pairs(property) do
				if key == _key then return error("property key '"..key.."' for '"..propertyInfo.propertyName.."' has already been defined") end
			end
			-- check not already defined in duplicates
			for _, objectType in ipairs(propertyInfo.duplicates) do
				for _key in pairs(environment[objectType]) do
					if _key == key then
						return error("cannot set '"..key.."' in '"..propertyInfo.propertyName.."', it is already defined in "..objectType)
					end
				end
			end
			-- add value to environment property
			if value == nil then value = NIL end
			property[key] = value
			-- mark tracking as true
			tracking[propertyInfo.propertyName] = true
			return
		end
		return error("attempt to set class property '"..tostring("TEST").."' after class loading has completed")
	end,
}

--===== INTERNAL CHECKERS =====--
_checkers.any = function(value)
	return true, value
end
_checkers.index = function(value)
	if type(value) ~= "number" then return false, typeError("number", type(value)) end
	if value < 1 or math.floor(value) ~= value then return false, typeError("non-negative integer", type(value), "got value "..tostring(value)) end
	return true, value
end
_checkers.string = function(value)
	if type(value) ~= "string" then return false, typeError("string", type(value)) end
	return true, value
end
_checkers.package_string = function(value)
	if type(value) ~= "string" then return false, typeError("string", type(value)) end
	local length = value:len()
	if length == 0 then return true, value end
	local sub_package_string, seek = nil, 0
	while seek <= length do
		sub_package_string, seek = value:match("([^.]*).-()", seek + 1)
		local ok, err = _checkers.sub_package_string(sub_package_string)
		if not ok then
			return false, typeError("string", type(value), tostring(value).." - "..err)
		end
	end
	return true, value
end
_checkers.sub_package_string = function(value)
	if type(value) ~= "string" then return false, typeError("string", type(value)) end
	if value:len() == 0 then return false, "zero length sub_package_string not allowed" end
	if value:match("[^%l%d_]") then return false, "only lowercase alphanumeric characters + underscores allowed in sub_package_string" end
	return true, value
end
_checkers.imports_array = function(value)
	return checkArray(value, _checkers.imports_string)
end
_checkers.string_array = function(value)
	return checkArray(value, _checkers.string)
end
_checkers.imports_string = function(value)
	if type(value) ~= "string" then return false, typeError("string", type(value)) end
	local package_string, name = splitFullName(value)
	local ok, err = _checkers.package_string(package_string)
	if not ok then
		return false, typeError("import_package_string", type(value), tostring(value).." - "..err)
	end
	if not (_checkers.short_class_string(name) or _checkers.short_interface_string(name) or name == "*") then
		local err = "expected class_name / interface_name / wildcard at end of imports_string"
		return false, typeError("string", type(value), tostring(value).." - "..err)
	end
	return true, value
end
_checkers.short_class_string = function(value)
	if type(value) ~= "string" then return false, typeError("string", type(value)) end
	if value:len() == 0 then return false, typeError("class_name", type(value), tostring(value).." - zero length class_name not allowed") end
	if value:find("[^%w_]") then return false, typeError("class_name", type(value), tostring(value).." - class_name must only contain alphanumeric characters + underscores") end
	if value:find("%u") ~= 1 then return false, typeError("class_name", type(value), tostring(value).." - class_name must start with capital letter") end
	if _checkers.short_interface_string(value) then return false, typeError("class_name", type(value), tostring(value).." - class_name cannot have the same format as interface_name") end
	return true, value
end
_checkers.full_class_string = function(value)
	if type(value) ~= "string" then return false, typeError("full_class_name", type(value), tostring(value)) end
	local package_string, class_name = splitFullName(value)
	local ok, err = _checkers.package_string(package_string)
	if not ok then
		return false, typeError("full_class_name", type(value), tostring(value).." - "..err)
	end
	local ok, err = _checkers.short_class_string(class_name)
	if not ok then
		return false, typeError("full_class_name", type(value), tostring(value).." - "..err)
	end
	return true, value
end
_checkers.short_interface_string = function(value)
	if type(value) ~= "string" then return false, typeError("interface_name", type(value), tostring(value)) end
	if value:len() < 1 then return false, typeError("interface_name", type(value), tostring(value).." - interface_name too short") end
	if value:find("[^%w_]") then return false, typeError("interface_name", type(value), tostring(value).." - interface_name must only contain alphanumeric characters + underscores") end
	if value:find("I") ~= 1 then return false, typeError("interface_name", type(value), tostring(value).." - interface_name must start with capital letter 'I'") end
	if value:find("%u", 2) ~= 2 then return false, typeError("interface_name", type(value), tostring(value).." - interface_name must start with capital letter 'I' then a capital letter") end
	return true, value
end
_checkers.full_interface_string = function(value)
	if type(value) ~= "string" then return false, typeError("full_interface_name", type(value), tostring(value)) end
	local package_string, interface_name = splitFullName(value)
	local ok, err = _checkers.package_string(package_string)
	if not ok then return false, err end
	local ok, err = _checkers.short_interface_string(interface_name)
	if not ok then return false, err end
	return true, value
end
_checkers.string_to_function_table = function(value)
	return checkTable(value, _checkers.string, _checkers["function"])
end
_checkers.implements_array = function(value)
	return checkArray(value, _checkers.full_interface_string)
end
_checkers.string_to_any_table = function(value)
	return checkTable(value, _checkers.string, _checkers.any)
end
_checkers["function"] = function(value)
	if type(value) ~= "function" then return false, typeError("function", type(value), tostring(value)) end
	return true, value
end

--===== MAIN CHECKERS =====--
-- class + interface
checkers.package = function(value, environment, tracking)
	return _checkers.package_string(value)
end
checkers.imports = function(value, environment, tracking)
	local valueType = type(value)
	if valueType == "table" then
		return checkPropertyArray(value, "imports_array", {}, "imports", environment)
	elseif valueType == "string" then
		local ok, _value = _checkers.imports_string(value)
		if not ok then return false, typeError("imports_string", type(value), _value) end
		table.insert(environment.imports, _value)
		return true, environment.imports
	end
	return false, typeError("imports_string_array or imports_string", valueType)
end
checkers.extends = function(value, environment, tracking)
	if tracking.class then
		return _checkers.full_class_string(value)
	elseif tracking.interface then
		return _checkers.full_interface_string(value)
	else
		return false, "must define class or interface first"
	end
end

checkers.static_methods = function(value, environment, tracking)
	if tracking.class then
		return checkPropertyTable(value, "string_to_function_table", METHOD_DUPLICATES, "static_methods", environment)
	elseif tracking.interface then
		return checkPropertyArray(value, "string_array", {"methods"}, "static_methods", environment)
	end
	return false, "must define class or interface first"
end
checkers.methods = function(value, environment, tracking)
	if tracking.class then
		return checkPropertyTable(value, "string_to_function_table", METHOD_DUPLICATES, "methods", environment)
	elseif tracking.interface then
		return checkPropertyArray(value, "string_array", {"static_methods"}, "methods", environment)
	end
	return false, "must define class or interface first"
end

-- class only
checkers.class = function(value, environment, tracking)
	if tracking.interface then return false, "cannot define class and interface in same file" end
	local ok, _value = _checkers.short_class_string(value)
	if not ok then return false, typeError("short_class_string", type(value), _value) end
	return true, _value
end
checkers.implements = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("implements") end
	if not tracking.class then return false, "must define class first" end
	local valueType = type(value)
	if valueType == "table" then
		return checkPropertyArray(value, "implements_array", {}, "implements", environment)
	elseif valueType == "string" then
		local ok, _value = _checkers.full_interface_string(value)
		if not ok then return false, _value end
		table.insert(environment.implements, _value)
		return true, environment.implements
	end
	return false, typeError("imports_string_array or imports_string", valueType)
end

checkers.static_variables = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("static_variables") end
	if not tracking.class then return false, "must define class first" end
	return checkPropertyTable(value, "string_to_any_table", STATIC_DUPLICATES, "static_variables", environment)
end
checkers.static_getters = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("static_getters") end
	if not tracking.class then return false, "must define class first" end
	return checkPropertyTable(value, "string_to_function_table", STATIC_DUPLICATES, "static_getters", environment)
end
checkers.static_setters = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("static_setters") end
	if not tracking.class then return false, "must define class first" end
	return checkPropertyTable(value, "string_to_function_table", STATIC_DUPLICATES, "static_setters", environment)
end

checkers.variables = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("variables") end
	if not tracking.class then return false, "must define class first" end
	return checkPropertyTable(value, "string_to_any_table", INSTANCE_DUPLICATES, "variables", environment)
end
checkers.getters = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("getters") end
	if not tracking.class then return false, "must define class first" end
	return checkPropertyTable(value, "string_to_function_table", INSTANCE_DUPLICATES, "getters", environment)
end
checkers.setters = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("setters") end
	if not tracking.class then return false, "must define class first" end
	return checkPropertyTable(value, "string_to_function_table", INSTANCE_DUPLICATES, "setters", environment)
end

checkers.constructor = function(value, environment, tracking)
	if tracking.interface then return invalidInterfaceProperty("constructor") end
	if not tracking.class then return false, "must define class first" end
	if type(value) ~= "function" then return false, typeError("function", type(value)) end
	return true, value
end

-- interface only
checkers.interface = function(value, environment, tracking)
	if tracking.class then return false, "cannot define class and interface in same file" end
	local ok, _value = _checkers.short_interface_string(value)
	if not ok then return false, typeError("short_interface_string", type(value), _value) end
	-- update static_methods
	local staticMethodsProxy = environment.proxies.static_methods
	setmetatable(staticMethodsProxy, metatables.array)
	propertyFrom[staticMethodsProxy].valueType = "string"
	propertyFrom[staticMethodsProxy].duplicates = {"methods"}
	-- update methods
	local methodsProxy = environment.proxies.methods
	setmetatable(methodsProxy, metatables.array)
	propertyFrom[methodsProxy].valueType = "string"
	propertyFrom[methodsProxy].duplicates = {"static_methods"}
	return true, _value
end

--===== EXTERNAL FUNCTIONS =====--
local function init(_NIL, _environmentFrom, _mainClassEnvironment, _mainEnvironment)
	NIL, environmentFrom, mainClassEnvironment, mainEnvironment = _NIL, _environmentFrom, _mainClassEnvironment, _mainEnvironment
end

local function new()
	local environment, proxy = newEnvironment(), setmetatable({NIL = NIL}, metatables.environment)
	environmentFrom[proxy] = environment
	return environment, proxy
end

local function check(environment, proxy)
	-- check for class
	if environment.class ~= false then
		if environment.extends == false then environment.extends = nil end
		if environment.constructor == false then
			local constructor
			if environment.extends then
				constructor = function(self, ...)
					self.super(...)
				end
			else
				constructor = function(self, ...)
				end
			end
			setfenv(constructor, proxy)
			environment.constructor = constructor
		end
		-- create live class data
		local class = {
			package = environment.package,
			imports = environment.imports,

			name = environment.class,
			extends = environment.extends,
			implements = environment.implements,

			static = {
				variables = environment.static_variables,
				getters = environment.static_getters,
				setters = environment.static_setters,
				methods = environment.static_methods,
			},

			instance = {
				variables = environment.variables,
				getters = environment.getters,
				setters = environment.setters,
				methods = environment.methods,
				constructor = environment.constructor,
			},

			extendedBy = {},
		}
		class.fullName = environment.class
		if environment.package ~= "" then
			class.fullName = environment.package.."."..class.fullName
		end
		return class, "class"
	elseif environment.interface ~= false then
		if environment.extends == false then environment.extends = nil end
			-- create live interface data
		local interface = {
			package = environment.package,
			imports = environment.imports,

			name = environment.interface,
			extends = environment.extends,

			static_methods = environment.static_methods,
			methods = environment.methods,

			extendedBy = {},
		}
		interface.fullName = environment.interface
		if environment.package ~= "" then
			interface.fullName = environment.package.."."..interface.fullName
		end
		return interface, "interface"
	end
	return false, "no class or interface defined"
end

local function clearTracking(environment)
	environment.tracking = nil
end

return {
	init = init,
	new = new,
	check = check,
	clearTracking = clearTracking,
}
