;; Run with \ee \eb 
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
(local kube (fennel.dofile (.. dir "/kube.fnl")))
(local suggestions (fennel.dofile (.. dir "/suggestions.fnl")))
(local metricas (fennel.dofile (.. dir "/metricas.fnl")))

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

;; ── kube (kubectl al PR — RAG/ML inspection) ─────
; (kube.use! "sox-95289-develop")                 ; setea namespace activo
; (kube.ps)                                       ; modal con pods
; (kube.api-pod)                                  ; nombre del primer api-* en Running
; (kube.rag-status)                               ; GET $ML_LOCAL_URL/rag/index/status
; (kube.rag-recommend 1 :program_regulation_items); test directo del recommend
; (kube.rag-recommend-all-for-policy 1)           ; resumen de los 5 target types
; (kube.rag-sync!)                                ; POST /rag/index/sync
; (kube.ml-logs 200)                              ; logs del ml-service
; (kube.api-logs 200)                             ; logs del backend api
; (kube.why-pending)                              ; Events de los pods que NO están Running (Pending, etc)
; (kube.events 40)                                ; eventos del namespace, más nuevos al final
; (kube.describe-pod "worker-convert-markup-files-xxxx")
; (kube.not-running)                              ; raw: [[name status] ...]

;; ── suggestions (seed overlap policy ↔ entities) ──
; (suggestions.seed-overlap! 1)                   ; pide al RAG y vincula al program 1
; (suggestions.seed-overlap! 1 2)                 ; program-id explícito
; (suggestions.rag-ids 1 :controls_data)          ; raw: IDs que sugiere el RAG

; (let [url (galaxy.fetch-galaxy-url "soxhub" "auditboard-frontend" 38743)
      ; bc (galaxy.fetch-breadcrumb url)] 
    ; (vim.notify (.. "Conectando a: " bc) vim.log.levels.INFO)
    ; (tsh.connect! bc)
    ; (mappings.policy-dismissals-by-type)    
    ; (tsh.disconnect!)
    ; )

;; ── metricas (PRs mergeados front/back/ml) ───────
; (metricas.merged-prs)                            ; lista plana con :title :url :merged-at :first-commit-at :repo
; (metricas.merged-prs-in-repo "soxhub/machine-learning")
; (metricas.print-all)                             ; imprime todos en una línea c/u

;; Solo ML, imprime cada uno:
; (metricas.print-all (metricas.merged-prs-in-repo "soxhub/machine-learning"))

;; Cantidad por repo:
; (let [prs (metricas.merged-prs)
      ; by-repo {}]
    ; (each [_ p (ipairs prs)]
      ; (tset by-repo p.repo (+ (or (. by-repo p.repo) 0) 1)))
    ; (each [r n (pairs by-repo)] (print (string.format "%s → %d" r n))))

;; Cycle time promedio (días entre primer commit y merge):
; (let [prs (metricas.merged-prs)
      ; sum 0]
    ; (each [_ p (ipairs prs)] (set sum (+ sum (or p.days-to-merge 0))))
    ; (print (string.format "avg cycle time: %.1f días (n=%d)" (/ sum (length prs)) (length prs))))

;; PRs mergeados por semana (ISO week, ej: '2026-W25'):
; (let [by-week {}]
    ; (each [_ p (ipairs (metricas.merged-prs))]
      ; (tset by-week p.merged-week (+ (or (. by-week p.merged-week) 0) 1)))
    ; (let [weeks (icollect [k _ (pairs by-week)] k)]
      ; (table.sort weeks)
      ; (each [_ w (ipairs weeks)] (print (string.format "%s → %d" w (. by-week w))))))

;; Top 5 PRs más lentos:
; (let [prs (metricas.merged-prs)]
    ; (table.sort prs #(> (or $1.days-to-merge 0) (or $2.days-to-merge 0)))
    ; (each [i p (ipairs prs)]
      ; (when (<= i 5) (print (metricas.format-row p)))))

;; PRs mergeados en los últimos 30 días:
; (let [cutoff (- (os.time) (* 30 86400))]
    ; (icollect [_ p (ipairs (metricas.merged-prs))]
      ; (when (> (vim.fn.strptime "%Y-%m-%dT%H:%M:%SZ" p.merged-at) cutoff)
        ; p)))

;; Volcar a CSV para abrir en otro lado:
; (let [f (io.open "/tmp/mis-prs.csv" "w")]
    ; (f:write "repo,number,first_commit_at,merged_at,merged_week,days_to_merge,approvals,comments,title,url\n")
    ; (each [_ p (ipairs (metricas.merged-prs))]
      ; (f:write (string.format "%s,%d,%s,%s,%s,%.2f,%d,%d,%q,%s\n"
                              ; p.repo p.number p.first-commit-at p.merged-at
                              ; p.merged-week (or p.days-to-merge 0)
                              ; p.approvals p.comments p.title p.url)))
    ; (f:close))

;; Re-exportamos por si querés requerir madame desde otro lado.
{: jira : prs : slack : tsh : mappings : chulos : docker : galaxy : kube : suggestions : metricas}
