;; kube.fnl — helpers para hablar con el cluster de un PR via kubectl.
;;
;; Pensado para inspeccionar/disparar el ML service (RAG) desde adentro del
;; cluster, ya que /api/v1/rag/* está protegido por ml-local-service-auth
;; (subnet privada + header ml-local-secret) y no es alcanzable por nginx.
;;
;; Uso típico:
;;   (kube.use! "sox-95289-develop")    ; setea el namespace activo
;;   (kube.api-pod)                      ; devuelve el nombre del primer api-*
;;   (kube.rag-status)                   ; GET $ML_LOCAL_URL/rag/index/status
;;   (kube.rag-recommend 1 :program_regulation_items)
;;   (kube.rag-sync!)                    ; POST /rag/index/sync
;;   (kube.ml-logs 200)                  ; logs del ml service (último N)

(local api vim.api)
(local vfn vim.fn)

;; ── Primitivas: kubectl + modal ───────────────────

(fn run [args]
  "Corre `kubectl <args>` sincrónicamente. Devuelve (values ok? output)."
  (let [cmd (vim.list_extend [:kubectl] args)
        out (vfn.system cmd)]
    (values (= 0 vim.v.shell_error) (or out ""))))

(fn show-output [title lines]
  "Modal flotante con `lines`. q/<Esc> cierra."
  (let [buf (api.nvim_create_buf false true)
        width (math.min 140 (- vim.o.columns 4))
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

(fn lines-of [s]
  (vim.split (vim.trim (or s "")) "\n" {:plain true}))

;; ── Namespace activo ──────────────────────────────

(fn instance->ns [instance]
  "Convierte la 'instance' del breadcrumb de Galaxy (e.g. 'sox-95289-develop')
  al namespace de k8s (e.g. 'pr-sox-95289-develop'). Si ya empieza con 'pr-',
  lo devuelve tal cual."
  (if (and instance (= 1 (string.find instance "pr-" 1 true)))
    instance
    (.. "pr-" (or instance ""))))

(fn use! [ns-or-instance]
  "Setea el namespace activo. Acepta el namespace directo ('pr-sox-...') o la
  instance de Galaxy ('sox-...-develop') y agrega el prefijo 'pr-' automáticamente."
  (let [ns (instance->ns ns-or-instance)]
    (set vim.g.kube_namespace ns)
    (vim.notify (.. "kube: ns = " ns) vim.log.levels.INFO)
    ns))

(fn current-namespace [?ns]
  "Devuelve ?ns si está, si no vim.g.kube_namespace, si no nil."
  (or ?ns vim.g.kube_namespace nil))

(fn require-ns [?ns]
  (let [ns (current-namespace ?ns)]
    (if ns ns
      (do (vim.notify "kube: falta namespace — usá (kube.use! \"sox-XXXXX-develop\")"
                      vim.log.levels.ERROR)
          nil))))

;; ── Pods ──────────────────────────────────────────

(fn pods [?ns]
  "Lista pods (name + status + node) del namespace actual. Devuelve lines o nil."
  (let [ns (require-ns ?ns)]
    (when ns
      (let [(ok? out) (run [:-n ns :get :pods :-o
                            "custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName"
                            :--no-headers])]
        (if ok? (lines-of out)
          (do (vim.notify (.. "kubectl get pods error: " out) vim.log.levels.ERROR) nil))))))

(fn ps [?ns]
  "Modal con los pods del namespace."
  (let [ls (pods ?ns)]
    (when ls (show-output (.. " kube pods @ " (require-ns ?ns) " ") ls))))

(fn find-pod-by-prefix [prefix ?ns]
  "Primer pod cuyo nombre empieza con `prefix`. Prioriza Running pero si no
  hay, devuelve el primer match en cualquier estado (útil para diagnosticar)."
  (let [ls (pods ?ns)]
    (when ls
      (var running nil)
      (var any nil)
      (each [_ line (ipairs ls)]
        (let [name (string.match line "^(%S+)")
              status (string.match line "^%S+%s+(%S+)")]
          (when (and name (= 1 (string.find name prefix 1 true)))
            (when (not any) (set any name))
            (when (and (not running) (= status "Running"))
              (set running name)))))
      (or running any))))

(fn api-pod [?ns]
  "Primer pod del backend API (nombre que empieza con 'api-'). Prioriza Running."
  (or (find-pod-by-prefix "api-" ?ns)
      (do (vim.notify
            (.. "kube: no encontré pod api-* en ns="
                (tostring (current-namespace ?ns))
                ". Corré (kube.ps) para ver qué hay.")
            vim.log.levels.WARN)
          nil)))

(fn namespaces []
  "Lista todos los namespaces del cluster actual."
  (let [(ok? out) (run [:get :ns :-o "name" :--no-headers])]
    (if ok? (lines-of out)
      (do (vim.notify (.. "kubectl get ns error: " out) vim.log.levels.ERROR) nil))))

(fn raw-pods-output [?ns]
  "Devuelve el output crudo de `kubectl -n NS get pods` (sin custom-columns).
  Más confiable para diagnosticar — captura errores y stderr."
  (let [ns (current-namespace ?ns)]
    (when ns
      (let [args [:-n ns :get :pods]
            cmd (vim.list_extend [:kubectl] args)
            out (vfn.system cmd)]
        (.. "exit=" (tostring vim.v.shell_error) "\n" (or out ""))))))

(fn debug-context [?ns]
  "Modal con el contexto actual + namespace + lista de namespaces matcheando
  el actual + intento raw de listar pods. Útil cuando algo no encuentra el pod."
  (let [ns (current-namespace ?ns)
        (_ ctx) (run [:config :current-context])
        (_ contexts) (run [:config :get-contexts])
        nss (or (namespaces) [])
        matching (icollect [_ n (ipairs nss)]
                   (when (or (not ns) (string.find n (or ns "") 1 true)) n))
        raw (raw-pods-output ?ns)
        lines (vim.list_extend
                [(.. "current-context: " (vim.trim (or ctx "?")))
                 (.. "kube_namespace:   " (tostring ns))
                 ""
                 "── contexts ──"]
                (lines-of (or contexts "")))
        lines (vim.list_extend lines
                ["" (.. "── namespaces matching '" (or ns "*") "' ──")])
        lines (vim.list_extend lines (if (> (length matching) 0) matching
                                       ["(ninguno — chequeá nombre o RBAC)"]))
        lines (vim.list_extend lines ["" "── raw `kubectl -n NS get pods` ──"])
        lines (vim.list_extend lines (lines-of raw))]
    (show-output " kube debug " lines)))

(fn ml-pod [?ns]
  "Primer pod del ML service. Probamos varios prefijos comunes."
  (or (find-pod-by-prefix "ab-mlservice-local-" ?ns)
      (find-pod-by-prefix "ab-mlservice-" ?ns)
      (find-pod-by-prefix "ml-service-" ?ns)
      (find-pod-by-prefix "mlservice-" ?ns)
      (do (vim.notify "kube: no encontré pod ml-service-* en Running" vim.log.levels.WARN)
          nil)))

(fn ml-pods-status [?ns]
  "Modal con los pods del ML service y su estado (todos los matches, no solo
  Running). Útil para confirmar si está crasheando / reiniciándose."
  (let [ls (or (pods ?ns) [])
        matches (icollect [_ line (ipairs ls)]
                  (when (or (string.find line "mlservice" 1 true)
                            (string.find line "ml-service" 1 true)
                            (string.find line "mlworker" 1 true)
                            (string.find line "ml-worker" 1 true))
                    line))
        lines (if (> (length matches) 0) matches
                ["(ninguno — el service apunta a un pod inexistente)"])]
    (show-output " ml pods " lines)))

;; ── Exec / logs ───────────────────────────────────

(fn exec [pod sh-cmd ?ns]
  "Corre `sh -c sh-cmd` dentro de `pod`. Devuelve (ok? out)."
  (let [ns (require-ns ?ns)]
    (when ns
      (run [:-n ns :exec pod :-- :sh :-c sh-cmd]))))

(fn logs [pod ?n ?ns]
  "Modal con las últimas ?n (default 200) líneas de logs del pod."
  (let [ns (require-ns ?ns)
        n (tostring (or ?n 200))]
    (when ns
      (let [(ok? out) (run [:-n ns :logs pod (.. :--tail= n)])]
        (if ok? (show-output (.. " logs " pod " (last " n ") ") (lines-of out))
          (vim.notify (.. "kubectl logs error: " out) vim.log.levels.ERROR))))))

(fn ml-logs [?n ?ns]
  "Logs del primer pod del ML service."
  (let [pod (ml-pod ?ns)]
    (when pod (logs pod ?n ?ns))))

(fn api-logs [?n ?ns]
  "Logs del primer pod del API."
  (let [pod (api-pod ?ns)]
    (when pod (logs pod ?n ?ns))))

;; ── Curl al ML service desde el pod del API ───────
;;
;; El ML service no tiene auth desde dentro del cluster — el backend lo llama
;; con fetch(${ML_LOCAL_URL}/...) sin headers extra. Reproducimos eso vía
;; exec en un api-pod (que ya tiene ML_LOCAL_URL en su env).

(fn shell-quote [s]
  "Single-quote para sh."
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn rag-curl [path ?opts]
  "Curl al ML service. ?opts: {:method 'POST' :body 'json' :ns 'sox-...' :pod 'api-...'}.
  Devuelve (ok? out). Default: GET, ns = current, pod = api-pod.

  Usa la k8s-injected env var AB_MLSERVICE_LOCAL_SERVICE_HOST + _PORT (que sí
  está en el pod del API; ML_LOCAL_URL viene vacía). Eso replica lo que hace
  el backend Node, que también recibe el host vía k8s service discovery."
  (let [opts (or ?opts {})
        ns (require-ns opts.ns)]
    (when ns
      (let [pod (or opts.pod (api-pod ns))]
        (when pod
          (let [method (or opts.method "GET")
                body opts.body
                base (.. "curl -sS -m 10 -X " method
                         " -H 'content-type: application/json'"
                         (if body (.. " -d " (shell-quote body)) "")
                         " -w '\\nHTTP_CODE=%{http_code}\\n'"
                         " \"http://$AB_MLSERVICE_LOCAL_SERVICE_HOST:$AB_MLSERVICE_LOCAL_SERVICE_PORT"
                         path "\"")]
            (exec pod base ns)))))))

(fn show-json [title body]
  "Pretty-print json (via jq si está) y abre modal."
  (let [out (vfn.system ["jq" "."] body)
        formatted (if (= 0 vim.v.shell_error) out body)]
    (show-output title (lines-of formatted))))

(fn rag-status [?ns]
  "GET /rag/index/status — qué types está indexando el ML, totalChunks, etc."
  (let [(ok? out) (rag-curl "/rag/index/status" {:ns ?ns})]
    (if ok?
      (show-json " rag status " out)
      (vim.notify (.. "rag-status error: " (or out "?")) vim.log.levels.ERROR))))

(fn rag-debug [?ns]
  "Modal con: api-pod, todas las env vars del pod que contengan ML, prueba
  de curl al ML service en distintas URLs candidatas + status code."
  (let [ns (require-ns ?ns)]
    (when ns
      (let [pod (api-pod ns)]
        (if (not pod)
          (vim.notify "kube: no hay api-pod" vim.log.levels.ERROR)
          (let [(_ env-out) (exec pod
                              "env | grep -iE 'ml|rag|service' | sort"
                              ns)
                ;; URLs candidatas comunes para el ML service en k8s
                (_ probe-out) (exec pod
                                "for url in \"$ML_LOCAL_URL\" \"$ML_LOCAL_SERVICE_URL\" \"$ML_SERVICE_URL\" \"http://ml-service:8000\" \"http://ab-mlservice-local:8000\" \"http://mlservice:8000\" \"http://localhost:8000\"; do
  echo \"── url='$url' ──\"
  if [ -n \"$url\" ]; then
    curl -sS -m 3 -w 'HTTP_CODE=%{http_code}\\n' \"$url/rag/index/status\" 2>&1 | head -5
  else
    echo '(vacío, skip)'
  fi
done"
                                ns)
                lines (vim.list_extend
                        [(.. "namespace: " ns)
                         (.. "api-pod:   " pod)
                         ""
                         "── env vars (grep -iE 'ml|rag|service') ──"]
                        (lines-of (or env-out "")))
                lines (vim.list_extend lines ["" "── probe URLs candidatas ──"])
                lines (vim.list_extend lines (lines-of (or probe-out "")))]
            (show-output " rag debug " lines)))))))

(fn rag-recommend [source-id target-type ?source-type ?ns]
  "POST /rag/recommend. ?source-type default 'policies'. Muestra suggestions."
  (let [src-type (or ?source-type "policies")
        body (vim.json.encode {:sourceId source-id
                               :sourceType src-type
                               :targetType target-type})
        (ok? out) (rag-curl "/rag/recommend"
                            {:method "POST" :body body :ns ?ns})]
    (if ok?
      (show-json (.. " rag recommend " src-type ":" source-id " → " target-type " ")
                 out)
      (vim.notify (.. "rag-recommend error: " (or out "?")) vim.log.levels.ERROR))))

(fn rag-sync! [?ns]
  "POST /rag/index/sync — dispara un reindex. Puede tardar minutos."
  (let [(ok? out) (rag-curl "/rag/index/sync" {:method "POST" :body "{}" :ns ?ns})]
    (if ok?
      (show-json " rag sync " out)
      (vim.notify (.. "rag-sync error: " (or out "?")) vim.log.levels.ERROR))))

(fn rag-flush! [?ns]
  "POST /rag/index/flush — borra el índice entero. Pide confirmación."
  (let [choice (vfn.confirm "⚠ FLUSH borra el índice RAG entero. ¿Seguir?"
                            "&No\n&Sí" 1)]
    (when (= choice 2)
      (let [(ok? out) (rag-curl "/rag/index/flush" {:ns ?ns})]
        (if ok?
          (show-json " rag flush " out)
          (vim.notify (.. "rag-flush error: " (or out "?")) vim.log.levels.ERROR))))))

;; ── Atajos para la policy en debug ────────────────

(fn rag-recommend-all-for-policy [policy-id ?ns]
  "Llama a /rag/recommend para los 5 target types de policy suggestions y
  muestra un resumen consolidado de suggestionsCount por target."
  (let [targets [:framework_items :controls_data :risks
                 :program_regulation_items :auditable_entities]
        lines [(.. "policy_id = " policy-id) ""]]
    (each [_ tt (ipairs targets)]
      (let [body (vim.json.encode {:sourceId policy-id
                                   :sourceType "policies"
                                   :targetType tt})
            (ok? out) (rag-curl "/rag/recommend"
                                {:method "POST" :body body :ns ?ns})
            out-str (vim.trim (or out ""))]
        (if (not ok?)
          (do (table.insert lines (.. "✗ " tt " — exit≠0:"))
              (each [_ l (ipairs (lines-of out-str))]
                (table.insert lines (.. "    " l))))
          (let [(parsed-ok parsed) (pcall vim.json.decode out-str)
                count (if parsed-ok (?. parsed :suggestionsCount) nil)]
            (table.insert lines
              (if count
                (string.format "%-30s %d suggestions" tt count)
                (.. "? " tt " — " (string.sub out-str 1 200))))))))
    (show-output " rag recommend × policy " lines)))

; (use! "sox-95289-develop")
; (ps)
; (api-pod)
; (ml-pod)
; (rag-status)
; (rag-recommend 1 :program_regulation_items)
; (rag-recommend-all-for-policy 1)
; (rag-sync!)
; (ml-logs 200)
; (api-logs 200)
; (rag-flush!)

{: use!
 : current-namespace
 : pods
 : ps
 : namespaces
 : debug-context
 : find-pod-by-prefix
 : api-pod
 : ml-pod
 : ml-pods-status
 : exec
 : logs
 : api-logs
 : ml-logs
 : rag-curl
 : rag-status
 : rag-debug
 : rag-recommend
 : rag-recommend-all-for-policy
 : rag-sync!
 : rag-flush!}
