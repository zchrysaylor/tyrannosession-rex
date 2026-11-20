---Tyrannosessionl: a simple floating sessionizer for Rex.

---@class Tyrannosession.Options
---@field roots? string[] Directories to search for projects. Defaults to `{ "~/Code" }`.
---@field programs? string[][] One command per tab in a new session. Defaults to one interactive shell.
---@field shell? string The shell for new terminals. Defaults to `$SHELL`, then `/bin/sh`.
---@field executables? { fd?: string, fzf?: string } Where to find `fd` and `fzf` when Rex's PATH lacks them, e.g. `/opt/homebrew/bin/fzf`.
---@field bindings? { picker?: string|false, new_tab?: string[] } `picker` defaults to `ctrl+b>f`; `false` disables it.
---@field state_path? string Where session records are saved. Defaults to `$XDG_STATE_HOME/rex/tyrannosession.json`.
---@field max_depth? integer How deep `fd` searches below each root. Defaults to 1.

---@class Tyrannosession.Config
---@field script_path string This file, which the picker runs with `rex do`.
---@field roots string[]
---@field programs string[][]
---@field shell string
---@field max_depth integer
---@field state_path string
---@field executables { fd: string, fzf: string }

---@class Tyrannosession.Session
---@field session_id string
---@field window_id? string The tab to select, when one was just created.
---@field created boolean Whether a window was just created, so selection must wait for the app.

---@class Tyrannosession.Candidates
---@field paths string[] Every project directory found, roots included.
---@field fzf string

---@class Tyrannosession.ActionContext
---@field session_id? string
---@field block_id? string
---@field client_id? string

---@class Tyrannosession
local Tyrannosession = {}

local home = assert(os.getenv("HOME"), "HOME must be set")
local rex_cli = os.getenv("REX_BIN_DIR") and (os.getenv("REX_BIN_DIR") .. "/rex") or "rex"

---@type Tyrannosession.Config
local config

---Session records by session ID, or `nil` until loaded from disk.
---@type table<string, { cwd: string }>?
local records

---Expand a leading ~ and drop trailing slashes, which fd adds to directories.
---@param path string
local function absolute(path)
   assert(type(path) == "string", "Expected a path string")
   if path == "~" or path:sub(1, 2) == "~/" then
      path = home .. path:sub(2)
   end
   assert(path:sub(1, 1) == "/", "Path must be absolute: " .. path)
   return (path:gsub("(.)/+$", "%1"))
end

---Abbreviate the home directory to ~ for display.
---@param path string
local function tildify(path)
   if path == home or path:sub(1, #home + 1) == home .. "/" then
      return "~" .. path:sub(#home + 1)
   end
   return path
end

---@param path string
---@return boolean
local function is_directory(path)
   return assert(rex.exec({ "/bin/test", "-d", path })).ok
end

---Missing state is normal; unreadable or malformed state must not be overwritten.
---@return table<string, { cwd: string }>
local function load_records()
   if records then
      return records
   end
   local file, err = io.open(config.state_path, "r")
   if not file then
      -- Rex's Lua reports generic code 1 for OS errors instead of POSIX ENOENT, so match the message.
      assert(err:match("no such file or directory$"), "Cannot read project-session state: " .. err)
      records = {}
      return records
   end
   local contents = assert(file:read("*a"))
   assert(file:close())
   local saved = assert(rex.json.decode(contents))
   assert(type(saved) == "table" and saved.version == 1 and type(saved.sessions) == "table", "Invalid project-session state: " .. config.state_path)
   records = saved.sessions
   return records
end

---Write beside the destination, then atomically replace it. Never evaluate state as Lua.
---Nothing between open and rename yields, so a fixed temporary name cannot be shared.
local function save_records()
   local parent = config.state_path:match("^(.+)/") or "/"
   local made = assert(rex.exec({ "/bin/mkdir", "-p", parent }))
   assert(made.ok, "Cannot create project-session state directory: " .. made.stderr)
   local encoded = assert(rex.json.encode({ version = 1, sessions = records }))
   local temporary = config.state_path .. ".tmp"
   local file = assert(io.open(temporary, "w"))
   assert(file:write(encoded, "\n"))
   assert(file:close())
   assert(os.rename(temporary, config.state_path))
end

---The last `depth` components of `cwd`, or all of `cwd` when it has fewer.
---@param cwd string
---@param depth integer
local function path_suffix(cwd, depth)
   if cwd == "/" and depth == 1 then
      return "root"
   end
   local parts = {}
   for part in cwd:gmatch("[^/]+") do
      parts[#parts + 1] = part
   end
   if depth > #parts then
      return cwd
   end
   return table.concat(parts, "/", #parts - depth + 1)
end

---Lengthen the path suffix until it no longer collides with a taken label.
---@param cwd string
---@param taken table<string, boolean> Labels already used by live sessions.
local function unique_label(cwd, taken)
   local depth = 1
   local label = path_suffix(cwd, depth)
   while taken[label] do
      depth = depth + 1
      local longer = path_suffix(cwd, depth)
      assert(longer ~= label, "Cannot disambiguate project label: " .. label)
      label = longer
   end
   return label
end

---A layout with one terminal at `cwd`, running `command` or an interactive shell.
---@param cwd string
---@param command? string[]
local function terminal(cwd, command)
   return {
      block = {
         flavor = "com.superlogical.terminal.shell",
         options = { cwd = cwd, shell = config.shell, command = command, interactive = command ~= nil },
      },
   }
end

---Give Rex.app time to apply new-window events before asking it to select one.
---Config actions have no rex.sleep; rex.exec yields while the app processes events.
---@param session Tyrannosession.Session
local function select_session(session)
   if session.created then
      local settled = assert(rex.exec({ "/bin/sleep", "0.2" }))
      assert(settled.ok, "Could not delay new-tab selection: " .. settled.stderr)
   end
   rex.client.queue("session.select", { session_id = session.session_id, window_id = session.window_id })
end

---Open or reuse a project by its normalized absolute root, never its display label.
---@param args { cwd: string, focus?: boolean } `focus` defaults to `true`.
---@return Tyrannosession.Session
function Tyrannosession.territorialize(args)
   local cwd = absolute(args.cwd)
   assert(is_directory(cwd), "Directory does not exist: " .. cwd)
   ---@param session Tyrannosession.Session
   local function open(session)
      if args.focus ~= false then
         select_session(session)
      end
      return session
   end

   local known = load_records()
   local live, taken = {}, {}
   for _, session in ipairs(assert(rex.call("session.list")).sessions or {}) do
      live[session.session_id] = true
      taken[session.label] = true
   end
   -- Dead records are skipped, never reused; reuse returns early without saving, so they leave the file at the next save.
   for id, record in pairs(known) do
      if not live[id] then
         known[id] = nil
      elseif record.cwd == cwd then
         return open({ session_id = id, created = false })
      end
   end

   local windows = {}
   for _, program in ipairs(config.programs) do
      windows[#windows + 1] = { layout = terminal(cwd, program) }
   end
   local claimed = assert(rex.call("session.create", { label = unique_label(cwd, taken), initial_windows = windows }))
   known[claimed.session_id] = { cwd = cwd }
   save_records()
   return open({ session_id = claimed.session_id, window_id = claimed.initial_windows[#windows].window_id, created = true })
end

---Scan in the server action, where the configured roots and executables live.
---@return Tyrannosession.Candidates
local function candidates()
   local paths, seen = {}, {}
   local function add(path)
      path = absolute(path)
      if not seen[path] then
         paths[#paths + 1] = path
         seen[path] = true
      end
   end
   local hunt = { config.executables.fd, "--type=directory", "--max-depth=" .. config.max_depth, "." }
   local initial_count = #hunt
   for _, root in ipairs(config.roots) do
      if is_directory(root) then
         hunt[#hunt + 1] = root
         add(root)
      end
   end
   assert(#hunt > initial_count, "None of the configured project roots exist")
   local sighted = assert(rex.exec(hunt))
   assert(sighted.ok, "Could not scan project directories: " .. sighted.stderr)
   for path in sighted.stdout:gmatch("[^\n]+") do
      add(path)
   end
   return { paths = paths, fzf = config.executables.fzf }
end

---Run in the floating picker process; fetch all configuration-dependent data remotely.
---@return Tyrannosession.Session? session `nil` when the picker is cancelled.
function Tyrannosession.chomp()
   ---@type Tyrannosession.Candidates
   local found = assert(rex.invoke("tyrannosession_candidates"))
   local display, paths = {}, {}
   for _, cwd in ipairs(found.paths) do
      local shown = tildify(cwd)
      display[#display + 1] = shown
      paths[shown] = cwd
   end
   table.sort(display)
   local ambush = assert(rex.exec.start({ found.fzf }, {
      stdin = table.concat(display, "\n") .. "\n",
      stderr = function(data)
         io.write(data)
      end,
   }))
   local selected = assert(ambush:wait())
   if selected.code == 1 or selected.code == 130 then
      return
   end
   assert(selected.ok, "fzf exited with status " .. tostring(selected.code))
   local cwd = paths[selected.stdout:gsub("\n$", "")]
   assert(cwd, "Project picker returned an unknown directory")
   local session = assert(rex.invoke("territorialize", { cwd = cwd, focus = false }))
   select_session(session)
   return session
end

---Register project actions. All API calls and state writes are deferred until use.
---@param options Tyrannosession.Options
function Tyrannosession.setup(options)
   assert(type(options) == "table", "setup expects a configuration table")
   local shell = options.shell or os.getenv("SHELL") or "/bin/sh"
   local executables = options.executables or {}
   config = {
      -- Rex reports the plain file path; standard Lua prefixes it with @.
      script_path = absolute((debug.getinfo(1, "S").source:gsub("^@", ""))),
      roots = {},
      programs = options.programs or { { shell } },
      shell = shell,
      max_depth = options.max_depth or 1,
      state_path = absolute(options.state_path or ((os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/rex/tyrannosession.json")),
      executables = {
         fd = executables.fd or "fd",
         fzf = executables.fzf or "fzf",
      },
   }
   assert(#config.programs > 0, "programs must contain at least one argument array")
   for _, root in ipairs(options.roots or { home .. "/Code" }) do
      config.roots[#config.roots + 1] = absolute(root)
   end
   records = nil

   rex.action({
      name = "territorialize",
      title = "Open Project Session",
      category = "Session",
      args = { cwd = "string", focus = "boolean?" },
      run = function(_, args)
         return Tyrannosession.territorialize(args)
      end,
   })
   rex.action({
      name = "hatch",
      title = "New Tab at Project Root",
      category = "Tab",
      ---@param ctx Tyrannosession.ActionContext
      run = function(ctx)
         local record = ctx.session_id and load_records()[ctx.session_id]
         if not record then
            rex.client.queue("client.tab.new")
            return
         end
         assert(is_directory(record.cwd), "Directory does not exist: " .. record.cwd)
         local window = assert(rex.session.new_window({
            session_id = ctx.session_id,
            focus = true,
            layout = terminal(record.cwd),
         }))
         select_session({ session_id = ctx.session_id, window_id = window.window_id, created = true })
         return { window_id = window.window_id }
      end,
   })
   rex.action({
      name = "tyrannosession_candidates",
      title = "List Project Directories",
      category = "Session",
      run = candidates,
   })
   rex.action({
      name = "pick_project_session",
      title = "Tyrannosession",
      category = "Session",
      ---@param ctx Tyrannosession.ActionContext
      run = function(ctx)
         assert(ctx.session_id and ctx.client_id, "Open the project picker from a Rex client session")
         local window_id
         if ctx.block_id then
            -- The app's visible tab can differ from the server's active window.
            local described = assert(rex.session.describe_block({ session_id = ctx.session_id, block_id = ctx.block_id }))
            assert(described.block.placement == "placed" and described.block.window_id, "The invoking pane is no longer in a window")
            window_id = described.block.window_id
         else
            -- Palette/CLI invocations may not identify a pane.
            window_id = assert(rex.session.view({ session_id = ctx.session_id })).active_window_id
         end
         return assert(rex.session.new_layer({
            session_id = ctx.session_id,
            window_id = window_id,
            bounds = { 0.35, 0.1, 0.3, 0.4 },
            focus = true,
            layout = {
               block = {
                  flavor = "com.superlogical.terminal.shell",
                  options = {
                     cwd = home,
                     shell = "none",
                     login = false,
                     command = { rex_cli, "--autostart=false", "-C", ctx.client_id, "do", config.script_path, "--session", ctx.session_id, "pick=true" },
                  },
               },
            },
         }))
      end,
   })
   local bindings = options.bindings or {}
   if bindings.picker ~= false then
      rex.bind(bindings.picker or "ctrl+b>f", "pick_project_session")
   end
   for _, key in ipairs(bindings.new_tab or {}) do
      rex.bind(key, "hatch")
   end
end

if rex.args and rex.args.pick then
   local ok, result = pcall(Tyrannosession.chomp)
   if not ok then
      io.write("\n" .. tostring(result) .. "\nPress Enter to close.\n")
      local _ = io.read("*l")
      rex.stop(1)
   end
   return result
end

return Tyrannosession
