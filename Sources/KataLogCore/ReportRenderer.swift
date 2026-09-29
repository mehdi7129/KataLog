import Foundation

public enum ReportRenderer {
    public static func json(_ snapshot: FleetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    public static func html(_ snapshot: FleetSnapshot) -> String {
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        func number(_ n: Double) -> String { n.isFinite ? String(format: "%.2f", n) : "non disponible" }
        func severity(_ level: String) -> String {
            let tone = LogMessage.rank(level) >= 5 ? "danger" : LogMessage.rank(level) >= 4 ? "warning" : "neutral"
            return "<span class=\"severity \(tone)\">\(h(level))</span>"
        }
        func items(_ values: [String]) -> String { values.map { "<li>\(h($0))</li>" }.joined() }
        let allGroups = snapshot.alertGroups
        let groups = allGroups.filter(\.isAlert) + allGroups.filter { !$0.isAlert }
        let logs = snapshot.logs
        var logIndices: [String: Int] = [:]
        for (index, log) in logs.enumerated() where logIndices[log.id] == nil { logIndices[log.id] = index }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = logs.compactMap { log -> String? in
            guard log.date.range(of: #"^\d{4}-\d{2}-\d{2}(?=$|T| )"#, options: .regularExpression) != nil else { return nil }
            let day = String(log.date.prefix(10))
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            let actual = calendar.dateComponents([.year, .month, .day], from: date)
            return actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2] ? day : nil
        }.sorted()
        let period = days.first.map { $0 == days.last ? $0 : "\($0) → \(days.last!)" } ?? "Période non renseignée"
        let logo = "<svg viewBox=\"0 0 40 40\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M20 3 3 12a2 2 0 0 0 0 4l17 9 17-9a2 2 0 0 0 0-4L20 3Zm-17 19v4l17 9 17-9v-4l-17 9-17-9Zm0 9v4l17 9 17-9v-4l-17 9-17-9Z\" transform=\"translate(2 0) scale(.9)\"/></svg>"
        var out: [String] = []
        out.append("""
        <header class="topbar"><div class="topbar-inner"><a class="brand" href="#overview">\(logo)<span>kataLOG</span></a><nav aria-label="Sections du rapport"><a href="#overview">Synthèse</a><a href="#signals">Messages</a><a href="#history">Historique</a><a href="#sources">Sources</a></nav><div class="actions" hidden id="report-actions"><button type="button" id="theme-toggle" aria-label="Changer le thème">Clair / sombre</button><button type="button" id="print-report">Imprimer / PDF</button></div></div></header>
        <main class="report-shell"><section class="hero" id="overview"><div><p class="eyebrow">RAPPORT DE FLOTTE · PX4 / ULOG</p><h1>Les traces de votre flotte.</h1><p class="lede">Des enregistrements aux signaux à examiner.</p></div><div class="meta"><span class="pill">Rapport local · autonome</span><p>\(h(period))</p><small>Exporté le \(h(snapshot.generatedAt))</small></div></section>
        <section class="scope-bar" aria-label="Filtres du rapport"><div class="filter-controls" id="filter-controls" hidden>
        <label>Drone<select id="drone-filter"><option value="">Tous les drones</option>\(snapshot.drones.map { "<option value=\"\(h($0.id))\">\(h($0.name)) · \(h($0.id))</option>" }.joined())</select></label>
        <label>Famille<select id="family-filter"><option value="">Toutes les familles</option>\(Set(logs.flatMap { $0.messages.map(\.family) }).sorted().map { "<option value=\"\(h($0))\">\(h($0))</option>" }.joined())</select></label>
        <label>Niveau<select id="level-filter"><option value="">Tous les messages</option><option value="ALERTS">Alertes repérées</option><option value="ERROR+">ERROR et plus</option><option value="WARNING+">WARNING et plus</option><option value="INFO">INFO</option><option value="DEBUG">DEBUG</option></select></label>
        <label class="search-label">Recherche<input id="report-search" type="search" placeholder="Message, fichier, date, identité…" autocomplete="off"></label><button type="button" id="reset-filters">Réinitialiser</button></div>
        <p class="filter-status" id="filter-status" role="status" aria-live="polite">Toute la bibliothèque · \(logs.count) fichiers · \(snapshot.drones.count) identités</p></section>
        <section class="stats" aria-label="Chiffres du périmètre"><div class="stat"><span>Identités drone</span><strong id="stat-drones">\(snapshot.drones.count)</strong><small>Contrôleurs distincts</small></div><div class="stat"><span>Fichiers ULog</span><strong id="stat-logs">\(logs.count)</strong><small id="stat-quality">\(snapshot.validLogs.count) lisibles · \(logs.count - snapshot.validLogs.count) en erreur</small></div><div class="stat"><span>Durée enregistrée</span><strong id="stat-duration">\(number(snapshot.totalDurationSeconds / 60))<em> min</em></strong><small>Inclut les périodes au sol</small></div><div class="stat"><span>Logs avec alertes</span><strong id="stat-alerts">\(snapshot.alertLogCount)<em> / \(snapshot.validLogs.count)</em></strong><small id="stat-alert-detail">Messages repérés ou failsafe observé</small></div></section>
        <section class="dashboard-grid" aria-label="Graphiques"><article class="panel"><div class="panel-heading"><div><p class="eyebrow">PROFIL DES ALERTES</p><h2>Les familles présentes</h2><p>Nombre de logs concernés · les familles peuvent se recouper.</p></div><span class="pill" id="radar-scale">0 — \(snapshot.validLogs.count) logs</span></div><div class="chart-space" id="family-chart">
        """)
        let familyCounts = Dictionary(grouping: snapshot.validLogs.flatMap { log in Set(log.messages.filter(\.isAlert).map(\.family)).map { ($0, log.id) } }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }).count }
        if familyCounts.isEmpty { out.append("<p class=\"empty-state\">Aucune alerte textuelle repérée dans ce périmètre.</p>") }
        else {
            out.append("<div class=\"family-bars\">")
            for family in familyCounts.keys.sorted() {
                let count = familyCounts[family]!
                out.append("<a class=\"family-row\" href=\"#signals\"><span>\(h(family))</span><span class=\"bar-track\"><span class=\"bar-fill\" style=\"width:\(Double(count) / Double(max(snapshot.validLogs.count, 1)) * 100)%\"></span></span><strong>\(count)</strong></a>")
            }
            out.append("</div>")
        }
        out.append("""
        </div><div class="chart-legend" id="family-legend"></div><p class="muted chart-help">Une famille compte une seule fois par log. Ce graphique n’est pas un score de santé.</p></article>
        <article class="panel"><div class="panel-heading"><div><p class="eyebrow">ACTIVITÉ ENREGISTRÉE</p><h2>Les logs dans le temps</h2><p id="timeline-caption">Dates enregistrées dans les fichiers.</p></div></div><div class="timeline" id="timeline-chart"><p class="empty-state">Le graphique interactif apparaît lorsque JavaScript est activé. Les dates complètes restent dans l’historique.</p></div><div class="chart-legend"><span><i class="legend-total"></i> Tous les fichiers</span><span><i class="legend-alert"></i> Avec alertes</span></div><p class="muted chart-help" id="period-hint">Les dates de chemin n’ont pas de fuseau connu ; les dates GPS sont en UTC.</p></article></section>
        <p class="notice">Une alerte n’est pas une panne confirmée. Les domaines absents des logs et les événements binaires sans dictionnaire restent non évalués. Les limites sont détaillées pour chaque fichier.</p>
        <section id="signals"><div class="section-heading"><div><p class="eyebrow">COMPRENDRE LES SIGNAUX</p><h2>Messages et explications</h2><p>Ouvrir un groupe pour retrouver son sens, ses limites et les logs concernés.</p></div><span class="pill" id="group-summary">\(groups.count) groupes · \(logs.reduce(0) { $0 + $1.messages.count }) messages</span></div><div class="empty-state" id="groups-empty" \(groups.isEmpty ? "" : "hidden")>Aucun message dans ce périmètre.</div><div class="group-list">
        """)
        var hasOtherGroups = false
        for (groupIndex, group) in groups.enumerated() {
            if !group.isAlert && !hasOtherGroups {
                out.append("<details class=\"technical\" id=\"other-groups\"><summary id=\"other-groups-label\">Autres messages · \(groups.filter { !$0.isAlert }.count) groupes</summary><div class=\"group-list\">")
                hasOtherGroups = true
            }
            guard let message = group.occurrences.first?.message else { continue }
            let explanation = AlertKnowledge.explanation(for: message)
            out.append("<details class=\"alert-group\" data-group=\"\(h(group.id))\" id=\"group-\(groupIndex)\"><summary>\(severity(group.level))<span class=\"group-heading\"><strong>\(h(group.title))</strong><small>\(h(group.family))</small></span><span class=\"group-count\">\(group.logCount) logs · \(group.messageCount) messages</span></summary><div class=\"group-body\">")
            if group.isAlert {
                out.append("<div class=\"explanation\"><p class=\"eyebrow\">COMPRENDRE CE MESSAGE</p><h3>\(h(explanation.title))</h3><p>\(h(explanation.meaning))</p><ul class=\"checks\">\(items(explanation.checks))</ul><p class=\"limits\">\(h(explanation.limits))</p><small>\(h(explanation.provenance))</small><div class=\"source-links\">\(explanation.sources.map { "<a href=\"\(h($0.url.absoluteString))\" target=\"_blank\" rel=\"noopener noreferrer\">\(h($0.title)) ↗</a>" }.joined())</div></div>")
            }
            if let source = message.sourceFamily { out.append("<p class=\"muted\">Famille attribuée manuellement : \(h(message.family)). Famille détectée : \(h(source)).</p>") }
            out.append("<p class=\"raw\">\(h(message.text))</p><p class=\"muted\">Même texte et même niveau ; le nombre de répétitions ne mesure pas le nombre d’incidents.</p><div class=\"table-wrap\"><table><thead><tr><th>Drone</th><th>Log</th><th>Messages</th></tr></thead><tbody>")
            let byLog = Dictionary(grouping: group.occurrences, by: \.logID)
            for logID in byLog.keys.sorted() {
                guard let occurrence = byLog[logID]?.first, let logIndex = logIndices[logID] else { continue }
                out.append("<tr class=\"group-occurrence\" data-log=\"\(h(logID))\"><td>\(h(occurrence.droneName))</td><td><a href=\"#log-\(logIndex)\" data-open-log=\"log-\(logIndex)\">\(h(logs[logIndex].fileName)) · \(h(occurrence.date))</a></td><td>\(byLog[logID]!.count)</td></tr>")
            }
            out.append("</tbody></table></div></div></details>")
        }
        if hasOtherGroups { out.append("</div></details>") }
        out.append("</div></section><section id=\"history\"><div class=\"section-heading\"><div><p class=\"eyebrow\">REMONTÉE AUX SOURCES</p><h2>L’historique des drones</h2><p>Les détails complets restent dans ce fichier, y compris les messages informatifs.</p></div><button type=\"button\" id=\"expand-logs\" hidden>Déplier les logs visibles</button></div><div class=\"empty-state\" id=\"logs-empty\" \(logs.isEmpty ? "" : "hidden")>Aucun log dans ce périmètre.</div>")
        for drone in snapshot.drones {
            out.append("<section class=\"drone-section\" data-drone=\"\(h(drone.id))\"><h2>\(h(drone.name))</h2><p class=\"drone-meta mono\">\(h(drone.id))</p>")
            for log in drone.logs {
                guard let index = logIndices[log.id] else { continue }
                out.append("<details class=\"log-card\" data-log=\"\(h(log.id))\" id=\"log-\(index)\"><summary><span class=\"log-title\"><strong>\(h(log.fileName))</strong><small>\(h(log.date.isEmpty ? "Date inconnue" : log.date))</small></span><span class=\"log-meta\">\(number(log.durationSeconds / 60)) min · <span class=\"visible-message-count\">\(log.messages.count) message\(log.messages.count > 1 ? "s" : "")</span></span><span class=\"log-status \(log.status == "error" ? "danger" : log.status == "partial" ? "warning" : "neutral")\">\(h(log.status == "error" ? "Lecture impossible" : log.status == "partial" ? "Lecture partielle" : "Lisible"))</span></summary><div class=\"log-body\"><div class=\"detail-grid\"><div class=\"detail-box\"><h3>Identité et provenance</h3><p>Nom source : \(h(log.droneName)). Numéro attribué manuellement : \(h(log.stockNumber ?? "non renseigné")).</p><p>Identité de l’annotation : <code>\(h(log.annotationKey))</code>.</p>")
                if let warning = log.annotationWarning { out.append("<p class=\"notice\">Identité à vérifier : \(h(warning))</p>") }
                if log.metadata["gcsUUID"] == nil && log.annotationKey.hasPrefix("gcs:") { out.append("<p class=\"muted\">Lien GCS local établi à partir des autres logs du même contrôleur. Cet UUID n’a pas été observé dans ce fichier ; les métadonnées source sont conservées.</p>") }
                out.append("<p>SHA256 : <code>\(h(log.id))</code></p><ul class=\"coverage-list mono\">\(items(log.sourcePaths))</ul></div><div class=\"detail-box\"><h3>Contexte de l’enregistrement</h3><p>Durée enregistrée : \(number(log.durationSeconds)) s. Temps déclaré en vol par le détecteur (landed=false) : \(log.flightSeconds.map { number($0) + " s" } ?? "non calculable").</p><p>Date issue de : \(h(log.dateSource)). Failsafe observé : \(log.failsafeObserved ? "oui" : "non repéré").</p><p class=\"muted\">Les durées et mesures portent sur la portion enregistrée.</p></div></div>")
                if !log.issues.isEmpty { out.append("<div class=\"notice\"><h3>Qualité du fichier</h3><ul>\(items(log.issues))</ul></div>") }
                out.append("<h3>Mesures disponibles</h3><div class=\"table-wrap\"><table><thead><tr><th>Mesure</th><th>Valeur</th><th>Méthode / portée</th></tr></thead><tbody>")
                for metric in log.metrics { out.append("<tr><td>\(h(metric.label))</td><td>\(number(metric.value)) \(h(metric.unit))</td><td>\(h(metric.detail))</td></tr>") }
                out.append("</tbody></table></div><h3>Couverture et limites</h3><ul class=\"coverage-list\">\(items(log.coverage))</ul><details class=\"technical\"><summary>Métadonnées et topics</summary><div class=\"table-wrap\"><table><tbody>\(log.metadata.keys.sorted().map { "<tr><th>\(h($0))</th><td class=\"raw\">\(h(log.metadata[$0] ?? ""))</td></tr>" }.joined())</tbody></table></div><p class=\"raw\">\(log.topics.map(h).joined(separator: ", "))</p></details><h3>Messages texte</h3><p class=\"muted\">Temps relatif au début du log. Une valeur négative indique un message mis en tampon avant l’ouverture. Les filtres ne modifient pas les données embarquées.</p><div class=\"table-wrap\"><table class=\"message-table\"><thead><tr><th>t (s)</th><th>Niveau</th><th>Famille</th><th>Message source</th></tr></thead><tbody>")
                for (messageIndex, message) in log.messages.enumerated() {
                    let family = h(message.family) + (message.sourceFamily.map { "<small>Manuelle · détectée : \(h($0))</small>" } ?? "")
                    out.append("<tr class=\"message-row\" data-index=\"\(messageIndex)\"><td class=\"mono\">\(number(message.timestampSeconds))</td><td>\(severity(message.level))</td><td>\(family)</td><td class=\"raw\">\(h(message.text))</td></tr>")
                }
                out.append("</tbody></table></div></div></details>")
            }
            out.append("</section>")
        }
        out.append("""
        </section><section id="sources" class="panel"><div class="section-heading"><div><p class="eyebrow">TRAÇABILITÉ</p><h2>Sources et méthode</h2></div><span class="pill">\(snapshot.sourceFolders.count) dossiers</span></div><ul class="coverage-list mono">\(items(snapshot.sourceFolders))</ul><p>Les identifiants de logs sont calculés par SHA256 : les copies identiques ne comptent qu’une fois. Deux contrôleurs portant le même numéro restent deux identités distinctes. Une identité sans UUID reste provisoire.</p><p>Les graphiques concernent les données sélectionnées. Les messages INFO/DEBUG restent disponibles. Les dates GPS sont en UTC ; une date issue du chemin ne fournit pas de fuseau horaire. Les familles peuvent se recouper : leurs valeurs ne s’additionnent pas pour calculer un total de pannes.</p><p>Ce document inclut les données exportées, indépendamment de la disponibilité de la GCS. Les filtres sont locaux et aucun fichier source n’est modifié.</p></section><footer class="report-footer"><span>kataLOG · Rapport de flotte</span><span>Généré le \(h(snapshot.generatedAt)) · Données conservées dans ce document</span></footer></main>
        """)
        // Only the small, required dashboard projection is duplicated. All source
        // details stay in the server-rendered, usable-without-JavaScript document.
        let dashboardLogs: [[String: Any]] = logs.map { log in
            ["id": log.id, "droneID": log.droneID, "droneName": log.displayName,
             "sourceName": log.droneName, "fileName": log.fileName, "date": log.date, "dateSource": log.dateSource,
             "status": log.status, "durationSeconds": log.durationSeconds.isFinite ? log.durationSeconds : 0,
             "failsafeObserved": log.failsafeObserved,
             "messages": log.messages.enumerated().map { index, m -> [String: Any] in
                 ["index": index, "id": m.id, "groupKey": m.groupKey, "level": m.level,
                  "family": m.family, "title": m.title, "text": m.text, "isAlert": m.isAlert]
             }]
        }
        var enhancement = ""
        if let data = try? JSONSerialization.data(withJSONObject: ["logs": dashboardLogs], options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let safe = json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
                .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            enhancement = "<script id=\"report-data\" type=\"application/json\">\(safe)</script><script>\(ReportInteraction.script)</script>"
        }
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>KataLog · Rapport de flotte</title><style>\(ReportStyle.css)</style></head><body>
        \(out.joined(separator: "\n"))
        <noscript><p class="notice">JavaScript est désactivé : le rapport complet reste lisible. Les filtres et graphiques interactifs nécessitent JavaScript.</p></noscript>
        \(enhancement)
        </body></html>
        """
    }
}
