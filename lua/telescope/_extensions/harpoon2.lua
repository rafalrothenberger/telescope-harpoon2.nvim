local telescope_installed, telescope = pcall(require, "telescope")

if not telescope_installed then
  error("harpoon2-telescope.nvim requires nvim-telescope/telescope.nvim")
end

return telescope.register_extension({
  exports = {
    ui = require("telescope._extensions.ui"),
  },
})
