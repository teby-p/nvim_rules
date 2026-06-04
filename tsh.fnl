;; tsh.fnl — helpers para conectarse a la DB de un PR deploy vía Teleport.

(local api vim.api)
(local vfn vim.fn)

(fn parse-instance-breadcrumb [s]
  "Extrae cluster e instancia del string breadcrumb de Galaxy.
  Ejemplo:
    'Home › Cloud › Instances › PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop'
  Devuelve {:cluster 'pr-us-west-2-tennis' :instance 'sox-82749-develop'}.
  OJO: el cluster del breadcrumb (Galaxy) NO necesariamente coincide con el
  nombre de la DB registrada en Teleport. Usá `pick-db` para elegir el correcto."
  (let [cluster (string.match s "%((pr%-[%w%-]+)%s*/%s*[%w%-]+%)")
        instance (string.match s "/%s*([%w%-]+)%s*$")]
    {: cluster : instance}))

(fn db-name [instance galaxy-id]
  "Nombre de DB para tsh: instancia sin guiones + galaxy id.
  'sox-82749-develop' + 111400 → 'sox82749develop111400'."
  (.. (string.gsub instance "%-" "") (tostring galaxy-id)))

(fn build-command [breadcrumb ?galaxy-id ?cluster-override]
  "Devuelve el comando `tsh db connect ...`.
  Si pasás ?cluster-override, lo usa en vez del cluster parseado del breadcrumb
  (que muchas veces no matchea el nombre real de la DB en Teleport)."
  (let [{:cluster parsed-cluster : instance} (parse-instance-breadcrumb breadcrumb)
        cluster (or ?cluster-override parsed-cluster)]
    (if (or (not cluster) (not instance))
      (do (vim.notify (.. "tsh: no pude parsear el breadcrumb: " breadcrumb)
                      vim.log.levels.ERROR) nil)
      (let [gid (or ?galaxy-id "<GALAXY_ID>")]
        (string.format "tsh db connect %s --db-user=teleport --db-name=%s"
                       cluster (db-name instance gid))))))

;; ── Galaxy ID auto-lookup ─────────────────────────

(fn fetch-galaxy-id [instance]
  "Para una instancia tipo 'sox-82749-develop':
   1) infiere ticket (SOX-82749),
   2) busca PR con label pr-deploy en soxhub,
   3) parsea el comment del PR Deploy Bot y devuelve el Galaxy ID.
   Devuelve nil si no encuentra."
  (let [(prefix num) (string.match instance "^([%a]+)-(%d+)")]
    (when (and prefix num)
      (let [ticket (.. (string.upper prefix) "-" num)
            search-out (vfn.system ["gh" "search" "prs" ticket
                                    "--owner" "soxhub"
                                    "--label" "pr-deploy"
                                    "--state" "open"
                                    "--limit" "5"
                                    "--json" "number,repository,updatedAt"])]
        (if (not= 0 vim.v.shell_error)
          (do (vim.notify (.. "gh search error: " search-out)
                          vim.log.levels.ERROR) nil)
          (let [prs (vim.json.decode search-out)]
            (when (> (length prs) 0)
              (table.sort prs (fn [a b] (> a.updatedAt b.updatedAt)))
              (let [pr (. prs 1)
                    repo (?. pr :repository :nameWithOwner)
                    number pr.number
                    comments-out (vfn.system
                                   ["gh" "api"
                                    (string.format "repos/%s/issues/%d/comments"
                                                   repo number)
                                    "--jq"
                                    "[.[] | select(.body | test(\"PRDeployment Reserved Comment\")) | .body] | last"])]
                (if (not= 0 vim.v.shell_error)
                  (do (vim.notify (.. "gh api error: " comments-out)
                                  vim.log.levels.ERROR) nil)
                  (string.match comments-out
                                "galaxy%.auditboardteam%.com/admin/cloud/instance/(%d+)"))))))))))

;; ── DB picker ─────────────────────────────────────

(fn list-dbs []
  "Devuelve la lista de nombres de DBs registradas (via `tsh db ls -f json`)."
  (let [out (vfn.system ["tsh" "db" "ls" "-f" "json"])]
    (if (not= 0 vim.v.shell_error)
      (do (vim.notify (.. "tsh db ls error: " out) vim.log.levels.ERROR) nil)
      (let [parsed (vim.json.decode out)
            names []]
        (each [_ db (ipairs (or parsed []))]
          (let [n (?. db :metadata :name)]
            (when n (table.insert names n))))
        names))))

(fn pick-db [on-select]
  "Modal flotante con las DBs registradas. Llama (on-select db-name) al elegir."
  (let [names (list-dbs)]
    (when names
      (if (= 0 (length names))
        (vim.notify "tsh: no hay DBs registradas — ¿corriste `tsh login`?"
                    vim.log.levels.WARN)
        (let [buf (api.nvim_create_buf false true)
              width (math.min 60 (- vim.o.columns 4))
              height (math.min (length names) (math.max 5 (- vim.o.lines 8)))
              row (math.floor (/ (- vim.o.lines height) 2))
              col (math.floor (/ (- vim.o.columns width) 2))]
          (api.nvim_buf_set_lines buf 0 -1 false names)
          (api.nvim_set_option_value :modifiable false {:buf buf})
          (api.nvim_set_option_value :buftype :nofile {:buf buf})
          (let [win (api.nvim_open_win buf true
                                       {:relative :editor
                                        :width width
                                        :height height
                                        :row row :col col
                                        :style :minimal
                                        :border :rounded
                                        :title " Elegí DB "
                                        :title_pos :center})
                opts {:buffer buf :silent true :nowait true}
                close #(when (api.nvim_win_is_valid win)
                         (api.nvim_win_close win true))]
            (api.nvim_win_set_cursor win [1 0])
            (vim.keymap.set :n :q close opts)
            (vim.keymap.set :n :<Esc> close opts)
            (vim.keymap.set :n :<CR>
                            #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                                   chosen (. names lnum)]
                               (close)
                               (when chosen (on-select chosen)))
                            opts)))))))

;; ── Statusline indicator ──────────────────────────
;; Estado en `vim.g.tsh_connected` (string = instancia conectada, nil = no).
;; El componente de lualine se registra via install-lualine! — evalualo una vez.

(fn spawn-terminal! [cmd instance]
  "Lanza cmd en un split-terminal y configura el tracking de la conexión."
  (let [orig-win (api.nvim_get_current_win)]
    (vim.cmd (string.format "botright 10split | terminal %s" cmd))
    (let [term-buf (api.nvim_get_current_buf)]
      (set vim.g.tsh_buf term-buf)
      (set vim.g.tsh_connected instance)
      (vim.cmd :redrawstatus)
      (api.nvim_create_autocmd
        :TermClose
        {:buffer term-buf
         :once true
         :callback (fn []
                     (set vim.g.tsh_connected nil)
                     (set vim.g.tsh_buf nil)
                     (vim.cmd :redrawstatus))})
      (api.nvim_set_current_win orig-win))))

(fn connect! [breadcrumb ?galaxy-id]
  "Abre el picker de DBs y, al elegir una, lanza el `tsh db connect` en un
  split-terminal abajo. Si no pasás ?galaxy-id, lo busca solo via el PR Deploy
  Bot comment (estilo pr-deploy-db-connect.sh)."
  (if vim.g.tsh_connected
    (vim.notify (.. "tsh: ya hay conexión activa con " vim.g.tsh_connected
                    ". Disconnect primero.")
                vim.log.levels.WARN)
    (let [{: instance} (parse-instance-breadcrumb breadcrumb)]
      (if (not instance)
        (vim.notify (.. "tsh: no pude parsear el breadcrumb: " breadcrumb)
                    vim.log.levels.ERROR)
        (let [galaxy-id (or ?galaxy-id
                            (do (vim.notify (.. "🔎 buscando galaxy-id para "
                                                instance "…")
                                            vim.log.levels.INFO)
                                (vim.cmd :redraw)
                                (fetch-galaxy-id instance)))]
          (if (not galaxy-id)
            (vim.notify (.. "tsh: no pude encontrar el galaxy-id para " instance)
                        vim.log.levels.ERROR)
            (pick-db (fn [cluster]
                       (let [cmd (build-command breadcrumb galaxy-id cluster)]
                         (when cmd (spawn-terminal! cmd instance)))))))))))

(fn disconnect! []
  "Cierra el terminal del tsh (si está abierto) y apaga el indicador."
  (when (and vim.g.tsh_buf (api.nvim_buf_is_valid vim.g.tsh_buf))
    (api.nvim_buf_delete vim.g.tsh_buf {:force true}))
  (set vim.g.tsh_buf nil)
  (set vim.g.tsh_connected nil)
  (vim.cmd :redrawstatus))

;; ── Query execution ──────────────────────────────
;; Mandamos la SQL al psql del terminal via chansend, con `\o file` para
;; redirigir el resultado a un archivo. Después leemos el archivo y lo
;; mostramos en un modal. El terminal sigue siendo psql interactivo —
;; las queries también quedan visibles ahí como side-effect.

(local query-output-file "/tmp/tsh-query-output.txt")

(fn term-job-id []
  (when (and vim.g.tsh_buf (api.nvim_buf_is_valid vim.g.tsh_buf))
    (let [(ok job) (pcall api.nvim_buf_get_var vim.g.tsh_buf :terminal_job_id)]
      (when ok job))))

(fn send-to-tsh [text]
  "Manda text + Enter al psql del terminal tsh."
  (let [job (term-job-id)]
    (when job (vfn.chansend job (.. text "\r")))))

(fn show-query-result [lines sql]
  "Modal flotante con el resultado de la query. q/<Esc> cierra."
  (let [buf (api.nvim_create_buf false true)
        all-lines (let [acc []]
                    ;; el sql header puede ser multilínea; split por \n
                    (each [_ l (ipairs (vim.split (.. "-- " sql) "\n" {:plain true}))]
                      (table.insert acc l))
                    (table.insert acc "")
                    (each [_ l (ipairs lines)]
                      ;; defensivo: alguna línea de readfile podría traer \r
                      (each [_ sub (ipairs (vim.split l "\n" {:plain true}))]
                        (table.insert acc sub)))
                    acc)
        width (math.min 120 (- vim.o.columns 4))
        height (math.min (math.max 6 (length all-lines)) (- vim.o.lines 6))
        row (math.floor (/ (- vim.o.lines height) 2))
        col (math.floor (/ (- vim.o.columns width) 2))]
    (api.nvim_buf_set_lines buf 0 -1 false all-lines)
    (api.nvim_set_option_value :modifiable false {:buf buf})
    (api.nvim_set_option_value :buftype :nofile {:buf buf})
    (let [win (api.nvim_open_win buf true
                                 {:relative :editor
                                  :width width :height height
                                  :row row :col col
                                  :style :minimal
                                  :border :rounded
                                  :title " query result "
                                  :title_pos :center})
          opts {:buffer buf :silent true :nowait true}
          close #(when (api.nvim_win_is_valid win)
                   (api.nvim_win_close win true))]
      (vim.keymap.set :n :q close opts)
      (vim.keymap.set :n :<Esc> close opts))))

(fn query [sql ?delay-ms]
  "Ejecuta sql en el psql del terminal y muestra el resultado en un modal.
  ?delay-ms (default 500) es cuánto esperar a que psql termine antes de leer."
  (if (not vim.g.tsh_connected)
    (vim.notify "tsh: no hay conexión activa" vim.log.levels.WARN)
    (do
      (send-to-tsh (.. "\\o " query-output-file))
      (send-to-tsh sql)
      (send-to-tsh "\\o")
      (vim.defer_fn
        (fn []
          (let [(ok content) (pcall vfn.readfile query-output-file)]
            (if (or (not ok) (= 0 (length content)))
              (vim.notify "tsh: no pude leer la salida — ¿query terminó? probá con más delay"
                          vim.log.levels.ERROR)
              (show-query-result content sql))))
        (or ?delay-ms 500)))))

;; ── Helpers de queries comunes ────────────────────

(fn count-policies []
  "Cantidad total de policies."
  (query "SELECT count(*) FROM policies;"))

;; ── Fetch estructurado vía \copy CSV ──────────────

(local csv-output-file "/tmp/tsh-csv-output.csv")

(fn parse-csv-line [line]
  "Split por comas. No maneja comas dentro de campos quoted — suficiente para
  resultados con counts y strings sin comas (typical para enums/types)."
  (vim.split line "," {:plain true}))

(fn fetch-rows [sql ?delay-ms callback]
  "Corre sql via \\copy TO csv, lee el archivo y llama (callback rows).
  rows = [{header value ...} ...]. callback con [] si no hay datos."
  (if (not vim.g.tsh_connected)
    (do (vim.notify "tsh: no hay conexión activa" vim.log.levels.WARN)
        (callback []))
    (let [flat-sql (-> sql
                       (string.gsub ";%s*$" "")
                       (string.gsub "%s*\n%s*" " "))
          copy-cmd (string.format "\\copy (%s) TO '%s' WITH (FORMAT csv, HEADER)"
                                  flat-sql csv-output-file)]
      (send-to-tsh copy-cmd)
      (vim.defer_fn
        (fn []
          (let [(ok content) (pcall vfn.readfile csv-output-file)]
            (if (or (not ok) (< (length content) 1))
              (do (vim.notify "tsh: fetch-rows sin datos" vim.log.levels.ERROR)
                  (callback []))
              (let [header (parse-csv-line (. content 1))
                    rows []]
                (for [i 2 (length content)]
                  (let [vals (parse-csv-line (. content i))
                        row {}]
                    (each [j h (ipairs header)]
                      (tset row h (. vals j)))
                    (table.insert rows row)))
                (callback rows)))))
        (or ?delay-ms 500)))))

;; ── Policy mappings (accepted suggestions) ────────

(local mappings-by-source-sql
  "SELECT 'FrameworkItem' AS reference_type, source, COUNT(*) AS count
   FROM policy_framework_item_mappings WHERE deleted_at IS NULL GROUP BY source
   UNION ALL
   SELECT 'Risk', source, COUNT(*)
   FROM policy_risk_mappings WHERE deleted_at IS NULL GROUP BY source
   UNION ALL
   SELECT 'RegulationItem', source, COUNT(*)
   FROM policy_regulation_item_mappings WHERE deleted_at IS NULL GROUP BY source
   UNION ALL
   SELECT 'AuditableEntity', source, COUNT(*)
   FROM policy_auditable_entity_mappings WHERE deleted_at IS NULL GROUP BY source
   UNION ALL
   SELECT 'ControlsDatum', source, COUNT(*)
   FROM policy_controls_datum_mappings WHERE deleted_at IS NULL GROUP BY source
   UNION ALL
   SELECT 'Policy', source, COUNT(*)
   FROM policy_policy_mappings WHERE deleted_at IS NULL GROUP BY source
   ORDER BY reference_type, count DESC")

(fn policy-mappings-by-source []
  "Resumen de policy mappings por reference_type y source. Útil para
  identificar qué valor de source corresponde a 'accepted from suggestion'
  (la otra cara de las dismissals)."
  (query (.. mappings-by-source-sql ";") 1500))

(fn clear-all-mappings! []
  "Soft-delete (deleted_at = NOW()) de TODOS los rows activos en los 5 join
  tables de policy mappings. Atómico (BEGIN/COMMIT), con confirmación."
  (if (not vim.g.tsh_connected)
    (vim.notify "tsh: no hay conexión activa" vim.log.levels.WARN)
    (let [tables ["policy_framework_item_mappings"
                  "policy_risk_mappings"
                  "policy_regulation_item_mappings"
                  "policy_auditable_entity_mappings"
                  "policy_controls_datum_mappings"]
          prompt (.. "Soft-delete TODOS los mappings activos de:\n  - "
                     (table.concat tables "\n  - ")
                     "\n\n¿Continuar?")
          choice (vfn.confirm prompt "&Sí\n&No" 2)]
      (when (= choice 1)
        (let [updates (icollect [_ t (ipairs tables)]
                        (.. "UPDATE " t " SET deleted_at = NOW() "
                            "WHERE deleted_at IS NULL;"))
              sql (.. "BEGIN;\n" (table.concat updates "\n") "\nCOMMIT;")]
          (query sql 1500))))))

;; ── Policy dismissals ─────────────────────────────

(local dismissals-summary-sql
  "SELECT reference_type, COUNT(*) AS count
   FROM policy_mapping_suggestion_dismissals
   WHERE deleted_at IS NULL
   GROUP BY reference_type
   ORDER BY count DESC")

(fn policy-dismissals-by-type []
  "Resumen de dismissals de policy_mapping_suggestion_dismissals agrupado
  por reference_type, contando solo las no borradas (deleted_at IS NULL)."
  (query (.. dismissals-summary-sql ";")))

(fn delete-dismissals! []
  "Modal con dismissals por reference_type + opción <ALL>. Al elegir, pide
  confirmación y hace soft-delete (UPDATE deleted_at = NOW())."
  (fetch-rows dismissals-summary-sql nil
    (fn [rows]
      (if (= 0 (length rows))
        (vim.notify "tsh: no hay dismissals activos" vim.log.levels.INFO)
        (let [total (do (var t 0)
                        (each [_ r (ipairs rows)]
                          (set t (+ t (or (tonumber r.count) 0))))
                        t)
              items [{:label (string.format "<ALL>  (%d)" total) :type :all}]]
          (each [_ r (ipairs rows)]
            (table.insert items
              {:label (string.format "%s  (%s)" r.reference_type r.count)
               :type r.reference_type}))
          (let [buf (api.nvim_create_buf false true)
                lines (icollect [_ it (ipairs items)] it.label)
                width (math.min 60 (- vim.o.columns 4))
                height (math.min (length lines) (math.max 4 (- vim.o.lines 8)))
                row-pos (math.floor (/ (- vim.o.lines height) 2))
                col-pos (math.floor (/ (- vim.o.columns width) 2))]
            (api.nvim_buf_set_lines buf 0 -1 false lines)
            (api.nvim_set_option_value :modifiable false {:buf buf})
            (api.nvim_set_option_value :buftype :nofile {:buf buf})
            (let [win (api.nvim_open_win buf true
                                         {:relative :editor
                                          :width width :height height
                                          :row row-pos :col col-pos
                                          :style :minimal
                                          :border :rounded
                                          :title " Borrar dismissals "
                                          :title_pos :center})
                  opts {:buffer buf :silent true :nowait true}
                  close #(when (api.nvim_win_is_valid win)
                           (api.nvim_win_close win true))]
              (api.nvim_win_set_cursor win [1 0])
              (vim.keymap.set :n :q close opts)
              (vim.keymap.set :n :<Esc> close opts)
              (vim.keymap.set :n :<CR>
                #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                       item (. items lnum)]
                   (when item
                     (close)
                     (let [target (if (= item.type :all)
                                    "TODOS los reference_type"
                                    (tostring item.type))
                           choice (vfn.confirm
                                    (.. "Soft-delete dismissals de "
                                        target "?")
                                    "&Sí\n&No"
                                    2)]
                       (when (= choice 1)
                         (let [where (if (= item.type :all)
                                       "deleted_at IS NULL"
                                       (string.format
                                         "deleted_at IS NULL AND reference_type = '%s'"
                                         (sql-escape item.type)))
                               sql (.. "UPDATE policy_mapping_suggestion_dismissals "
                                       "SET deleted_at = NOW() WHERE " where ";")]
                           (query sql))))))
                opts))))))))

(fn list-tables []
  "Lista las tablas del schema public."
  (query "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"
         1000))

(fn sql-escape [s]
  "Escapa comillas simples para usar en SQL inline."
  (string.gsub (or s "") "'" "''"))

(fn find-tables [?pattern]
  "Tablas del schema public que matcheen ?pattern (ILIKE). Sin pattern, todas."
  (let [p (sql-escape (or ?pattern "%"))]
    (query (string.format
             "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename ILIKE '%s' ORDER BY tablename;"
             p)
           1000)))

(fn describe-table [name]
  "Columnas + tipos + nullable de la tabla."
  (query (string.format
           "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '%s' ORDER BY ordinal_position;"
           (sql-escape name))
         1000))

(fn find-columns [pattern]
  "Busca columnas que matcheen pattern (ILIKE) en todas las tablas de public."
  (query (string.format
           "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND column_name ILIKE '%s' ORDER BY table_name;"
           (sql-escape pattern))
         1500))

(fn install-lualine! []
  "Agrega el indicador tsh a lualine_x. Idempotente — re-evaluar no duplica."
  (let [lualine (require :lualine)
        cfg (lualine.get_config)
        component {1 (fn []
                       (.. "🚀 tsh:" (or vim.g.tsh_connected "")))
                   :cond (fn [] (not= vim.g.tsh_connected nil))
                   :color {:fg "#a6e3a1"}}]
    (when (not vim.g.tsh_lualine_installed)
      (table.insert cfg.sections.lualine_x component)
      (lualine.setup cfg)
      (set vim.g.tsh_lualine_installed true))))

; (install-lualine!)
; (list-dbs)
; (pick-db (fn [db] (vim.notify (.. "elegiste " db))))
; (fetch-galaxy-id "sox-82749-develop")
; (connect! "Home › Cloud › Instances › PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop")
; (count-policies)
; (list-tables)
; (query "SELECT id, name FROM policies LIMIT 5;")
; (disconnect!)
; (find-tables "%policy_mapping%")
; (describe-table "policy_mapping_suggestion_dismissals")
; (find-columns "%dismiss%")
; (policy-dismissals-by-type)
; (delete-dismissals!)
; (clear-all-mappings!)

{: connect!
 : disconnect!
 : install-lualine!
 : query
 : count-policies
 : policy-dismissals-by-type
 : delete-dismissals!
 : policy-mappings-by-source
 : clear-all-mappings!
 : list-tables
 : find-tables
 : describe-table
 : find-columns}
