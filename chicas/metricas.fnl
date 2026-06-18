;; metricas.fnl — PRs mergeados (front / back / ml) via GitHub GraphQL.
;;
;; Devuelve datos crudos. La idea es componer en `madame.fnl`:
;;   (local prs (m.metricas.merged-prs))
;;   (each [_ p (ipairs prs)] (print p.url))

(local vfn vim.fn)

(local merged-query
  "query($q: String!, $first: Int!, $after: String) {
     search(query: $q, type: ISSUE, first: $first, after: $after) {
       issueCount
       pageInfo { hasNextPage endCursor }
       nodes {
         ... on PullRequest {
           number title url mergedAt
           repository { nameWithOwner }
           commits(first: 1) { nodes { commit { committedDate } } }
         }
       }
     }
   }")

(fn gh-graphql [query str-vars int-vars]
  "Devuelve (ok? data-o-error). str-vars usa -f (string), int-vars usa -F (typed)."
  (let [args ["gh" "api" "graphql" "-f" (.. "query=" query)]]
    (each [k v (pairs (or str-vars {}))]
      (table.insert args "-f")
      (table.insert args (.. k "=" v)))
    (each [k v (pairs (or int-vars {}))]
      (table.insert args "-F")
      (table.insert args (.. k "=" (tostring v))))
    (let [out (vfn.system args)]
      (if (not= 0 vim.v.shell_error)
        (values false out)
        (let [(ok parsed) (pcall vim.json.decode out)]
          (if ok
            (values true parsed)
            (values false out)))))))

(fn fetch-page [q first after]
  "Una página de search. Devuelve {:nodes :next-cursor :total} o nil en error."
  (let [str-vars {:q q}
        _ (when after (tset str-vars :after after))
        (ok data) (gh-graphql merged-query str-vars {:first first})]
    (if (not ok)
      (do (vim.notify (.. "metricas: gh graphql error: " (or data "?"))
                      vim.log.levels.ERROR) nil)
      (let [search (?. data :data :search)]
        {:nodes (or (?. search :nodes) [])
         :next-cursor (when (?. search :pageInfo :hasNextPage)
                        (?. search :pageInfo :endCursor))
         :total (?. search :issueCount)}))))

(fn iso->epoch [s]
  "ISO 8601 UTC ('2026-06-17T14:44:40Z') → unix seconds. nil si no parsea."
  (when s
    (let [t (vfn.strptime "%Y-%m-%dT%H:%M:%SZ" s)]
      (when (and t (> t 0)) t))))

(fn diff-days [from-iso to-iso]
  "Días (float) entre dos timestamps ISO. nil si alguno falla."
  (let [a (iso->epoch from-iso)
        b (iso->epoch to-iso)]
    (when (and a b)
      (/ (- b a) 86400))))

(fn iso-week [s]
  "ISO 8601 week → 'YYYY-Www' (ej: '2026-W25'). Usa el año-ISO (%G), no el
  año calendario, para evitar bugs en bordes de año (ej: 2024-12-30 = 2025-W01)."
  (let [t (iso->epoch s)]
    (when t (vfn.strftime "%G-W%V" t))))

(fn flatten-pr [n]
  "Aplana un nodo de PR de GraphQL a una tabla plana.
  :days-to-merge = días (float) entre first-commit-at y merged-at."
  (let [merged-at n.mergedAt
        first-commit-at (?. n :commits :nodes 1 :commit :committedDate)]
    {:number n.number
     :title n.title
     :url n.url
     :repo (?. n :repository :nameWithOwner)
     : merged-at
     : first-commit-at
     :days-to-merge (diff-days first-commit-at merged-at)
     :merged-week (iso-week merged-at)}))

(fn merged-prs [?query]
  "Lista plana de mis PRs mergeados (todos los repos donde tengo PRs).
  Cada item: {:number :title :url :repo :merged-at :first-commit-at}.
  ?query: query de búsqueda extra (default: 'author:@me is:pr is:merged')."
  (let [q (or ?query "author:@me is:pr is:merged")
        all []]
    (var cursor nil)
    (var done? false)
    (while (not done?)
      (let [page (fetch-page q 100 cursor)]
        (if (not page)
          (set done? true)
          (do
            (each [_ n (ipairs page.nodes)]
              (table.insert all (flatten-pr n)))
            (if page.next-cursor
              (set cursor page.next-cursor)
              (set done? true))))))
    all))

(fn merged-prs-in-repo [owner-repo]
  "Misma lista, filtrada a un repo (ej: 'soxhub/machine-learning')."
  (merged-prs (.. "author:@me is:pr is:merged repo:" owner-repo)))

;; ── Helpers de presentación (opcionales) ──────────

(fn format-row [p]
  "String de una línea por PR — útil para imprimir en el REPL."
  (string.format "%s  #%d  %s → %s  (%5.1fd)  %s"
                 (or p.repo "?")
                 (or p.number 0)
                 (or p.first-commit-at "?")
                 (or p.merged-at "?")
                 (or p.days-to-merge 0)
                 (or p.title "")))

(fn print-all [?prs]
  "Imprime todos los PRs en una línea cada uno. Si no se pasa lista, los fetcha."
  (let [prs (or ?prs (merged-prs))]
    (each [_ p (ipairs prs)]
      (print (format-row p)))
    prs))

; (merged-prs)
; (merged-prs-in-repo "soxhub/machine-learning")
; (print-all)

{: merged-prs
 : merged-prs-in-repo
 : format-row
 : print-all
 : iso-week
 : diff-days}
