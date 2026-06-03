;; prs.fnl — funciones GitHub via `gh`

(local api vim.api)
(local vfn vim.fn)

;; require :jira no funciona porque busca jira.lua; usamos fennel.dofile
;; con path absoluto. Re-ejecuta el archivo cada vez, así los cambios en
;; jira.fnl se ven al re-evaluar este bloque.
(local jira ((. (require :fennel) :dofile)
             "/Users/epodesta/Development/escort/jira.fnl"))

(fn my-prs []
  "Devuelve mis PRs abiertos como lista de tablas."
  (let [out (vfn.system
              "gh search prs --author=@me --state=open --json number,title,url,repository,createdAt --limit 50")]
    (if (not= 0 vim.v.shell_error)
      (do (vim.notify (.. "gh error: " out) vim.log.levels.ERROR) nil)
      (vim.json.decode out))))

; (my-prs)

;; ── PR details (CI + review threads) via GraphQL ───

(local pr-detail-tpl
  "pullRequest(number: %d) {
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    reviewThreads(first: 100) { nodes { isResolved isOutdated } }
  }")

(fn build-batch-query [prs]
  "Una sola query GraphQL con un alias por PR."
  (let [parts []]
    (each [i pr (ipairs prs)]
      (let [name-with-owner (?. pr :repository :nameWithOwner)]
        (when name-with-owner
          (let [parts2 (vim.split name-with-owner "/")
                owner (. parts2 1)
                repo (. parts2 2)e
            (table.insert parts
              (string.format "pr%d: repository(owner: %q, name: %q) { %s }"
                             i owner repo
                             (string.format pr-detail-tpl pr.number)))))))
    (.. "query { " (table.concat parts " ") " }")))

(fn fetch-batch-details [prs]
  "Devuelve lista de {:ci :unresolved :outdated} en el mismo orden que prs."
  (if (= 0 (length prs))
    []
    (let [q (build-batch-query prs)
          out (vfn.system ["gh" "api" "graphql" "-f" (.. "query=" q)])]
      (if (not= 0 vim.v.shell_error)
        (do (vim.notify (.. "gh graphql error: " out) vim.log.levels.ERROR) [])
        (let [data (?. (vim.json.decode out) :data)
              result []]
          (each [i _ (ipairs prs)]
            (let [pr-data (?. data (.. "pr" i) :pullRequest)
                  ci (?. pr-data :commits :nodes 1 :commit :statusCheckRollup :state)
                  threads (or (?. pr-data :reviewThreads :nodes) [])]
              (var u 0)
              (var o 0)
              (each [_ t (ipairs threads)]
                (when (not t.isResolved) (set u (+ u 1)))
                (when t.isOutdated (set o (+ o 1))))
              (table.insert result {:ci ci :unresolved u :outdated o})))
          result)))))

;; ── Comments view ─────────────────────────────────

(local comments-query
  "query($owner: String!, $repo: String!, $number: Int!) {
     repository(owner: $owner, name: $repo) {
       pullRequest(number: $number) {
         reviewThreads(first: 100) {
           nodes {
             isResolved isOutdated path line
             comments(first: 20) {
               nodes { author { login } body }
             }
           }
         }
       }
     }
   }")

(fn fetch-pr-comments [owner repo number]
  (let [out (vfn.system
              ["gh" "api" "graphql"
               "-f" (.. "query=" comments-query)
               "-f" (.. "owner=" owner)
               "-f" (.. "repo=" repo)
               "-F" (.. "number=" (tostring number))])]
    (if (not= 0 vim.v.shell_error)
      (do (vim.notify (.. "gh error: " out) vim.log.levels.ERROR) nil)
      (?. (vim.json.decode out) :data :repository :pullRequest :reviewThreads :nodes))))

(fn build-comments-buffer [pr threads]
  "Construye lineas + highlights para el modal de comentarios."
  (let [active []
        old []
        lines []
        hls []
        push! (fn [text hl]
                (table.insert lines text)
                (when hl
                  (table.insert hls
                    {:line (- (length lines) 1) :col-start 0
                     :col-end (length text) :hl hl})))
        push-thread! (fn [t]
                       (push! (string.format "  %s:%s"
                                             (or t.path "?")
                                             (tostring (or t.line "")))
                              :Directory)
                       (each [_ c (ipairs (or (?. t :comments :nodes) []))]
                         (let [author (or (?. c :author :login) "?")
                               body-lines (vim.split (or c.body "") "\n")]
                           (push! (.. "    @" author) :Identifier)
                           (each [_ bl (ipairs body-lines)]
                             (push! (.. "      " bl) nil))))
                       (push! "" nil))]
    (each [_ t (ipairs threads)]
      (if t.isOutdated
        (table.insert old t)
        (when (not t.isResolved)
          (table.insert active t))))
    (push! (string.format "#%d  %s" pr.number pr.title) :Title)
    (push! (.. "  " (or (?. pr :repository :nameWithOwner) "?")) :Function)
    (push! "" nil)
    (push! (string.format "═══ Sin resolver (%d) ═══" (length active)) :DiagnosticWarn)
    (push! "" nil)
    (if (= 0 (length active))
      (do (push! "  (ninguno)" :Comment) (push! "" nil))
      (each [_ t (ipairs active)] (push-thread! t)))
    (push! (string.format "═══ Outdated (%d) ═══" (length old)) :Comment)
    (push! "" nil)
    (if (= 0 (length old))
      (push! "  (ninguno)" :Comment)
      (each [_ t (ipairs old)] (push-thread! t)))
    {: lines : hls}))

(fn show-pr-comments [pr return-fn]
  "Modal con comentarios del PR separados en sin-resolver y outdated."
  (let [name-with-owner (?. pr :repository :nameWithOwner)]
    (when name-with-owner
      (let [parts (vim.split name-with-owner "/")
            owner (. parts 1)
            repo (. parts 2)
            threads (fetch-pr-comments owner repo pr.number)]
        (when threads
          (let [{:lines all-lines :hls all-hls} (build-comments-buffer pr threads)
                buf (api.nvim_create_buf false true)
                width (math.min 100 (- vim.o.columns 4))
                height (math.max 10 (math.min (length all-lines) (- vim.o.lines 6)))
                row (math.floor (/ (- vim.o.lines height) 2))
                col (math.floor (/ (- vim.o.columns width) 2))
                ns (api.nvim_create_namespace :pr-comments)]
            (api.nvim_buf_set_lines buf 0 -1 false all-lines)
            (each [_ h (ipairs all-hls)]
              (api.nvim_buf_set_extmark buf ns h.line h.col-start
                                       {:end_col h.col-end :hl_group h.hl}))
            (api.nvim_set_option_value :modifiable false {:buf buf})
            (api.nvim_set_option_value :buftype :nofile {:buf buf})
            (api.nvim_set_option_value :filetype :prcomments {:buf buf})
            (let [win (api.nvim_open_win buf true
                                         {:relative :editor
                                          :width width
                                          :height height
                                          :row row
                                          :col col
                                          :style :minimal
                                          :border :rounded
                                          :title (string.format " Comments #%d " pr.number)
                                          :title_pos :center})
                  opts {:buffer buf :silent true :nowait true}
                  close #(when (api.nvim_win_is_valid win)
                           (api.nvim_win_close win true))]
              (api.nvim_set_option_value :wrap true {:win win})
              (vim.keymap.set :n :q #(do (close) (when return-fn (return-fn))) opts)
              (vim.keymap.set :n :<Esc> close opts))))))))

(fn ci-icon [state]
  (case state
    :SUCCESS "🟢"
    :FAILURE "🔴"
    :ERROR "🔴"
    :PENDING "🟡"
    :EXPECTED "🟡"
    _ "⚪"))

(fn ci-hl [state]
  (case state
    :SUCCESS :DiagnosticOk
    :FAILURE :DiagnosticError
    :ERROR :DiagnosticError
    :PENDING :DiagnosticWarn
    :EXPECTED :DiagnosticWarn
    _ :Comment))

;; Cada PR ocupa 5 líneas: header, título, counts, jira, separador en blanco.
(local lines-per-pr 5)

(fn build-pr-block [pr d jira-lookup]
  "Devuelve {:lines [...] :hls [{:line :col-start :col-end :hl}]} para un PR."
  (let [icon (ci-icon (?. d :ci))
        repo (or (?. pr :repository :nameWithOwner) "?")
        unr (or (?. d :unresolved) 0)
        out (or (?. d :outdated) 0)
        num-str (string.format "#%d" pr.number)
        jira-key (jira.extract-jira-key pr.title)
        jira-status (and jira-key (. jira-lookup jira-key))
        line0 (.. num-str "  " icon "  " repo)
        line1 (.. "  " pr.title)
        line2 (.. "  💬 " (string.format "%d unresolved · %d outdated" unr out))
        line3 (if jira-status
                (string.format "  🎫 %s [%s]" jira-key jira-status)
                "")
        hls []
        icon-start (+ (length num-str) 2)
        icon-end (+ icon-start (length icon))
        repo-start (+ icon-end 2)
        repo-end (+ repo-start (length repo))]
    (table.insert hls {:line 0 :col-start 0 :col-end (length num-str) :hl :Number})
    (table.insert hls {:line 0 :col-start icon-start :col-end icon-end :hl (ci-hl (?. d :ci))})
    (table.insert hls {:line 0 :col-start repo-start :col-end repo-end :hl :Function})
    (table.insert hls {:line 2 :col-start 0 :col-end (length line2) :hl :Comment})
    (when jira-status
      (let [hl (if (= jira-status "On Hold") :DiagnosticWarn :DiagnosticInfo)]
        (table.insert hls {:line 3 :col-start 0 :col-end (length line3) :hl hl})))
    {:lines [line0 line1 line2 line3 ""] : hls}))

(fn show-prs []
  "Modal flotante con mis PRs + CI + comentarios.
  q/<Esc>: cerrar  <CR>: abrir en browser  r: refrescar"
  (let [prs (my-prs)]
    (when prs
      (if (= 0 (length prs))
        (vim.notify "Sin PRs abiertos" vim.log.levels.INFO)
        (let [details (fetch-batch-details prs)
              jira-lookup (jira.build-jira-lookup)
              all-lines []
              all-hls []]
          (each [i pr (ipairs prs)]
            (let [block (build-pr-block pr (or (. details i) {}) jira-lookup)
                  base (length all-lines)]
              (each [_ l (ipairs block.lines)]
                (table.insert all-lines l))
              (each [_ h (ipairs block.hls)]
                (table.insert all-hls
                  {:line (+ base h.line) :col-start h.col-start :col-end h.col-end :hl h.hl}))))
          (let [buf (api.nvim_create_buf false true)
                width (math.min 90 (- vim.o.columns 4))
                separator (string.rep "─" width)
                help-text " <CR> abrir · c comments · r refrescar · q cerrar"
                push-footer! (fn []
                               (table.insert all-lines separator)
                               (table.insert all-hls
                                 {:line (- (length all-lines) 1) :col-start 0
                                  :col-end (length separator) :hl :Comment})
                               (table.insert all-lines help-text)
                               (table.insert all-hls
                                 {:line (- (length all-lines) 1) :col-start 0
                                  :col-end (length help-text) :hl :Comment}))
                _ (push-footer!)
                height (math.min (length all-lines) (math.max 4 (- vim.o.lines 6)))
                row (math.floor (/ (- vim.o.lines height) 2))
                col (math.floor (/ (- vim.o.columns width) 2))
                ns (api.nvim_create_namespace :prs)]
            (api.nvim_buf_set_lines buf 0 -1 false all-lines)
            (each [_ h (ipairs all-hls)]
              (api.nvim_buf_set_extmark buf ns h.line h.col-start
                                       {:end_col h.col-end :hl_group h.hl}))
            (api.nvim_set_option_value :modifiable false {:buf buf})
            (api.nvim_set_option_value :buftype :nofile {:buf buf})
            (api.nvim_set_option_value :filetype :prs {:buf buf})
            (let [win (api.nvim_open_win buf true
                                         {:relative :editor
                                          :width width
                                          :height height
                                          :row row
                                          :col col
                                          :style :minimal
                                          :border :rounded
                                          :title " PRs abiertos "
                                          :title_pos :center})
                  opts {:buffer buf :silent true :nowait true}
                  close #(when (api.nvim_win_is_valid win)
                           (api.nvim_win_close win true))
                  cursor->pr #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                                    idx (+ (math.floor (/ (- lnum 1) lines-per-pr)) 1)]
                                (. prs idx))]
              (api.nvim_win_set_cursor win [1 0])
              (vim.keymap.set :n :q close opts)
              (vim.keymap.set :n :<Esc> close opts)
              (vim.keymap.set :n :<CR>
                              #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                                     idx (+ (math.floor (/ (- lnum 1) lines-per-pr)) 1)
                                     offset (% (- lnum 1) lines-per-pr)
                                     pr (. prs idx)
                                     jira-key (and pr (jira.extract-jira-key pr.title))]
                                 (when pr
                                   (if (and (= offset 3) jira-key)
                                     (vim.ui.open (.. "https://auditboard.atlassian.net/browse/" jira-key))
                                     (vim.ui.open pr.url))))
                              opts)
              (vim.keymap.set :n :c
                              #(let [pr (cursor->pr)]
                                 (when pr (close) (show-pr-comments pr show-prs)))
                              opts)
              (vim.keymap.set :n :r #(do (close) (show-prs)) opts))))))))

; (show-prs)
