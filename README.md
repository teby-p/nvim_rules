# escort ❤️💬

Scripts en Fennel para Neovim que automatizan mi trabajo en Auditboard.

## Motivación

La mayoría de estas tareas se pueden resolver con skills, agentes o lo que se te ocurra directamente desde Claude. Pero como ingeniero me duele ver que los muchachos de ***Antro_pic*** hayan resuelto de la peor manera posible un problema que está resuelto desde 1958: extender un programa en caliente. Se llama REPL y lo inventó Lisp.

Los archivos `.md` tienen drawbacks severos:

- No componen: no podés llamar un skill desde otro como si fueran funciones.
- No hay debugging: no podés steppear, inspeccionar variables ni mirar el stack.
- No los testeás: ¿Qué assert le ponés a un `.md`?
- Cada invocación arranca de cero: no hay estado vivo entre llamadas.
- Versionarlos es teatro: el diff de prosa natural es ruido puro.
- Acoplados al modelo: cambia la versión del LLM y tu "programa" muta solo.
- Discoverability nula: Para saber qué hace un skill hay que leer todo el `.md` y rezar.
- No son determinísticos: el mismo input puede producir comportamientos distintos según cómo se sienta el modelo ese día.
- Gastan tokens al botón: aunque esto debe ser por diseño.
- Hacen mal a la vista.

## Requisitos

- **Neovim** ≥ 0.10 (usa `vim.ui.open`, `vim.base64.encode`, `vim.fs.dirname`).
- **Fennel** disponible como módulo Lua (`require :fennel`).
- Un plugin para evaluar Fennel desde el buffer — este repo está pensado para
  [Conjure](https://github.com/Olical/conjure) con el cliente de Fennel.

## Instalacion
- Para usar choferes: cd ~/Development/escort/choferes && npm install
