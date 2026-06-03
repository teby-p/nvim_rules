;; slack.fnl — lee Slack delegando en el CLI de Claude vía MCP, porque Optro requiere 
;; admin approval para apps pero no para mcp 🤷‍♂️
;; En este caso usar un modelo tiene sentido ya que trata con lenguaje natural.
;;
;; Setup: alcanza con tener `claude` en el PATH y autenticado. El MCP de
;; Slack ya viene configurado en tu workspace de Claude — no hace falta
;; crear apps, tokens, ni pedir permisos al admin.

(local api vim.api)
(local vfn vim.fn)

;; Canales por nombre (#general) o por ID. El MCP los resuelve.
(local channels
  ["#ped-policies-teamonly"])  ; TODO: reemplazar con tus canales

;; Ventana de tiempo (en horas) para considerar mensajes "recientes".
(local lookback-hours 24)

;; Subdomain de tu Slack — sale del URL del workspace en el browser.
(local workspace "auditboard")

;; Tu display name / handle en Slack — usado para filtrar tus propios mensajes
;; en show-reviews (no tiene sentido pedirte review a vos mismo).
(local me "Esteban Podesta")  ; TODO: ajustá si tu display name no es este

(local mcp-tools
  "mcp__claude_ai_Slack__slack_read_channel,mcp__claude_ai_Slack__slack_search_channels")

(local output-shape
  "[{\"channel\": {\"id\": \"C0XXXX\", \"name\": \"<nombre sin #>\"},
  \"messages\": [{\"user\": \"<display name>\",
                 \"text\": \"<texto>\",
                 \"time\": \"<HH:MM legible>\",
                 \"ts\": \"<timestamp Slack original, tipo 1717420200.123456>\",
                 \"pr_url\": \"<URL del PR si lo menciona, o null>\"}]}]")

(fn build-prompt [chans hours]
  (string.format
    "Para cada canal de Slack listado abajo, usá la herramienta
mcp__claude_ai_Slack__slack_read_channel para traer los mensajes de las
últimas %d horas. Si necesitás resolver un nombre a ID, usá
mcp__claude_ai_Slack__slack_search_channels primero.

Canales: %s

Devolveme EXCLUSIVAMENTE un JSON válido. Sin texto antes ni después, sin
bloques markdown (nada de ```). Forma exacta:

%s

Mensajes más nuevos primero. Si no hay mensajes, devolvé messages: []."
    hours (table.concat chans ", ") output-shape))

(fn build-review-prompt [chans hours]
  (string.format
    "Para cada canal de Slack listado abajo, usá la herramienta
mcp__claude_ai_Slack__slack_read_channel para traer los mensajes de las
últimas %d horas. Si necesitás resolver un nombre a ID, usá
mcp__claude_ai_Slack__slack_search_channels primero.

Canales: %s

Filtrá y devolveme SOLO los mensajes donde alguien (que NO sea %s) está
pidiendo review de un PR. Señales típicas:
- frases tipo \"can someone review\", \"PR ready\", \"reviews appreciated\",
  \"please review\", \"eyes on this PR\", \"needs review\", \"ready for review\"
- links a PRs de GitHub (github.com/.../pull/N)
- mensajes con un número de PR (#1234) en contexto de pedido

Ignorá: status updates, anuncios de merges, comentarios sobre código sin
pedido, Y CUALQUIER MENSAJE CUYO AUTHOR SEA %s (soy yo — no quiero ver mis
propios pedidos).

Devolveme EXCLUSIVAMENTE un JSON válido. Sin texto antes ni después, sin
bloques markdown. Forma exacta:

%s

Si un canal no tiene pedidos de review, devolvé messages: []."
    hours (table.concat chans ", ") me me output-shape))

(fn strip-fences [s]
  "Si claude metió el JSON dentro de ```...```, lo desenvuelve."
  (let [trimmed (vim.trim s)
        no-open (string.gsub trimmed "^```[%w]*\n?" "")
        no-close (string.gsub no-open "\n?```$" "")]
    (vim.trim no-close)))

(fn ask-claude [prompt label]
  "Corre `claude -p` con MCP de Slack permitido. Devuelve la tabla parseada."
  (vim.notify (string.format "🤖 %s (%d canal(es))…" label (length channels))
              vim.log.levels.INFO)
  (vim.cmd :redraw)
  (let [started (vim.uv.hrtime)
        out (vfn.system ["claude" "-p" prompt
                         "--output-format" "text"
                         "--allowed-tools" mcp-tools])
        elapsed-s (/ (- (vim.uv.hrtime) started) 1e9)]
    (if (not= 0 vim.v.shell_error)
      (do (vim.notify (.. "claude error: " out) vim.log.levels.ERROR) nil)
      (let [(ok parsed) (pcall vim.json.decode (strip-fences out))]
        (if (not ok)
          (do (vim.notify (.. "no pude parsear el output de claude:\n" out)
                          vim.log.levels.ERROR) nil)
          (do (vim.notify (string.format "✓ listo (%.1fs)" elapsed-s)
                          vim.log.levels.INFO)
              parsed))))))

(fn unread-all []
  "Mensajes recientes de los canales configurados."
  (ask-claude (build-prompt channels lookback-hours) "unread"))

(fn review-requests []
  "Mensajes que parecen pedir review de un PR."
  (ask-claude (build-review-prompt channels lookback-hours) "review requests"))

(fn slack-url [channel-id ts]
  "URL del mensaje en Slack — abre en browser o desktop (vía slack:// handler)."
  (string.format "https://%s.slack.com/archives/%s/p%s"
                 workspace channel-id (string.gsub (or ts "") "%." "")))

(fn nilable [x]
  "JSON null llega como vim.NIL; lo normalizamos a nil."
  (when (and x (not= x vim.NIL)) x))

(fn build-buffer [data]
  "Construye lineas + highlights + lnum→{channel-id, ts, pr-url}."
  (let [lines []
        hls []
        line->msg {}
        push! (fn [text hl]
                (table.insert lines text)
                (when hl
                  (table.insert hls
                    {:line (- (length lines) 1) :col-start 0
                     :col-end (length text) :hl hl})))
        attach! (fn [channel-id ts pr-url]
                  (tset line->msg (length lines)
                        {:channel-id channel-id :ts ts :pr-url pr-url}))]
    (each [_ ch (ipairs data)]
      (let [name (or (?. ch :channel :name) "?")
            id (or (?. ch :channel :id) "")
            msgs (or ch.messages [])]
        (push! (.. "#" name) :Title)
        (push! "" nil)
        (if (= 0 (length msgs))
          (do (push! "  (sin mensajes)" :Comment) (push! "" nil))
          (each [_ m (ipairs msgs)]
            (let [user (or m.user "?")
                  when-s (or m.time "")
                  pr (nilable m.pr_url)
                  slack-ts (or m.ts "")
                  header (if pr
                           (string.format "  @%s  %s  →  %s" user when-s pr)
                           (string.format "  @%s  %s" user when-s))]
              (push! header :Identifier)
              (attach! id slack-ts pr)
              (each [_ tline (ipairs (vim.split (or m.text "") "\n"))]
                (push! (.. "    " tline) nil)
                (attach! id slack-ts pr))
              (push! "" nil))))))
    {: lines : hls : line->msg}))

(fn render-modal [data title refresh-fn]
  "Modal flotante reutilizable para listas de mensajes de Slack."
  (when data
    (let [{: lines : hls : line->msg} (build-buffer data)
          buf (api.nvim_create_buf false true)
          width (math.min 100 (- vim.o.columns 4))
          separator (string.rep "─" width)
          help-text " <CR> abrir (PR si hay, si no Slack) · r refrescar · q cerrar"
          _ (do (table.insert lines separator)
                (table.insert hls
                  {:line (- (length lines) 1) :col-start 0
                   :col-end (length separator) :hl :Comment})
                (table.insert lines help-text)
                (table.insert hls
                  {:line (- (length lines) 1) :col-start 0
                   :col-end (length help-text) :hl :Comment}))
          height (math.max 10 (math.min (length lines) (- vim.o.lines 6)))
          row (math.floor (/ (- vim.o.lines height) 2))
          col (math.floor (/ (- vim.o.columns width) 2))
          ns (api.nvim_create_namespace :slack)]
      (api.nvim_buf_set_lines buf 0 -1 false lines)
      (each [_ h (ipairs hls)]
        (api.nvim_buf_set_extmark buf ns h.line h.col-start
                                 {:end_col h.col-end :hl_group h.hl}))
      (api.nvim_set_option_value :modifiable false {:buf buf})
      (api.nvim_set_option_value :buftype :nofile {:buf buf})
      (api.nvim_set_option_value :filetype :slack {:buf buf})
      (let [win (api.nvim_open_win buf true
                                   {:relative :editor
                                    :width width
                                    :height height
                                    :row row
                                    :col col
                                    :style :minimal
                                    :border :rounded
                                    : title
                                    :title_pos :center})
            opts {:buffer buf :silent true :nowait true}
            close #(when (api.nvim_win_is_valid win)
                     (api.nvim_win_close win true))]
        (api.nvim_set_option_value :wrap true {:win win})
        (api.nvim_win_set_cursor win [1 0])
        (vim.keymap.set :n :q close opts)
        (vim.keymap.set :n :<Esc> close opts)
        (vim.keymap.set :n :<CR>
                        #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                               msg (. line->msg lnum)]
                           (when msg
                             (vim.ui.open
                               (or msg.pr-url
                                   (slack-url msg.channel-id msg.ts)))))
                        opts)
        (vim.keymap.set :n :r #(do (close) (refresh-fn)) opts)))))

(fn show-slack []
  "Modal con mensajes recientes de los canales configurados."
  (render-modal (unread-all) " Slack " show-slack))

(fn show-reviews []
  "Modal con pedidos de review de PRs detectados en los canales."
  (render-modal (review-requests) " Review requests " show-reviews))

; (show-slack)
; (show-reviews)

{: unread-all : review-requests : show-slack : show-reviews}
