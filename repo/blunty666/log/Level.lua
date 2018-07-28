package = "blunty666.log"

class = "Level"

local LEVELS = {
	"SEVERE",
	"WARNING",
	"INFO",
	"CONFIG",
	"FINE",
	"FINER",
	"FINEST",
}

static_method.fromIndex = function(index)
	return LEVELS[index]
end

for levelIndex, levelString in ipairs(LEVELS) do
	static_variable[levelString] = levelIndex
end
