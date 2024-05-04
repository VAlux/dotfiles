-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- paste without yanking deleted text into the unnamed register
vim.keymap.set("x", "<leader>p", '"_dP')
vim.keymap.set("n", "<leader>uu", vim.cmd.UndotreeToggle)
