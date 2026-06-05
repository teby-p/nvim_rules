;; madame.fnl — punto de entrada. Carga los demas y deja las funciones
;; exportadas listas para evaluar. Corre con Conjure la linea que quieras.

(local fennel (require :fennel))
(local dir "/Users/epodesta/Development/escort")

(local jira (fennel.dofile (.. dir "/jira.fnl")))
(local prs (fennel.dofile (.. dir "/prs.fnl")))
(local slack (fennel.dofile (.. dir "/slack.fnl")))
(local tsh (fennel.dofile (.. dir "/tsh.fnl")))
(local mappings (fennel.dofile (.. dir "/mappings.fnl")))
(local chulos (fennel.dofile (.. dir "/chulos.fnl")))

;; ── Jira ──────────────────────────────────────────
; (jira.show-issues)         ; modal con mis tickets abiertos
; (jira.my-issues)            ; raw: tabla con los issues asignados

;; ── GitHub PRs ────────────────────────────────────
; (prs.show-prs)              ; modal con mis PRs + CI + Jira + approvers
; (prs.my-prs)                ; raw: lista de mis PRs abiertos

;; ── Slack ─────────────────────────────────────────
; (slack.show-slack 24)       ; modal con mensajes de las últimas N horas
; (slack.show-reviews 48)     ; modal con pedidos de review de las últimas N horas
; (slack.unread-all 24)       ; raw: [{:channel :messages}]
; (slack.review-requests 48)  ; raw: ídem pero filtrado por review

;; ── tsh (Teleport DB) ─────────────────────────────
; (tsh.install-lualine!)      ; una vez: agrega indicador a la statusline
; (tsh.connect! "Home › Cloud › Instances › PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop")
; (tsh.query "SELECT id, name FROM policies LIMIT 5;")
; (tsh.count-policies)        ; helper: SELECT count(*) FROM policies
; (tsh.list-tables)           ; helper: tablas del schema public
; (tsh.disconnect!)           ; cierra el terminal y apaga el indicador

;; ── mappings (Auditboard policy stuff) ────────────
; (mappings.policy-mappings-by-source)    ; resumen por reference_type + source
; (mappings.policy-dismissals-by-type)    ; resumen de dismissals
; (mappings.delete-dismissals!)           ; picker para soft-delete
; (mappings.clear-all-mappings!)          ; soft-delete TODOS los mappings (confirmación)
; (mappings.replicate-regulation-items!)  ; dump PR → CSVs + import.sql para local

;; ── chulos (correr imports en local) ──────────────
; (chulos.pick-and-import!)               ; picker + corre psql -d demo_data -f .../import.sql
; (chulos.list-repros)                    ; raw: nombres de subdirs con import.sql

;; Re-exportamos por si querés requerir madame desde otro lado.
{: jira : prs : slack : tsh : mappings : chulos}
