;; madame.fnl — punto de entrada. Carga los demas y deja las funciones
;; exportadas listas para evaluar. Corre con Conjure la linea que quieras.

(local fennel (require :fennel))
(local dir "/Users/epodesta/Development/escort/chicas")

(local jira (fennel.dofile (.. dir "/jira.fnl")))
(local prs (fennel.dofile (.. dir "/prs.fnl")))
(local slack (fennel.dofile (.. dir "/slack.fnl")))
(local tsh (fennel.dofile (.. dir "/tsh.fnl")))
(local mappings (fennel.dofile (.. dir "/mappings.fnl")))
(local chulos (fennel.dofile (.. dir "/chulos.fnl")))
(local docker (fennel.dofile (.. dir "/docker.fnl")))
(local galaxy (fennel.dofile (.. dir "/galaxy.fnl")))

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
; (tsh.connect! "PRNew (pr-us-west-2-tennis / us-west-2) / sox-95289-develop")
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

;; ── docker (containers locales) ───────────────────
; (docker.fix-rag!)                       ; restart ab_mlservice_local + worker (cura ECONNRESET en :8000/rag/recommend)
; (docker.ps)                             ; modal con containers corriendo
; (docker.logs :ab_mlservice_local 200)   ; modal con los últimos N logs
; (docker.restart-containers! [:foo :bar]); restart de containers arbitrarios

;; ── galaxy (primitivas: Chrome CDP + scrape breadcrumb) ──
; (galaxy.chrome!)                               ; lanza Chrome con --remote-debugging-port (idempotente)
; (galaxy.cdp-alive?)                            ; true si Chrome está escuchando en :9222
; (galaxy.fetch-galaxy-url "soxhub" "auditboard-frontend" 38743)
; (galaxy.fetch-breadcrumb "https://galaxy.auditboardteam.com/admin/cloud/instance/<id>/")

; (let [url (galaxy.fetch-galaxy-url "soxhub" "auditboard-frontend" 38743)
;       bc (galaxy.fetch-breadcrumb url)] 
;     (vim.notify (.. "Conectando a: " bc) vim.log.levels.INFO)
;     (tsh.connect! bc)
;     (mappings.policy-dismissals-by-type)    
;     (tsh.disconnect!))

;; Re-exportamos por si querés requerir madame desde otro lado.
{: jira : prs : slack : tsh : mappings : chulos : docker : galaxy}
