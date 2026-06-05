;; chulos.fnl — picker para correr los import.sql que viven en chulos/<repro>/.

(local api vim.api)
(local vfn vim.fn)

(local chulos-dir "/Users/epodesta/Development/escort/chulos")
(local local-db "demo_data")

(fn list-repros []
  "Subdirectorios de chulos/. Devuelve array de nombres (sin path)."
  (let [entries (vfn.readdir chulos-dir
                             (fn [name]
                               (let [path (.. chulos-dir "/" name)]
                                 (and (= 1 (vfn.isdirectory path))
                                      (= 1 (vfn.filereadable (.. path "/import.sql")))))))
        sorted (or entries [])]
    (table.sort sorted)
    sorted))

(fn run-import! [repro]
  "Cambia CWD a chulos/<repro>/ y corre `psql -d <local-db> -f import.sql`.
  El cd es necesario para que los \\copy FROM con paths relativos resuelvan."
  (let [repro-dir (.. chulos-dir "/" repro)
        cmd (string.format "cd %s && psql -d %s -f import.sql"
                           (vfn.shellescape repro-dir)
                           (vfn.shellescape local-db))
        out (vfn.system cmd)
        ok? (= 0 vim.v.shell_error)
        lines (vim.split (vim.trim (or out "")) "\n" {:plain true})
        buf (api.nvim_create_buf false true)
        width (math.min 120 (- vim.o.columns 4))
        height (math.min (math.max 6 (length lines)) (- vim.o.lines 6))
        row (math.floor (/ (- vim.o.lines height) 2))
        col (math.floor (/ (- vim.o.columns width) 2))]
    (api.nvim_buf_set_lines buf 0 -1 false lines)
    (api.nvim_set_option_value :modifiable false {:buf buf})
    (api.nvim_set_option_value :buftype :nofile {:buf buf})
    (let [title (string.format " %s %s — %s "
                               (if ok? "✓" "✗") repro local-db)
          win (api.nvim_open_win buf true
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

(fn pick-and-import! []
  "Modal con los chulos disponibles. Enter corre import.sql del elegido contra
  la DB local (demo_data por defecto)."
  (let [repros (list-repros)]
    (if (= 0 (length repros))
      (vim.notify (.. "chulos: no hay subdirs con import.sql en " chulos-dir)
                  vim.log.levels.WARN)
      (let [buf (api.nvim_create_buf false true)
            width (math.min 60 (- vim.o.columns 4))
            height (math.min (length repros) (math.max 4 (- vim.o.lines 8)))
            row (math.floor (/ (- vim.o.lines height) 2))
            col (math.floor (/ (- vim.o.columns width) 2))]
        (api.nvim_buf_set_lines buf 0 -1 false repros)
        (api.nvim_set_option_value :modifiable false {:buf buf})
        (api.nvim_set_option_value :buftype :nofile {:buf buf})
        (let [win (api.nvim_open_win buf true
                                     {:relative :editor
                                      :width width :height height
                                      :row row :col col
                                      :style :minimal
                                      :border :rounded
                                      :title " Elegí repro "
                                      :title_pos :center})
              opts {:buffer buf :silent true :nowait true}
              close #(when (api.nvim_win_is_valid win)
                       (api.nvim_win_close win true))]
          (api.nvim_win_set_cursor win [1 0])
          (vim.keymap.set :n :q close opts)
          (vim.keymap.set :n :<Esc> close opts)
          (vim.keymap.set :n :<CR>
            #(let [lnum (. (api.nvim_win_get_cursor 0) 1)
                   chosen (. repros lnum)]
               (when chosen
                 (close)
                 (run-import! chosen)))
            opts))))))

; (list-repros)
; (pick-and-import!)

{: list-repros
 : run-import!
 : pick-and-import!}
