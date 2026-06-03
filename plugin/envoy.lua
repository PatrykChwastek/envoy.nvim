-- Loaded at startup, before lazy-loading kicks in.
-- Registers the .http / .rest filetypes so `ft = "http"` lazy-load triggers
-- fire. Everything else lives in lua/envoy/ and runs from setup().

if vim.g.loaded_envoy then return end
vim.g.loaded_envoy = 1

vim.filetype.add({ extension = { http = "http", rest = "http" } })
