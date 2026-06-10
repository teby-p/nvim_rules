;; docker.fnl — helpers para containers locales del dev-env.

(local api vim.api)
(local vfn vim.fn)

(fn run [args]
  "Corre `docker <args>` sincrónicamente. Devuelve (values ok? output)."
  (let [cmd (vim.list_extend [:docker] args)
        out (vfn.system cmd)]
    (values (= 0 vim.v.shell_error) (or out ""))))

(fn show-output [title lines]
  "Modal flotante con `lines`. q/<Esc> cierra."
  (let [buf (api.nvim_create_buf false true)
        width (math.min 120 (- vim.o.columns 4))
        height (math.min (math.max 6 (length lines)) (- vim.o.lines 6))
        row (math.floor (/ (- vim.o.lines height) 2))
        col (math.floor (/ (- vim.o.columns width) 2))]
    (api.nvim_buf_set_lines buf 0 -1 false lines)
    (api.nvim_set_option_value :modifiable false {:buf buf})
    (api.nvim_set_option_value :buftype :nofile {:buf buf})
    (let [win (api.nvim_open_win buf true
                                 {:relative :editor
                                  :width width :height height
                                  :row row :col col
                                  :style :minimal
                                  :border :rounded
                                  : title
                                  :title_pos :center})
          opts {:buffer buf :silent true :nowait true}
          close #(when (api.nvim_win_is_valid win)
                   (api.nvim_win_close win true))]
      (vim.keymap.set :n :q close opts)
      (vim.keymap.set :n :<Esc> close opts))))

;; ── Acciones ──────────────────────────────────────

(fn container-state [name]
  "Devuelve el `.State.Status` (running/exited/...) del container, o nil si no existe."
  (let [(ok? out) (run [:inspect name :--format "{{.State.Status}}"])]
    (when ok? (vim.trim out))))

(fn ensure-running! [name lines]
  "Si el container está exited/created, lo arranca. Si no existe, registra error.
  Si ya corre, no hace nada. Anota el resultado en `lines`."
  (let [state (container-state name)]
    (case state
      :running (table.insert lines (.. "= " name " (running)"))
      nil (table.insert lines (.. "✗ " name " (no existe)"))
      _ (let [(ok? out) (run [:start name])]
          (table.insert lines
            (if ok?
              (.. "▶ " name " (era " state ")")
              (.. "✗ start " name " — " (vim.trim out))))))))

(fn restart-containers! [names]
  "Restartea cada container de `names` (lista de strings) y reporta en un modal."
  (let [lines []]
    (each [_ name (ipairs names)]
      (vim.notify (.. "🔄 docker restart " name) vim.log.levels.INFO)
      (vim.cmd :redraw)
      (let [(ok? out) (run [:restart name])]
        (table.insert lines
          (if ok?
            (.. "✓ " name)
            (.. "✗ " name " — " (vim.trim out))))))
    (show-output " docker restart " lines)))

(fn fix-rag! []
  "Cura el ECONNRESET / socket hang up contra `http://localhost:8000/rag/recommend`.
  El endpoint vive en ab_mlservice_local, que depende de redisearch-server
  (mismo docker network `machine-learning_default`). Si redisearch está caído,
  ab_mlservice_local arranca pero se queda 720s esperando a redis y termina
  cerrando el socket → ECONNRESET. Pasos:
    1. ensure redisearch-server up (start si está exited).
    2. restart ab_mlservice_local + ab_mlworker_local para romper el wait-loop."
  (let [lines []]
    (vim.notify "🔎 chequeando redisearch-server…" vim.log.levels.INFO)
    (vim.cmd :redraw)
    (ensure-running! :redisearch-server lines)
    (each [_ name (ipairs [:ab_mlservice_local :ab_mlworker_local])]
      (vim.notify (.. "🔄 docker restart " name) vim.log.levels.INFO)
      (vim.cmd :redraw)
      (let [(ok? out) (run [:restart name])]
        (table.insert lines
          (if ok?
            (.. "✓ restart " name)
            (.. "✗ restart " name " — " (vim.trim out))))))
    (show-output " fix-rag! " lines)))

;; ── Inspección ────────────────────────────────────

(fn ps []
  "Modal con los containers corriendo."
  (let [(ok? out) (run [:ps :--format
                        "table {{.Names}}\t{{.Status}}\t{{.Ports}}"])]
    (if (not ok?)
      (vim.notify (.. "docker ps error: " out) vim.log.levels.ERROR)
      (show-output " docker ps "
                   (vim.split (vim.trim out) "\n" {:plain true})))))

(fn logs [container ?n]
  "Modal con las últimas ?n (default 200) líneas de logs del container."
  (let [n (tostring (or ?n 200))
        (ok? out) (run [:logs :--tail n container])]
    (if (not ok?)
      (vim.notify (.. "docker logs error: " out) vim.log.levels.ERROR)
      (show-output (.. " " container " — last " n " lines ")
                   (vim.split (vim.trim out) "\n" {:plain true})))))

; (ps)
; (fix-rag!)
; (logs :ab_mlservice_local 200)
; (restart-containers! [:ab_mlservice_local])

{: fix-rag!
 : restart-containers!
 : ps
 : logs}
