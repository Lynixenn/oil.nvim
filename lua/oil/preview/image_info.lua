-- Image information display fallback for Oil.nvim
-- Used when Kitty graphics protocol is not available

local M = {}

---Format file size in human-readable format
---@param bytes integer
---@return string
M.format_file_size = function(bytes)
  if bytes < 1024 then
    return string.format("%d B", bytes)
  elseif bytes < 1024 * 1024 then
    return string.format("%.1f KB", bytes / 1024)
  elseif bytes < 1024 * 1024 * 1024 then
    return string.format("%.1f MB", bytes / (1024 * 1024))
  else
    return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
  end
end

---Get image file metadata
---@param path string
---@return table|nil metadata {width: integer, height: integer, format: string, size: integer}
---@return string|nil error
M.get_image_metadata = function(path)
  -- Get file size
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return nil, "Could not stat file"
  end
  
  local metadata = {
    size = stat.size,
    format = "unknown",
    width = nil,
    height = nil,
  }
  
  -- Detect format from extension
  local ext = path:match("%.([^.]+)$")
  if ext then
    metadata.format = ext:upper()
  end
  
  -- Try to get dimensions using ImageMagick identify
  local has_identify = vim.fn.executable("identify") == 1
  if has_identify then
    local output = vim.fn.system(string.format("identify -format '%%w %%h %%m' %s 2>/dev/null", vim.fn.shellescape(path)))
    if vim.v.shell_error == 0 then
      local width, height, format = output:match("(%d+)%s+(%d+)%s+(%S+)")
      if width and height then
        metadata.width = tonumber(width)
        metadata.height = tonumber(height)
        if format and format ~= "" then
          metadata.format = format
        end
      end
    end
  end
  
  -- Fallback: try using `file` command
  if not metadata.width or not metadata.height then
    local has_file = vim.fn.executable("file") == 1
    if has_file then
      local output = vim.fn.system(string.format("file %s", vim.fn.shellescape(path)))
      local width, height = output:match("(%d+)%s*x%s*(%d+)")
      if width and height then
        metadata.width = tonumber(width)
        metadata.height = tonumber(height)
      end
    end
  end
  
  return metadata, nil
end

---Display image information in buffer
---@param bufnr integer
---@param path string
---@return boolean success
---@return string|nil error
M.display_image_info = function(bufnr, path)
  local metadata, err = M.get_image_metadata(path)
  if not metadata then
    return false, err
  end
  
  -- Build minimal info lines
  local filename = vim.fn.fnamemodify(path, ":t")
  local lines = {
    "",
    "Image: " .. filename,
    "Size: " .. M.format_file_size(metadata.size),
  }
  
  if metadata.width and metadata.height then
    table.insert(lines, string.format("Dimensions: %d x %d", metadata.width, metadata.height))
  end
  
  -- Display at top of buffer
  vim.bo[bufnr].modifiable = true
  
  -- Set the lines
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  
  return true, nil
end

return M