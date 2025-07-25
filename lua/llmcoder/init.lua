local M = {}

function M.find_git_root()
	local uv = vim.loop
	local cwd = uv.cwd()
	local home = os.getenv("HOME") or "~"

	local function is_git_dir(path)
		local stat = uv.fs_stat(path .. "/.git")
		return stat and (stat.type == "directory" or stat.type == "file")
	end

	local function is_home_or_root(path)
		return path == home or path == "/"
	end

	local function dirname(path)
		local pattern = package.config:sub(1, 1) == "\\" and "\\[^\\]+$" or "/[^/]+$"
		return path:match("^(.+)" .. pattern) or path
	end

	local dir = cwd
	while not is_home_or_root(dir) do
		if is_git_dir(dir) then
			return dir
		end
		local parent = dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end

	return nil
end

-- Get all tracked and untracked-but-n t-ignored files
function M.list_git_files()
	local git_root = M.find_git_root()
	if not git_root then
		vim.notify("Not inside a Git repo", vim.log.levels.WARN)
		return {}
	end

	-- Use Git to list files respecting .gitignore
	local cmd = { "git", "-C", git_root, "ls-files", "--cached", "--others", "--exclude-standard" }
	local output = vim.fn.systemlist(cmd)

	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to list files: " .. table.concat(output, "\n"), vim.log.levels.ERROR)
		return {}
	end

	local exclude_set = {
		[".gitignore"] = true,
		[".gitmodules"] = true,
	}

	local filtered = {}
	for _, file in ipairs(output) do
		if not exclude_set[file] then
			table.insert(filtered, file)
		end
	end

	return filtered
end

function M.setup(opts)
	opts = opts or {}

	local lspconfig = require("lspconfig")
	local util = require("lspconfig/util")

	-- Configuration with defaults
	local config = vim.tbl_deep_extend("force", {
		keymaps = {
			trigger = "<C-n>",
			accept = "<Tab>",
		},
		ghost_text = {
			hl_group = "Comment",
			enabled = true,
		},
		server = {
			launch_script = vim.fn.expand("~/.local/share/llmcoder/launch.sh"),
			filetypes = { "text", "markdown", "lua", "python", "javascript", "typescript" },
		},
		auto_trigger = {
			enabled = false,
			delay_ms = 500,
		},
	}, opts)

	local ghost_ns = vim.api.nvim_create_namespace("llmcoder_ghost")
	local state = {
		extmarks = {},
		ghost_data = nil, -- Store complete ghost text data
		auto_trigger_timer = nil,
	}

	-- Utility functions
	local function is_valid_buffer(bufnr)
		return bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
	end

	local function get_llmcoder_client(bufnr)
		for _, client in ipairs(vim.lsp.get_active_clients({ bufnr = bufnr })) do
			if client.name == "llmcoder" then
				return client
			end
		end
		return nil
	end

	local function handle_get_project_files(_, params, callback)
		local git_root = M.find_git_root()
		if not git_root then
			callback(nil)
			return
		end

		local files = M.list_git_files()
		local results = {}

		for _, relative_path in ipairs(files) do
			local full_path = git_root .. "/" .. relative_path
			local content = ""
			local f = io.open(full_path, "r")
			if f then
				content = f:read("*a")
				f:close()
			end
			table.insert(results, {
				path = relative_path,
				content = content,
			})
		end

		callback(results)
	end

	local function clear_ghost_text()
		if state.ghost_data and is_valid_buffer(state.ghost_data.bufnr) then
			vim.api.nvim_buf_clear_namespace(state.ghost_data.bufnr, ghost_ns, 0, -1)
		end
		state.extmarks = {}
		state.ghost_data = nil

		-- Cancel auto-trigger timer
		if state.auto_trigger_timer then
			state.auto_trigger_timer:stop()
			state.auto_trigger_timer:close()
			state.auto_trigger_timer = nil
		end
	end

	local function insert_ghost_text()
		if not state.ghost_data then
			return false
		end

		local bufnr = state.ghost_data.bufnr
		local line_num = state.ghost_data.line
		local text = state.ghost_data.text

		if not is_valid_buffer(bufnr) or not text or text == "" then
			return false
		end

		local lines = vim.split(text, "\n", true)
		if #lines == 0 then
			return false
		end

		-- Get current cursor position
		local cursor = vim.api.nvim_win_get_cursor(0)
		local current_line = cursor[1] - 1
		local current_col = cursor[2]

		-- Ensure we're still on the same line where ghost text was triggered
		if current_line ~= line_num then
			clear_ghost_text()
			return false
		end

		-- Get the current line content
		local current_line_content = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, true)[1] or ""

		-- Insert first line at cursor position
		local prefix = current_line_content:sub(1, current_col)
		local suffix = current_line_content:sub(current_col + 1)
		local first_line = lines[1]
		local new_first_line = prefix .. first_line .. suffix

		-- Prepare all lines to insert
		local lines_to_insert = { new_first_line }
		for i = 2, #lines do
			table.insert(lines_to_insert, lines[i])
		end

		-- Insert the text
		vim.api.nvim_buf_set_lines(bufnr, line_num, line_num + 1, true, lines_to_insert)

		-- Move cursor to end of inserted text
		local new_cursor_line = line_num + #lines
		local new_cursor_col = #lines > 1 and #lines[#lines] or (current_col + #first_line)
		vim.api.nvim_win_set_cursor(0, { new_cursor_line, new_cursor_col })

		clear_ghost_text()
		return true
	end

	local function display_ghost_text(bufnr, line_num, text, col)
		if not config.ghost_text.enabled or not is_valid_buffer(bufnr) then
			return
		end

		-- Clear existing ghost text
		vim.api.nvim_buf_clear_namespace(bufnr, ghost_ns, 0, -1)
		state.extmarks = {}

		local lines = vim.split(text, "\n", true)
		if #lines == 0 then
			return
		end

		-- Display first line as virtual text overlay
		local first_line_text = lines[1]
		if first_line_text and #first_line_text > 0 then
			local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ghost_ns, line_num, col, {
				virt_text = {
					{ string.rep("", #first_line_text), "Normal" }, -- creates padding
					{ first_line_text, config.ghost_text.hl_group }, -- actual ghost text
				},
				virt_text_pos = "inline",
				hl_mode = "combine",
			})
			table.insert(state.extmarks, extmark_id)
		end

		-- Display additional lines as a single virtual lines block to maintain order
		if #lines > 1 then
			local additional_lines = {}
			for i = 2, #lines do
				table.insert(additional_lines, { { lines[i], config.ghost_text.hl_group } })
			end

			local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ghost_ns, line_num, col, {
				virt_lines = additional_lines,
			})
			table.insert(state.extmarks, extmark_id)
		end
	end

	local function on_ghost_text_response(_, result)
		if not result or not result.uri then
			clear_ghost_text()
			return
		end

		local bufnr = vim.uri_to_bufnr(result.uri)
		if not is_valid_buffer(bufnr) then
			vim.fn.bufload(bufnr)
		end

		local line_num = result.line or 0
		local text = result.text or ""
		local col = vim.api.nvim_win_get_cursor(0)[2]

		-- Store ghost data
		state.ghost_data = {
			bufnr = bufnr,
			line = line_num,
			text = text,
			col = col,
		}

		display_ghost_text(bufnr, line_num, text, col)
	end

	local function cancel_ghost_text()
		local bufnr = vim.api.nvim_get_current_buf()
		local client = get_llmcoder_client(bufnr)

		if client then
			-- Notify server to cancel
			client.notify("$/cancelGhostText", {})
		end

		clear_ghost_text()
	end

	local function trigger_ghost_text()
		local bufnr = vim.api.nvim_get_current_buf()
		local client = get_llmcoder_client(bufnr)

		if not client then
			vim.notify("LLM Coder not active for current buffer", vim.log.levels.WARN)
			return
		end

		local cursor = vim.api.nvim_win_get_cursor(0)
		local uri = vim.uri_from_bufnr(bufnr)

		client.request("custom/triggerGhostText", {
			textDocument = { uri = uri },
			position = { line = cursor[1] - 1, character = cursor[2] },
		}, function(err, result)
			if err then
				vim.notify("GhostText error: " .. vim.inspect(err), vim.log.levels.ERROR)
			end
		end, bufnr)
	end

	local function auto_trigger_ghost_text()
		if not config.auto_trigger.enabled then
			return
		end

		-- Cancel existing timer
		if state.auto_trigger_timer then
			state.auto_trigger_timer:stop()
			state.auto_trigger_timer:close()
		end

		-- Create new timer
		state.auto_trigger_timer = vim.loop.new_timer()
		state.auto_trigger_timer:start(
			config.auto_trigger.delay_ms,
			0,
			vim.schedule_wrap(function()
				trigger_ghost_text()
			end)
		)
	end

	local function setup_autocommands()
		local group = vim.api.nvim_create_augroup("LLMCoderGhostText", { clear = true })

		-- Cancel ghost text on various events
		vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave" }, {
			group = group,
			callback = cancel_ghost_text,
		})

		vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI", "InsertCharPre" }, {
			group = group,
			callback = function()
				if state.ghost_data then
					local cursor = vim.api.nvim_win_get_cursor(0)
					local current_line = cursor[1] - 1
					local current_col = cursor[2]

					if current_line ~= state.ghost_data.line or current_col < state.ghost_data.col then
						clear_ghost_text()
					else
						clear_ghost_text()
					end
				end

				if config.auto_trigger.enabled then
					auto_trigger_ghost_text()
				end
			end,
		})
	end

	local function setup_lsp_server()
		-- Register LSP server if not already registered
		if not lspconfig.llmcoder then
			lspconfig.llmcoder = {
				default_config = {
					cmd = { config.server.launch_script },
					filetypes = config.server.filetypes,
					root_dir = function(fname)
						return util.find_git_ancestor(fname) or vim.fn.getcwd()
					end,
					single_file_support = true,
				},
			}
		end

		-- Setup the LSP server
		lspconfig.llmcoder.setup({
			handlers = {
				["ghostText/virtualText"] = vim.schedule_wrap(on_ghost_text_response),
			},
			on_attach = function(client, bufnr)
				if client.name ~= "llmcoder" then
					return
				end

				local opts = { buffer = bufnr, noremap = true, silent = true }

				-- Set up keymaps
				vim.keymap.set(
					"i",
					config.keymaps.trigger,
					trigger_ghost_text,
					vim.tbl_extend("force", opts, {
						desc = "Trigger ghost text completion",
					})
				)

				vim.keymap.set(
					"i",
					config.keymaps.accept,
					function()
						if state.ghost_data and #state.extmarks > 0 then
							if insert_ghost_text() then
								return
							end
						end
						-- Fallback to normal tab behavior
						vim.api.nvim_feedkeys(
							vim.api.nvim_replace_termcodes(config.keymaps.accept, true, false, true),
							"n",
							false
						)
					end,
					vim.tbl_extend("force", opts, {
						desc = "Accept ghost text or insert tab",
					})
				)
				local sent = false

				if not sent then
					sent = true
					vim.schedule(function()
						-- local client = get_llmcoder_client(bufnr)
						if client then
							local git_root = M.find_git_root()
							if not git_root then
								return
							end

							local files = M.list_git_files()
							for _, rel_path in ipairs(files) do
								local full_path = git_root .. "/" .. rel_path
								local f = io.open(full_path, "r")
								if f then
									local content = f:read("*a")
									f:close()

									client.notify("custom/projectFile", {
										path = rel_path,
										content = content,
										root = git_root,
									})
								end
							end
						end
					end)
				end
			end,
		})
	end

	-- Public API
	M.trigger_ghost_text = trigger_ghost_text
	M.cancel_ghost_text = cancel_ghost_text
	M.clear_ghost_text = clear_ghost_text
	M.has_ghost_text = function()
		return state.ghost_data ~= nil
	end
	M.get_config = function()
		return config
	end

	-- Initialize
	setup_lsp_server()
	setup_autocommands()
end

return M
