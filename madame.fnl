;; madame.fnl — punto de entrada. Carga los demas y deja las funciones
;; exportadas listas para evaluar. Corre con Conjure la linea que quieras.

(local fennel (require :fennel))
(local dir "/Users/epodesta/Development/escort")

(local jira (fennel.dofile (.. dir "/jira.fnl")))
(local prs (fennel.dofile (.. dir "/prs.fnl")))
(local slack (fennel.dofile (.. dir "/slack.fnl")))
(local tsh (fennel.dofile (.. dir "/tsh.fnl")))

;; ── Jira ──────────────────────────────────────────
; (jira.show-issues)         ; modal con mis tickets abiertos
; (jira.my-issues)            ; raw: tabla con los issues asignados

;; ── GitHub PRs ────────────────────────────────────
; (prs.show-prs)              ; modal con mis PRs + CI + Jira + approvers
; (prs.my-prs)                ; raw: lista de mis PRs abiertos

;; ── Slack ─────────────────────────────────────────
; (slack.show-slack)          ; modal con mensajes recientes
; (slack.show-reviews)        ; modal con pedidos de review filtrados
; (slack.unread-all)          ; raw: [{:channel :messages}]
; (slack.review-requests)     ; raw: ídem pero filtrado por review

;; ── tsh (Teleport DB) ─────────────────────────────
; (tsh.install-lualine!)      ; una vez: agrega indicador a la statusline
; (tsh.connect! "Home › Cloud › Instances › PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop")
; (tsh.query "SELECT id, name FROM policies LIMIT 5;")
; (tsh.count-policies)        ; helper: SELECT count(*) FROM policies
; (tsh.list-tables)           ; helper: tablas del schema public
; (tsh.disconnect!)           ; cierra el terminal y apaga el indicador

;; Re-exportamos por si querés requerir madame desde otro lado.
{: jira : prs : slack : tsh}
