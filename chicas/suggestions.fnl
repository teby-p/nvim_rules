;; suggestions.fnl — automatiza el setup de policy suggestions en una PR instance.
;;
;; El backend filtra las sugerencias del RAG por "program overlap": la policy
;; y la entity sugerida tienen que compartir al menos un program. En instancias
;; PR el demo data viene con muchas entities huérfanas de programs ({NULL}),
;; entonces aunque el RAG devuelve candidatos relevantes, el filtro los
;; descarta y el front recibe [].
;;
;; (suggestions.seed-overlap! 1) hace eso:
;;   1. Llama al RAG (vía kube.rag-curl) para cada target type.
;;   2. Parsea los IDs sugeridos.
;;   3. INSERTea las filas mínimas para que cada ID tenga overlap con el
;;      program de la policy:
;;        - controls_data → programs_controls_data
;;        - auditable_entities → programs_auditable_entities
;;        - risks → risks_auditable_entities (apunta a una AE ya en program)
;;        - program_regulation_items → no se toca (FK directo en program_regulations.program_id)
;;        - framework_items → no se toca (vía framework_item_implementations.program_id)
;;
;; Requiere: (m.tsh.connect! ...) activo + (m.kube.use! "pr-sox-...") activo.
;;
;; Uso:
;;   (m.suggestions.seed-overlap! 1)              ; default program-id = 1
;;   (m.suggestions.seed-overlap! 1 2)            ; program-id explícito
;;   (m.suggestions.rag-ids 1 :controls_data)     ; raw: IDs sugeridos por RAG

(local tsh ((. (require :fennel) :dofile)
            "/Users/epodesta/Development/escort/chicas/tsh.fnl"))
(local kube ((. (require :fennel) :dofile)
             "/Users/epodesta/Development/escort/chicas/kube.fnl"))

;; ── Parser de respuestas del RAG ──────────────────

(fn strip-http-code-tail [s]
  "El `curl -w 'HTTP_CODE=...'` deja un sufijo tras el JSON. Lo limpiamos."
  (-> (or s "")
      (string.gsub "%s*HTTP_CODE=%d+%s*$" "")
      (string.gsub "\n+$" "")))

(fn parse-suggestion-ids [out]
  "Toma el stdout crudo de /rag/recommend y devuelve la lista de entityIds.
  Devuelve nil si no parsea o si suggestions está vacío/missing."
  (let [cleaned (strip-http-code-tail out)
        (ok parsed) (pcall vim.json.decode cleaned)]
    (when (and ok parsed)
      (let [suggestions (or parsed.suggestions [])]
        (icollect [_ s (ipairs suggestions)]
          s.entityId)))))

(fn rag-ids [policy-id target-type]
  "Devuelve los entityIds que sugiere el RAG para (policies/:policy-id, target).
  nil en error o si no hay sugerencias."
  (let [body (vim.json.encode {:sourceId policy-id
                               :sourceType "policies"
                               :targetType target-type})
        (ok? out) (kube.rag-curl "/rag/recommend"
                                 {:method "POST" :body body})]
    (if (not ok?)
      (do (vim.notify (.. "rag-ids: error en " target-type ": "
                          (or out "?"))
                      vim.log.levels.ERROR)
          nil)
      (parse-suggestion-ids out))))

;; ── INSERTs vía el terminal psql ──────────────────
;;
;; Usamos send-to-tsh (fire-and-forget) para no abrir un modal por cada
;; INSERT. El terminal queda con el output visible si querés inspeccionar.

(fn ids->sql-array [ids]
  (.. "ARRAY[" (table.concat ids ", ") "]::int[]"))

(fn insert-m2m-program [join-table entity-col program-id ids]
  "INSERT en una M:N programs_<x>: (program_id, entity_id) con ON CONFLICT.
  Asume la tabla tiene created_at/updated_at."
  (when (and ids (> (length ids) 0))
    (let [sql (string.format
                "INSERT INTO %s (program_id, %s, created_at, updated_at)
                 SELECT %d, x, NOW(), NOW()
                 FROM unnest(%s) AS x
                 ON CONFLICT (program_id, %s) DO NOTHING;"
                join-table entity-col program-id
                (ids->sql-array ids) entity-col)]
      (tsh.send-to-tsh sql)
      true)))

(fn insert-risks-to-ae [risk-ids ae-id]
  "INSERT en risks_auditable_entities apuntando cada risk-id a la misma AE.
  Esa AE tiene que estar ya vinculada al program de la policy."
  (when (and risk-ids (> (length risk-ids) 0) ae-id)
    (let [sql (string.format
                "INSERT INTO risks_auditable_entities (risk_id, auditable_entity_id, created_at, updated_at)
                 SELECT x, %d, NOW(), NOW()
                 FROM unnest(%s) AS x
                 ON CONFLICT DO NOTHING;"
                ae-id (ids->sql-array risk-ids))]
      (tsh.send-to-tsh sql)
      true)))

;; ── Acción principal ──────────────────────────────

(fn seed-overlap! [policy-id ?program-id]
  "Para policy-id, vincula los IDs que el RAG sugiere a program-id (default 1)
  insertando filas en las join tables. Refrescá los suggested-* en el front
  después de correr esto."
  (if (not vim.g.tsh_connected)
    (do (vim.notify "tsh: no hay conexión activa — (m.tsh.connect! ...)"
                    vim.log.levels.WARN) nil)
    (let [program-id (or ?program-id 1)
          cd-ids (rag-ids policy-id :controls_data)
          ae-ids (rag-ids policy-id :auditable_entities)
          risk-ids (rag-ids policy-id :risks)
          pri-ids (rag-ids policy-id :program_regulation_items)
          fi-ids (rag-ids policy-id :framework_items)
          cd-n (length (or cd-ids []))
          ae-n (length (or ae-ids []))
          risk-n (length (or risk-ids []))
          pri-n (length (or pri-ids []))
          fi-n (length (or fi-ids []))]
      (insert-m2m-program "programs_controls_data" "controls_datum_id"
                          program-id cd-ids)
      (insert-m2m-program "programs_auditable_entities" "auditable_entity_id"
                          program-id ae-ids)
      ;; Para risks necesitamos una AE concreta que ya esté en program-id.
      ;; Usamos la primera de las que acabamos de vincular.
      (when (> ae-n 0)
        (insert-risks-to-ae risk-ids (. ae-ids 1)))
      (vim.notify (string.format
                    "✓ seed policy=%d program=%d → cd=%d ae=%d risks=%d (pri=%d fi=%d ya OK por FK)"
                    policy-id program-id cd-n ae-n risk-n pri-n fi-n)
                  vim.log.levels.INFO))))

; (seed-overlap! 1)
; (seed-overlap! 1 2)
; (rag-ids 1 :controls_data)
; (rag-ids 1 :program_regulation_items)

{: rag-ids
 : parse-suggestion-ids
 : seed-overlap!}
