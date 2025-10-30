require("plenary.async").tests.add_to_env()
local TmpDir = require("tests.tmpdir")
local oil = require("oil")
local test_util = require("tests.test_util")
local util = require("oil.util")

a.describe("oil preview", function()
  local tmpdir
  a.before_each(function()
    tmpdir = TmpDir.new()
  end)
  a.after_each(function()
    if tmpdir then
      tmpdir:dispose()
    end
    test_util.reset_editor()
  end)

  a.it("opens preview window", function()
    tmpdir:create({ "a.txt" })
    test_util.oil_open(tmpdir.path)
    a.wrap(oil.open_preview, 2)()
    local preview_win = util.get_preview_win()
    assert.not_nil(preview_win)
    assert(preview_win)
    local bufnr = vim.api.nvim_win_get_buf(preview_win)
    local preview_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.same({ "a.txt" }, preview_lines)
  end)

  a.it("opens preview window when open(preview={})", function()
    tmpdir:create({ "a.txt" })
    test_util.oil_open(tmpdir.path, { preview = {} })
    local preview_win = util.get_preview_win()
    assert.not_nil(preview_win)
    assert(preview_win)
    local bufnr = vim.api.nvim_win_get_buf(preview_win)
    local preview_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.same({ "a.txt" }, preview_lines)
  end)

  a.it("displays image info for image files", function()
    tmpdir:create({ "test.png" })
    -- Create a fake PNG file
    local png_path = tmpdir.path .. "/test.png"
    local fd = vim.loop.fs_open(png_path, "w", 438)
    if fd then
      vim.loop.fs_write(fd, "fake png data")
      vim.loop.fs_close(fd)
    end
    
    test_util.oil_open(tmpdir.path)
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- Position on test.png
    a.wrap(oil.open_preview, 2)()
    
    local preview_win = util.get_preview_win()
    assert.not_nil(preview_win)
    local bufnr = vim.api.nvim_win_get_buf(preview_win)
    local preview_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    
    -- Should contain image information display with simplified format
    local has_image_info = false
    for _, line in ipairs(preview_lines) do
      if line:match("Image:") or line:match("Size:") then
        has_image_info = true
        break
      end
    end
    assert.is_true(has_image_info)
  end)

  a.it("detects image files correctly", function()
    assert.is_true(util.is_image_file("test.png"))
    assert.is_true(util.is_image_file("photo.jpg"))
    assert.is_true(util.is_image_file("image.jpeg"))
    assert.is_true(util.is_image_file("animation.gif"))
    assert.is_true(util.is_image_file("graphic.webp"))
    assert.is_true(util.is_image_file("icon.svg"))
    
    assert.is_false(util.is_image_file("document.txt"))
    assert.is_false(util.is_image_file("script.lua"))
    assert.is_false(util.is_image_file("data.json"))
  end)
end)
