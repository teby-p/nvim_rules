;; mappings.fnl — helpers de Auditboard para policy mappings y dismissals.
;; Necesita conexión activa via tsh.fnl (corré (tsh.connect! ...) primero).

(local api vim.api)
(local vfn vim.fn)
(local tsh ((. (require :fennel) :dofile)
            "/Users/epodesta/Development/escort/chicas/tsh.fnl"))

(local chulos-dir "/Users/epodesta/Development/escort/chulos")

;; ── Resumen de mappings por source ────────────────

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
  identificar qué valor de source corresponde a 'accepted from suggestion'."
  (tsh.query (.. mappings-by-source-sql ";") 1500))

;; ── Borrar todos los mappings ─────────────────────

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
          (tsh.query sql 1500))))))

;; ── Resumen de dismissals ─────────────────────────

(local dismissals-summary-sql
  "SELECT reference_type, COUNT(*) AS count
   FROM policy_mapping_suggestion_dismissals
   WHERE deleted_at IS NULL
   GROUP BY reference_type
   ORDER BY count DESC")

(fn policy-dismissals-by-type []
  "Resumen de dismissals de policy_mapping_suggestion_dismissals agrupado
  por reference_type, contando solo las no borradas (deleted_at IS NULL)."
  (tsh.query (.. dismissals-summary-sql ";")))

;; ── Borrar dismissals con picker ──────────────────

(fn delete-dismissals! []
  "Modal con dismissals por reference_type + opción <ALL>. Al elegir, pide
  confirmación y hace soft-delete (UPDATE deleted_at = NOW())."
  (tsh.fetch-rows dismissals-summary-sql nil
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
                                         (tsh.sql-escape item.type)))
                               sql (.. "UPDATE policy_mapping_suggestion_dismissals "
                                       "SET deleted_at = NOW() WHERE " where ";")]
                           (tsh.query sql))))))
                opts))))))))

;; ── Replicar regulation items a local ─────────────

(fn replicate-regulation-items! [?out-dir]
  "Dump policies + regulation_items + policy_regulation_item_mappings a CSVs,
  y genera un import.sql con paths relativos listo para correr contra local
  via (chulos.pick-and-import!) o directamente:
    cd <out-dir> && psql -d demo_data -f import.sql

  Por defecto out-dir = chulos/repro-regulation-items (auto-detectable por
  chulos.fnl). Asume que en local los IDs no chocan — si chocan, DELETE antes."
  (if (not vim.g.tsh_connected)
    (vim.notify "tsh: no hay conexión activa" vim.log.levels.WARN)
    (let [dir (or ?out-dir (.. chulos-dir "/repro-regulation-items"))
          flat (fn [s] (-> s (string.gsub ";%s*$" "") (string.gsub "%s+" " ")))
          ;; Subset CTE-like: las regulation_items que están en mappings.
          ;; Usado para filtrar tablas dependientes.
          ri-subset "SELECT DISTINCT ri.id FROM regulation_items ri
                     JOIN policy_regulation_item_mappings prim
                       ON prim.regulation_item_id = ri.id"
          ;; Orden importa: parents antes que children por las FKs.
          tables [;; ── Standalone ──────────────────────────────────────
                  {:name "workspaces"
                   :select "SELECT * FROM workspaces"}
                  {:name "program_categories"
                   :select "SELECT * FROM program_categories"}
                  {:name "programs"
                   :select "SELECT * FROM programs"}
                  ;; NOTA: frameworks no se dumpea — asumimos que existen en
                  ;; local (PCI framework_id=14 viene en el seed). Además
                  ;; frameworks.scopes (jsonb) tiene data corrupta en PR que
                  ;; rompe el COPY. Si necesitás un framework que no esté en
                  ;; local, agregalo a mano.
                  ;; ── Framework items: solo del framework 14 + los que ─
                  ;; ── linkean a nuestros reg_items via controls.       ─
                  {:name "framework_items"
                   :select (.. "SELECT DISTINCT fi.* FROM framework_items fi
                                WHERE fi.framework_id = 14
                                   OR fi.id IN (SELECT cfi.framework_item_id
                                                FROM controls_framework_items cfi
                                                JOIN controls_regulation_items cri
                                                  ON cri.control_id = cfi.control_id
                                                WHERE cri.regulation_item_id IN ("
                               ri-subset "))")}
                  ;; ── Controls linkeados a nuestros reg_items ─────────
                  {:name "controls"
                   :select (.. "SELECT DISTINCT c.* FROM controls c
                                JOIN controls_regulation_items cri ON cri.control_id = c.id
                                WHERE cri.regulation_item_id IN (" ri-subset ")")}
                  ;; ── Regulations + items ────────────────────────────
                  {:name "regulations"
                   :select (.. "SELECT DISTINCT r.* FROM regulations r
                                JOIN regulation_items ri ON ri.regulation_id = r.id
                                WHERE ri.id IN (" ri-subset ")")}
                  {:name "regulation_items"
                   :select (.. "SELECT * FROM regulation_items WHERE id IN ("
                               ri-subset ")")}
                  ;; ── Policies + mappings ────────────────────────────
                  {:name "policies"
                   :select "SELECT DISTINCT p.* FROM policies p
                            JOIN policy_regulation_item_mappings prim
                              ON prim.policy_id = p.id"}
                  {:name "policy_regulation_item_mappings"
                   :select "SELECT * FROM policy_regulation_item_mappings"}
                  ;; ── Joins regulation ↔ framework/program/control ────
                  {:name "controls_regulation_items"
                   :select (.. "SELECT * FROM controls_regulation_items
                                WHERE regulation_item_id IN (" ri-subset ")")}
                  {:name "controls_framework_items"
                   :select (.. "SELECT * FROM controls_framework_items
                                WHERE control_id IN (
                                  SELECT control_id FROM controls_regulation_items
                                  WHERE regulation_item_id IN (" ri-subset "))")}
                  ;; program_regulations (SINGULAR PLURAL) — la entidad real
                  ;; que muestra el frontend. NO confundir con programs_regulations
                  ;; (plural plural) que es solo un m2m sin uso real.
                  {:name "program_regulations"
                   :select (.. "SELECT * FROM program_regulations
                                WHERE regulation_id IN (
                                  SELECT DISTINCT regulation_id FROM regulation_items
                                  WHERE id IN (" ri-subset "))")}
                  {:name "program_regulation_items"
                   :select (.. "SELECT * FROM program_regulation_items
                                WHERE regulation_item_id IN (" ri-subset ")")}
                  ;; versions polymorphic — necesarias para que IMDB cargue
                  ;; los program_regulation_items (filter por activeVersions).
                  {:name "versions"
                   :select (.. "SELECT * FROM versions
                                WHERE versionable_type = 'ProgramRegulationItem'
                                AND versionable_id IN (
                                  SELECT id FROM program_regulation_items
                                  WHERE regulation_item_id IN (" ri-subset "))")}
                  {:name "programs_frameworks"
                   :select "SELECT * FROM programs_frameworks"}
                  {:name "programs_regulations"
                   :select (.. "SELECT * FROM programs_regulations
                                WHERE regulation_id IN (
                                  SELECT DISTINCT regulation_id FROM regulation_items
                                  WHERE id IN (" ri-subset "))")}]]
      (vfn.mkdir dir "p")
      ;; 1. desde psql del PR: dump cada tabla en FORMAT text (tab-separated,
      ;; \N para NULL). Lo recomendado por PG para roundtrip dump/import —
      ;; CSV tiene ambigüedad NULL vs "" que rompe con columnas jsonb.
      (each [_ t (ipairs tables)]
        (tsh.send-to-tsh (string.format
                           "\\copy (%s) TO '%s/%s.txt' WITH (FORMAT text)"
                           (flat t.select) dir t.name)))
      ;; 2. desde nvim: generar import.sql que corre local
      (let [import-path (.. dir "/import.sql")
            lines ["-- Generated by mappings.fnl replicate-regulation-items!"
                   "-- Run: cd <este-dir> && psql -d demo_data -f import.sql"
                   "-- (o via (chulos.pick-and-import!))"
                   "--"
                   "-- Pisa los rows con IDs conflictivos en local con la versión del PR."
                   "-- Patrón: CSV → temp table → DELETE conflicts → INSERT FROM temp."
                   ""
                   "BEGIN;"
                   ""
                   "-- Disable FK checks para esquivar self-refs (parent_item_id),"
                   "-- ancestros faltantes y FK externas no incluidas."
                   "-- Requiere superuser — alcanza para demo_data en local."
                   "SET session_replication_role = replica;"
                   ""]]
        (each [_ t (ipairs tables)]
          (let [stage (.. "_stage_" t.name)]
            (table.insert lines (string.format "-- %s" t.name))
            (table.insert lines (string.format "CREATE TEMP TABLE %s (LIKE %s);"
                                               stage t.name))
            (table.insert lines (string.format
                                  "\\copy %s FROM '%s.txt' WITH (FORMAT text)"
                                  stage t.name))
            (table.insert lines (string.format
                                  "DELETE FROM %s WHERE id IN (SELECT id FROM %s);"
                                  t.name stage))
            (table.insert lines (string.format "INSERT INTO %s SELECT * FROM %s;"
                                               t.name stage))
            (table.insert lines (string.format "DROP TABLE %s;" stage))
            (table.insert lines "")))
        (table.insert lines "SET session_replication_role = origin;")
        (table.insert lines "")
        (table.insert lines "-- Resetear sequences para que próximos INSERTs no choquen")
        (each [_ t (ipairs tables)]
          (table.insert lines
            (string.format "SELECT setval(pg_get_serial_sequence('%s', 'id'), COALESCE((SELECT MAX(id) FROM %s), 1));"
                           t.name t.name)))
        (table.insert lines "")
        (table.insert lines "COMMIT;")
        (table.insert lines "")
        ;; ── Post-import steps fuera de la transacción ──────────────
        ;; (REFRESH MATERIALIZED VIEW CONCURRENTLY no corre en transacción)
        (table.insert lines "-- ─── post-import ───────────────────────────────────")
        (table.insert lines "-- 1. Patch scopes de la regulation: AB filtra el view")
        (table.insert lines "--    por scopes.admin_teams.all ∩ user.team_ids. Le")
        (table.insert lines "--    metemos TODOS los teams del local así cualquier")
        (table.insert lines "--    user la ve.")
        (table.insert lines "UPDATE regulations SET scopes = jsonb_build_object(")
        (table.insert lines "  'admin_teams', jsonb_build_object('all', (SELECT jsonb_agg(id) FROM teams)),")
        (table.insert lines "  'viewonly_teams', jsonb_build_object('all', (SELECT jsonb_agg(id) FROM teams))")
        (table.insert lines ") WHERE id IN (SELECT DISTINCT regulation_id FROM regulation_items);")
        (table.insert lines "")
        (table.insert lines "-- 2. Refresh user_facts matview (permission cache)")
        (table.insert lines "REFRESH MATERIALIZED VIEW CONCURRENTLY user_facts;")
        (table.insert lines "")
        (table.insert lines "\\echo")
        (table.insert lines "\\echo '✓ Import done. ACUERDATE de reiniciar el API node:'")
        (table.insert lines "\\echo '   pkill -f \"contexts/api/app.ts\"   # nodemon lo reinicia solo'")
        (table.insert lines "\\echo")
        (vfn.writefile lines import-path))
      ;; 3. notify después de un delay para que psql termine de escribir CSVs.
      ;; Subido a 10s porque las queries con JOIN al subset son lentas en PR DB.
      (vim.defer_fn
        (fn []
          (vim.notify (string.format
                        "✓ snapshot a %s (revisá que los CSVs no estén vacíos)\nCorré: psql -d demo_data -f %s/import.sql"
                        dir dir)
                      vim.log.levels.INFO))
        10000))))

; (tsh.connect! "Home › Cloud › Instances › PRNew (pr-us-west-2-tennis / us-west-2) / sox-82749-develop")
; (policy-mappings-by-source)
; (policy-dismissals-by-type)
; (delete-dismissals!)
; (clear-all-mappings!)
; (replicate-regulation-items!)

{: policy-mappings-by-source
 : policy-dismissals-by-type
 : delete-dismissals!
 : clear-all-mappings!
 : replicate-regulation-items!}
