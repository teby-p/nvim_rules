;; tsh.fnl — helpers para conectarse a la DB de un PR deploy vía Teleport.

(local api vim.api)
(local vfn vim.fn)

(fn parse-instance-breadcrumb [s]
  "Extrae cluster e instancia del string breadcrumb de Galaxy. Acepta tanto el
  breadcrumb entero como solo el último segmento — el regex se ancla al
  '(pr-X / region)' en el medio y al '/ word$' al final, ignora el prefijo.
  Ejemplos válidos:
    'Home › Cloud › Instances › PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop'
    'PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop'
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
  "Modal flotante con las DBs registradas. Llama (on-select db-name) al elegir.
  ASYNC: la UI corre via keymaps, no bloquea el caller. Si necesitás sync
  (e.g. para encadenar con vim.wait), usá pick-db-sync."
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

(fn flush-typeahead! []
  "Consume cualquier input pendiente. Necesario antes de inputlist/input cuando
  se invocan desde un eval-via-keymap (Conjure), o el typeahead los responde
  con 0 antes de que veas el prompt."
  (var continue true)
  (while continue
    (let [(ok ch) (pcall vim.fn.getchar 0)]
      (when (or (not ok) (= ch 0))
        (set continue false)))))

(fn pick-db-sync []
  "Picker síncrono via vim.fn.inputlist (cmdline). Bloquea el editor — usar
  cuando necesitás encadenar con vim.wait. Devuelve el nombre elegido o nil
  (cancelado / sin DBs)."
  (let [names (list-dbs)]
    (if (or (not names) (= 0 (length names)))
      (do (vim.notify "tsh: no hay DBs registradas — ¿corriste `tsh login`?"
                      vim.log.levels.WARN)
          nil)
      (let [prompt-list ["Elegí DB (número, 0 cancela):"]]
        (each [i n (ipairs names)]
          (table.insert prompt-list (string.format "%d. %s" i n)))
        (flush-typeahead!)
        (vim.cmd "redraw")
        (let [choice (vim.fn.inputlist prompt-list)]
          (when (and (>= choice 1) (<= choice (length names)))
            (. names choice)))))))

(fn cluster-prefix [cluster]
  "Strippea el último segmento del cluster Galaxy (el team) y devuelve el
  prefijo con guión al final, listo para matchar contra los DBs Teleport
  (que usan sufijo load-balanced).
  'pr-us-west-2-tennis' → 'pr-us-west-2-'
  Devuelve nil si no hay al menos 2 segmentos."
  (let [parts (vim.split cluster "-" {:plain true})
        n (length parts)]
    (when (> n 1)
      (let [keep []]
        (for [i 1 (- n 1)]
          (table.insert keep (. parts i)))
        (.. (table.concat keep "-") "-")))))

(fn auto-match-cluster [breadcrumb]
  "Resuelve la DB de Teleport para un breadcrumb de Galaxy. Estrategias:
   1. Match exacto: el cluster del breadcrumb existe tal cual en `tsh db ls`.
   2. Match por prefijo: Galaxy usa 'pr-<region>-<team>' (ej. pr-us-west-2-tennis)
      y Teleport usa 'pr-<region>-a-0' (load-balanced). Strippeamos el team y
      buscamos la primera DB que arranque con ese prefijo.
   Devuelve nil si nada matchea."
  (let [{:cluster bc-cluster} (parse-instance-breadcrumb breadcrumb)
        names (list-dbs)]
    (when (and bc-cluster names (> (length names) 0))
      (var found nil)
      ;; 1. exact match
      (each [_ n (ipairs names)]
        (when (and (not found) (= n bc-cluster))
          (set found n)))
      ;; 2. prefix match
      (when (not found)
        (let [prefix (cluster-prefix bc-cluster)]
          (when prefix
            (each [_ n (ipairs names)]
              (when (and (not found) (= 1 (string.find n prefix 1 true)))
                (set found n))))))
      found)))

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

(fn prompt-ready? [term-buf]
  "true si las últimas líneas del buffer terminan en un prompt psql (=> o =#).
  Usado por connect! para saber cuándo tsh terminó de autenticar."
  (if (or (not term-buf) (not (api.nvim_buf_is_valid term-buf)))
    false
    (let [lines (api.nvim_buf_get_lines term-buf -10 -1 false)]
      (var found false)
      (each [_ line (ipairs lines)]
        (when (and (not found) (string.match line "=[>#]%s*$"))
          (set found true)))
      found)))

(fn connect! [breadcrumb ?galaxy-id ?cluster]
  "Spawn de `tsh db connect` en split-terminal + vim.wait hasta el prompt psql.
  Resolución del cluster: 1) ?cluster si lo pasás; 2) auto-match (el cluster
  del breadcrumb existe como DB en tsh); 3) picker síncrono via inputlist.
  Devuelve true si conectó OK, false si cancelaste o timeout (90s). Si no pasás
  ?galaxy-id, lo busca solo via el PR Deploy Bot comment."
  (if vim.g.tsh_connected
    (do (vim.notify (.. "tsh: ya hay conexión activa con " vim.g.tsh_connected
                        ". Disconnect primero.")
                    vim.log.levels.WARN)
        false)
    (let [{: instance} (parse-instance-breadcrumb breadcrumb)]
      (if (not instance)
        (do (vim.notify (.. "tsh: no pude parsear el breadcrumb: " breadcrumb)
                        vim.log.levels.ERROR)
            false)
        (let [galaxy-id (or ?galaxy-id
                            (do (vim.notify (.. "🔎 buscando galaxy-id para "
                                                instance "…")
                                            vim.log.levels.INFO)
                                (vim.cmd :redraw)
                                (fetch-galaxy-id instance)))]
          (if (not galaxy-id)
            (do (vim.notify (.. "tsh: no pude encontrar el galaxy-id para " instance)
                            vim.log.levels.ERROR)
                false)
            (let [cluster (or ?cluster
                              (auto-match-cluster breadcrumb)
                              (pick-db-sync))]
              (if (not cluster)
                (do (vim.notify "tsh: picker cancelado / sin cluster" vim.log.levels.INFO) false)
                (let [cmd (build-command breadcrumb galaxy-id cluster)]
                  (if (not cmd)
                    (do (vim.notify "tsh: no se pudo armar el comando"
                                    vim.log.levels.ERROR)
                        false)
                    (do (spawn-terminal! cmd instance)
                        (vim.notify (.. "⏳ esperando prompt psql para " instance "…")
                                    vim.log.levels.INFO)
                        (let [ok? (vim.wait 90000
                                            #(prompt-ready? vim.g.tsh_buf)
                                            100)]
                          (if ok?
                            (do (vim.notify (.. "✓ tsh conectado: " instance)
                                            vim.log.levels.INFO)
                                true)
                            (do (vim.notify (.. "tsh: timeout (90s) esperando prompt psql para "
                                                instance)
                                            vim.log.levels.WARN)
                                false))))))))))))))

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

;; NOTA: lo de policy mappings/dismissals/replicate vive en mappings.fnl ahora.

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
{: connect!
 : disconnect!
 : install-lualine!
 : query
 : fetch-rows
 : send-to-tsh
 : sql-escape
 : count-policies
 : list-tables
 : find-tables
 : describe-table
 : find-columns
 ;; ── exports para debug / uso avanzado ─────────────
 : parse-instance-breadcrumb
 : list-dbs
 : auto-match-cluster
 : pick-db
 : pick-db-sync
 : prompt-ready?
 : fetch-galaxy-id}
