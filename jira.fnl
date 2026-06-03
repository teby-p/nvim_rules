;; jira.fnl — funciones Jira via REST API
;;
;; Setup (una vez). Token se genera en
;; https://id.atlassian.com/manage-profile/security/api-tokens
;;
;; Opcion A — macOS Keychain (recomendado):
;;   security add-generic-password -a "$USER" -s jira-email -w 'tu@auditboard.com'
;;   security add-generic-password -a "$USER" -s jira-api-token -w 'TU_TOKEN'
;;
;; Opcion B — env vars (en ~/.zshenv para que persistan en cualquier shell):
;;   echo 'export JIRA_EMAIL=tu@auditboard.com' >> ~/.zshenv
;;   echo 'export JIRA_API_TOKEN=tu-token'      >> ~/.zshenv

(local api vim.api)
(local vfn vim.fn)

(local base-url "https://auditboard.atlassian.net")

(fn read-keychain [service]
  "Lee un secreto del Keychain de macOS. Devuelve nil si no existe."
  (let [user (os.getenv "USER")
        out (vfn.system ["security" "find-generic-password"
                         "-a" user "-s" service "-w"])]
    (when (= 0 vim.v.shell_error)
      (vim.trim out))))

(fn auth-header []
  (let [email (or (os.getenv "JIRA_EMAIL") (read-keychain "jira-email"))
        token (or (os.getenv "JIRA_API_TOKEN") (read-keychain "jira-api-token"))]
    (when (and email token)
      (.. "Basic " (vim.base64.encode (.. email ":" token))))))

(fn search [jql]
  "Ejecuta una busqueda JQL contra Jira Cloud."
  (let [auth (auth-header)]
    (if (not auth)
      (do (vim.notify "Faltan credenciales — ver header de jira.fnl"
                      vim.log.levels.ERROR) nil)
      (let [body (vim.json.encode
                   {:jql jql
                    :fields ["summary" "status" "priority" "issuetype"]
                    :maxResults 50})
            out (vfn.system ["curl" "-sS" "-X" "POST"
                             "-H" (.. "Authorization: " auth)
                             "-H" "Content-Type: application/json"
                             "-H" "Accept: application/json"
                             "-d" body
                             (.. base-url "/rest/api/3/search/jql")])]
        (if (not= 0 vim.v.shell_error)
          (do (vim.notify (.. "jira curl error: " out) vim.log.levels.ERROR) nil)
          (let [parsed (vim.json.decode out)]
            (if parsed.errorMessages
              (do (vim.notify (.. "jira: " (vim.inspect parsed.errorMessages))
                              vim.log.levels.ERROR) nil)
              parsed)))))))

(fn my-issues []
  "Tickets asignados a mi que no esten Done."
  (search "assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC"))

; (my-issues)

(fn extract-jira-key [title]
  "Busca un key tipo SOX-1234 en el título del PR."
  (string.match (or title "") "[A-Z][A-Z0-9]+%-%d+"))

(fn build-jira-lookup []
  "Devuelve mapa key → status. Silencioso si Jira falla."
  (let [lookup {}
        data (my-issues)]
    (each [_ issue (ipairs (or (?. data :issues) []))]
      (tset lookup issue.key (or (?. issue :fields :status :name) "?")))
    lookup))

(fn type-icon [type-name]
  (case type-name
    :Bug "🐛"
    :Task "✅"
    :Story "📖"
    :Epic "🚀"
    "Sub-task" "↳"
    _ "•"))

(fn priority-hl [p]
  (case p
    :Highest :DiagnosticError
    :High :DiagnosticError
    :Medium :DiagnosticWarn
    :Low :Comment
    :Lowest :Comment
    _ :Comment))

(local lines-per-issue 3)

(fn build-issue-block [issue]
  (let [key issue.key
        fields (or issue.fields {})
        summary (or fields.summary "")
        status (or (?. fields :status :name) "?")
        priority (or (?. fields :priority :name) "?")
        issuetype (or (?. fields :issuetype :name) "?")
        icon (type-icon issuetype)
        status-text (.. "[" status "]")
        line0 (.. key "  " icon "  " status-text "  " priority)
        line1 (.. "  " summary)
        hls []
        key-end (length key)
        icon-start (+ key-end 2)
        icon-end (+ icon-start (length icon))
        status-start (+ icon-end 2)
        status-end (+ status-start (length status-text))
        prio-start (+ status-end 2)
        prio-end (+ prio-start (length priority))]
    (table.insert hls {:line 0 :col-start 0 :col-end key-end :hl :Number})
    (table.insert hls {:line 0 :col-start status-start :col-end status-end :hl :Function})
    (table.insert hls {:line 0 :col-start prio-start :col-end prio-end :hl (priority-hl priority)})
    {:lines [line0 line1 ""] : hls}))

(fn show-issues []
  "Modal flotante con mis tickets de Jira.
  q/<Esc>: cerrar  <CR>: abrir en browser  r: refrescar"
  (let [data (my-issues)]
    (when data
      (let [issues (or data.issues [])]
        (if (= 0 (length issues))
          (vim.notify "Sin tickets asignados" vim.log.levels.INFO)
          (let [all-lines []
                all-hls []]
            (each [_ issue (ipairs issues)]
              (let [block (build-issue-block issue)
                    base (length all-lines)]
                (each [_ l (ipairs block.lines)]
                  (table.insert all-lines l))
                (each [_ h (ipairs block.hls)]
                  (table.insert all-hls
                    {:line (+ base h.line) :col-start h.col-start
                     :col-end h.col-end :hl h.hl}))))
            (let [buf (api.nvim_create_buf false true)
                  width (math.min 100 (- vim.o.columns 4))
                  separator (string.rep "─" width)
                  help-text " <CR> abrir · r refrescar · q cerrar"
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
                  ns (api.nvim_create_namespace :jira)]
              (api.nvim_buf_set_lines buf 0 -1 false all-lines)
              (each [_ h (ipairs all-hls)]
                (api.nvim_buf_set_extmark buf ns h.line h.col-start
                                         {:end_col h.col-end :hl_group h.hl}))
              (api.nvim_set_option_value :modifiable false {:buf buf})
              (api.nvim_set_option_value :buftype :nofile {:buf buf})
              (api.nvim_set_option_value :filetype :jira {:buf buf})
              (let [win (api.nvim_open_win buf true
                                           {:relative :editor
                                            :width width
                                            :height height
                                            :row row
                                            :col col
                                            :style :minimal
                                            :border :rounded
                                            :title " Mis tickets "
                                            :title_pos :center})
                    opts {:buffer buf :silent true :nowait true}
                    close #(when (api.nvim_win_is_valid win)
                             (api.nvim_win_close win true))
                    cursor->issue #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                                         idx (+ (math.floor (/ (- lnum 1) lines-per-issue)) 1)]
                                     (. issues idx))]
                (api.nvim_win_set_cursor win [1 0])
                (vim.keymap.set :n :q close opts)
                (vim.keymap.set :n :<Esc> close opts)
                (vim.keymap.set :n :<CR>
                                #(let [issue (cursor->issue)]
                                   (when issue
                                     (close)
                                     (vim.ui.open (.. base-url "/browse/" issue.key))))
                                opts)
                (vim.keymap.set :n :r #(do (close) (show-issues)) opts)))))))))

; (show-issues)

{: my-issues
 : extract-jira-key
 : build-jira-lookup}
