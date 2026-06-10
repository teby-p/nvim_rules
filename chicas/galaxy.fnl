;; galaxy.fnl — primitivas para sacar el breadcrumb de una instancia de Galaxy.
;;
;; Galaxy requiere Microsoft Platform SSO con el broker de macOS — el Chromium
;; sandboxeado de Playwright no tiene acceso. Trabajamos contra un Chrome real
;; corriendo con --remote-debugging-port, al que Playwright se conecta via CDP.
;;
;; Setup primera vez:
;;   cd ~/Development/escort/choferes && npm install
;;   (galaxy.chrome!)                    ; lanza Chrome con debug port
;;   → en la ventana de Chrome, logueate en Galaxy una vez (SSO)
;;
;; Después, todo headless desde nvim.

(local vfn vim.fn)

(local choferes-dir "/Users/epodesta/Development/escort/choferes")
(local chrome-bin "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
(local chrome-profile-dir (.. (vim.fn.expand "~") "/.cache/escort/chrome-debug"))
(local cdp-port 9222)
(local cdp-url (.. "http://localhost:" cdp-port))

;; ── Chrome con debug port ─────────────────────────

(fn cdp-alive? []
  "true si Chrome está escuchando en cdp-port."
  (vfn.system ["curl" "-sf" "-o" "/dev/null" (.. cdp-url "/json/version")])
  (= 0 vim.v.shell_error))

(fn chrome! []
  "Lanza Chrome con --remote-debugging-port + profile dedicado. Detached, así
  sobrevive a cerrar nvim. Si ya está escuchando, no duplica."
  (if (cdp-alive?)
    (vim.notify (.. "✓ Chrome ya escuchando en " cdp-url) vim.log.levels.INFO)
    (do
      (vfn.jobstart [chrome-bin
                     (.. "--remote-debugging-port=" cdp-port)
                     (.. "--user-data-dir=" chrome-profile-dir)]
                    {:detach true})
      (vim.notify (.. "🚀 Chrome lanzado con CDP en " cdp-url
                      ". Primera vez: logueate en Galaxy en la ventana que se abre.")
                  vim.log.levels.INFO))))

;; ── Galaxy URL desde el PR ────────────────────────

(fn fetch-galaxy-url [owner repo number]
  "Saca la URL de la instancia de Galaxy del PRDeployment Reserved Comment.
  Devuelve nil si no la encuentra."
  (let [out (vfn.system
              ["gh" "api"
               (string.format "repos/%s/%s/issues/%d/comments" owner repo number)
               "--jq"
               "[.[] | select(.body | test(\"PRDeployment Reserved Comment\")) | .body] | last"])]
    (if (not= 0 vim.v.shell_error)
      (do (vim.notify (.. "gh api error: " out) vim.log.levels.ERROR) nil)
      (let [id (string.match out "galaxy%.auditboardteam%.com/admin/cloud/instance/(%d+)")]
        (when id
          (.. "https://galaxy.auditboardteam.com/admin/cloud/instance/" id "/"))))))

;; ── Scrape del breadcrumb via CDP ─────────────────

(fn fetch-breadcrumb [url]
  "Corre el chofer Playwright (CDP) contra la URL y devuelve el último segmento
  del breadcrumb. nil si falla — el error real (stderr del JS) va al notify."
  (if (not (cdp-alive?))
    (do (vim.notify (.. "Chrome no está en " cdp-url ". Corré (galaxy.chrome!) primero.")
                    vim.log.levels.ERROR) nil)
    (let [script (.. choferes-dir "/galaxy-breadcrumb.js")
          proc (vim.system [:node script url] {:text true})
          result (proc:wait)
          stdout (or result.stdout "")
          stderr (or result.stderr "")]
      (if (not= 0 result.code)
        (do (vim.notify (.. "galaxy-breadcrumb (exit " result.code "):\n" stderr)
                        vim.log.levels.ERROR) nil)
        (let [trimmed (vim.trim stdout)]
          (if (= "" trimmed)
            (do (vim.notify (.. "galaxy-breadcrumb: stdout vacío. stderr:\n" stderr)
                            vim.log.levels.WARN) nil)
            trimmed))))))

; (chrome!)
; (cdp-alive?)
; (fetch-galaxy-url "soxhub" "auditboard-frontend" 95289)
; (fetch-breadcrumb "https://galaxy.auditboardteam.com/admin/cloud/instance/118648/")

{: chrome!
 : cdp-alive?
 : fetch-galaxy-url
 : fetch-breadcrumb}
