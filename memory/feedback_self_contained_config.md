---
name: feedback-self-contained-config
description: Para el proyecto escort, mantener config dentro de los .fnl en vez de tocar nvim plugin specs externos.
metadata:
  type: feedback
---

Cuando el usuario pide una integración con nvim (statusline, keymaps, autocmds, etc.) desde un módulo del proyecto escort, **preferir registrarla programáticamente desde el .fnl** en vez de editar archivos en `~/.config/nvim/lua/plugins/`.

**Why:** El usuario eligió Fennel + Conjure para tener todo lo del proyecto en módulos auto-contenidos y evaluables form-a-form. Esparcir config a plugin specs rompe esa propiedad — exige reiniciar nvim para ver cambios, y separa la config de su feature relacionado.

**How to apply:** Antes de editar algo en `~/.config/nvim/`, preguntarse si la integración se puede hacer via la API runtime del plugin (ej. `lualine.setup`, `vim.keymap.set`, `vim.api.nvim_create_autocmd`) desde el .fnl correspondiente. Si sí, ese es el camino. Solo tocar plugin specs si el plugin no tiene API runtime.
