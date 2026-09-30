import Foundation

public enum ReportRenderer {
    public static func json(_ snapshot: FleetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var exported = snapshot
        for index in exported.logs.indices {
            exported.logs[index].signalAssessment = snapshot.logs[index].assessment
            exported.logs[index].identityProvisional = snapshot.logs[index].isProvisionalIdentity
        }
        return try encoder.encode(exported)
    }

    public static func html(_ snapshot: FleetSnapshot) -> String {
        html(snapshot, manifest: .describing(snapshot))
    }

    public static func document(_ snapshot: FleetSnapshot, manifest: ReportScopeManifest? = nil,
                                byteBudget: Int = 10 * 1024 * 1024) -> ReportHTMLDocument {
        let manifest = manifest ?? .describing(snapshot)
        let html = html(snapshot, manifest: manifest)
        return ReportHTMLDocument(html: html, manifest: manifest, byteCount: html.utf8.count, byteBudget: max(0, byteBudget))
    }

    public static func html(_ snapshot: FleetSnapshot, manifest: ReportScopeManifest) -> String {
        cancellableHTML(snapshot, manifest: manifest, isCancelled: { false })
    }

    /// The export service checks cancellation again before publishing. Returning
    /// early here bounds the rendering work without creating a partial file.
    public static func cancellableHTML(_ snapshot: FleetSnapshot, manifest: ReportScopeManifest,
                                       isCancelled: () -> Bool) -> String {
        if isCancelled() { return "" }
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        func number(_ n: Double) -> String { n.isFinite ? String(format: "%.2f", n) : "non disponible" }
        func sectionLabel(_ key: String) -> String {
            ["messages": "messages", "metrics": "mesures", "metadata": "métadonnées", "topics": "noms des topics", "sources": "sources",
             "parameters": "paramètres initiaux", "parameterChanges": "changements de paramètres", "topicDetails": "instances et champs des topics",
             "events": "événements", "telemetry": "séries de mesures",
             "metadataDetails": "informations et provenance", "parameterDetails": "paramètres typés",
             "dropouts": "interruptions de journalisation", "batteryDetails": "batteries par instance",
             "gnssDetails": "GNSS par récepteur"][key] ?? key
        }
        let exportedAt = manifest.generatedAt.isEmpty ? snapshot.generatedAt : manifest.generatedAt
        let alertMessageCount = snapshot.validLogs.reduce(0) { $0 + $1.messages.filter(\.isAlert).count }
        let alertLogCount = snapshot.validLogs.filter { $0.messages.contains(where: \.isAlert) || ($0.failsafeObserved && ($0.selectionIncludesFailsafe ?? true)) }.count
        let alertHelp = LibraryHelp.alerts + " Ce compteur porte sur les messages textuels et les états failsafe. Les événements PX4 restent décrits dans le badge de chaque log."
        let scannedLabel = "\(snapshot.scannedDroneCount) drone\(snapshot.scannedDroneCount > 1 ? "s" : "") scanné\(snapshot.scannedDroneCount > 1 ? "s" : "")"
        let provisionalLabel = "\(snapshot.provisionalDroneCount) identité\(snapshot.provisionalDroneCount > 1 ? "s" : "") provisoire\(snapshot.provisionalDroneCount > 1 ? "s" : "")"
        let alertDetail = "\(alertMessageCount) message\(alertMessageCount == 1 ? "" : "s") d’alerte · \(snapshot.failsafeLogCount) log\(snapshot.failsafeLogCount == 1 ? "" : "s") avec failsafe"
        let completenessLabel = manifest.completeness == .summary ? "résumés" : manifest.completeness == .detailed ? "détails chargés" : "détails partiels"
        let identityMethod = manifest.unavailableSections.contains("identity")
            ? "Les identités de ce rapport sont anonymisées. Les chemins, positions, textes et métadonnées brutes sont retirés de toutes les pièces ; les groupes restent distincts sans exposer leur texte source."
            : "Les identifiants de logs sont calculés par SHA256 : les copies identiques ne comptent qu’une fois. Deux contrôleurs portant le même numéro restent deux identités distinctes. Une identité sans UUID reste provisoire."
        func severity(_ level: String) -> String {
            let tone = LogMessage.rank(level) >= 5 ? "danger" : LogMessage.rank(level) >= 4 ? "warning" : "neutral"
            return "<span class=\"severity \(tone)\">\(h(level))</span>"
        }
        func items(_ values: [String]) -> String { values.map { "<li>\(h($0))</li>" }.joined() }
        func help(_ label: String, _ text: String) -> String {
            "<details class=\"report-help\"><summary title=\"\(h(text))\" aria-label=\"Aide : \(h(label))\">ⓘ</summary><p>\(h(text))</p></details>"
        }
        func statLabel(_ label: String, _ text: String) -> String {
            "<div class=\"stat-label\"><span title=\"\(h(text))\">\(h(label))</span>\(help(label, text))</div>"
        }
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
        <main class="report-shell"><section class="hero" id="overview"><div><p class="eyebrow">RAPPORT DE FLOTTE · PX4 / ULOG</p><h1>Les traces de votre flotte.</h1><p class="lede">Des enregistrements aux signaux à examiner.</p></div><div class="meta"><span class="pill">Rapport local · autonome</span><p>\(h(period))</p><small>Exporté le \(h(exportedAt))</small></div></section>
        <section class="panel" id="export-scope" aria-label="Périmètre de l’export" style="margin-bottom:20px"><p class="eyebrow">PÉRIMÈTRE EXPORTÉ</p><h2>\(h(manifest.scopeDescription))</h2><p>\(logs.count) logs · \(scannedLabel) · \(provisionalLabel) · \(logs.reduce(0) { $0 + $1.messages.count }) messages conservés. \(manifest.includesMaskedMessages ? "Les messages masqués sont inclus." : "Les messages masqués sont exclus de cette sélection.")</p><p class="muted">Couverture : \(completenessLabel) · révision : \(h(manifest.revision ?? "non renseignée")). Ce document présente une analyse ; il ne remplace pas les fichiers ULog originaux.</p><p class="muted">Sections disponibles : \(h(manifest.availableSections.map(sectionLabel).joined(separator: ", "))). \(manifest.unavailableSections.isEmpty ? "" : "Sections absentes ou non chargées pour certains logs : " + h(manifest.unavailableSections.map(sectionLabel).joined(separator: ", ")) + ".")</p></section>
        <section class="scope-bar" aria-label="Filtres du rapport"><div class="filter-controls" id="filter-controls" hidden>
        <label>Drone<select id="drone-filter"><option value="">Tous les drones</option>\(snapshot.drones.map { "<option value=\"\(h($0.id))\">\(h($0.name)) · \(h($0.id))</option>" }.joined())</select></label>
        <label>Famille<select id="family-filter"><option value="">Toutes les familles</option>\(Set(logs.flatMap { $0.messages.map(\.family) }).sorted().map { "<option value=\"\(h($0))\">\(h($0))</option>" }.joined())</select></label>
        <label>Niveau<select id="level-filter"><option value="">Tous les messages</option><option value="ALERTS">Alertes repérées</option><option value="ERROR+">ERROR et plus</option><option value="WARNING+">WARNING et plus</option><option value="INFO">INFO</option><option value="DEBUG">DEBUG</option></select></label>
        <label class="search-label">Recherche<input id="report-search" type="search" placeholder="Message, fichier, date, identité…" autocomplete="off"></label><button type="button" id="reset-filters">Réinitialiser</button></div>
        <p class="filter-status" id="filter-status" role="status" aria-live="polite">Tout le périmètre exporté · \(logs.count) fichiers · \(snapshot.drones.count) identités</p></section>
        <section class="stats" aria-label="Chiffres du périmètre"><div class="stat">\(statLabel("Drones scannés", LibraryHelp.drones))<strong id="stat-drones">\(snapshot.scannedDroneCount)</strong><small id="stat-provisional">\(provisionalLabel)</small></div><div class="stat">\(statLabel("Fichiers ULog", LibraryHelp.analysisQuality))<strong id="stat-logs">\(logs.count)</strong><small id="stat-quality">\(snapshot.validLogs.count) lisibles · \(logs.count - snapshot.validLogs.count) en erreur</small></div><div class="stat">\(statLabel("Durée enregistrée", LibraryHelp.recordedDuration))<strong id="stat-duration">\(number(snapshot.totalDurationSeconds / 60))<em> min</em></strong><small>Inclut les périodes au sol</small></div><div class="stat">\(statLabel("Temps de vol cumulé", LibraryHelp.flightDuration))<strong id="stat-flight">\(snapshot.totalFlightSeconds.map { number($0 / 60) + "<em> min</em>" } ?? "Non disponible")</strong><small id="stat-flight-coverage">Calculé sur \(snapshot.flightLogCount) / \(logs.count) logs</small></div><div class="stat">\(statLabel("Logs avec alertes", alertHelp))<strong id="stat-alerts">\(alertLogCount)<em> / \(snapshot.validLogs.count)</em></strong><small id="stat-alert-detail">\(alertDetail)</small></div></section>
        <section class="dashboard-grid" aria-label="Graphiques"><article class="panel"><div class="panel-heading"><div><p class="eyebrow">PROFIL DES ALERTES TEXTUELLES</p><div class="heading-with-help"><h2 title="\(h(LibraryHelp.profile))">Les familles présentes</h2>\(help("Profil des alertes", LibraryHelp.profile))</div><p>Nombre de logs avec un message d’alerte · les états failsafe restent comptés séparément.</p></div><span class="pill" id="radar-scale">0 — \(snapshot.validLogs.count) logs</span></div><div class="chart-space" id="family-chart">
        """)
        let familyCounts = Dictionary(grouping: snapshot.validLogs.flatMap { log in Set(log.messages.filter(\.isAlert).map(\.family)).map { ($0, log.id) } }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }).count }
        if familyCounts.isEmpty { out.append("<p class=\"empty-state\">Aucun message d’alerte textuel affiché. Consulter le badge et la couverture de chaque log.</p>") }
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
        <p class="notice">Une alerte n’est pas une panne confirmée. Le badge suit la gravité des signaux observés, séparément de la qualité de lecture. Un événement sans traduction conserve son niveau connu, sans motif inventé. Les domaines absents des logs restent non évalués.</p><p class="muted" id="assessment-scope">\(logs.contains { ($0.selectionIncludesEvents ?? $0.selectionIncludesFailsafe) == false } ? "Badge limité aux messages de la sélection capturée : événements PX4 et état failsafe exclus du périmètre." : "Badge : messages, événements PX4 disponibles et état failsafe dans le périmètre exporté.")</p><div class="assessment-legend" title="\(h(LibraryHelp.assessment))"><p>Légende : Signal critique · Erreur à vérifier · Avertissement · Aucune alerte détectée (dans la couverture disponible) · Niveau indéterminé.</p>\(help("Badge du log", LibraryHelp.assessment))</div>
        <section id="signals"><div class="section-heading"><div><p class="eyebrow">COMPRENDRE LES SIGNAUX</p><h2>Messages et explications</h2><p>Ouvrir un groupe pour retrouver son sens, ses limites et les logs concernés.</p></div><span class="pill" id="group-summary">\(groups.count) groupes · \(logs.reduce(0) { $0 + $1.messages.count }) messages</span></div><div class="empty-state" id="groups-empty" \(groups.isEmpty ? "" : "hidden")>Aucun message dans ce périmètre.</div><div class="group-list">
        """)
        var hasOtherGroups = false
        for (groupIndex, group) in groups.enumerated() {
            if isCancelled() { return "" }
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
            out.append("<p class=\"raw\">\(h(message.text))</p><p class=\"muted\">Même texte et même niveau ; le nombre de répétitions ne mesure pas le nombre d’incidents.</p><noscript class=\"occurrence-fallback\"><div class=\"table-wrap\"><table><thead><tr><th>Drone</th><th>Log</th><th>Messages</th></tr></thead><tbody>")
            let byLog = Dictionary(grouping: group.occurrences, by: \.logID)
            for logID in byLog.keys.sorted() {
                if isCancelled() { return "" }
                guard let occurrence = byLog[logID]?.first, let logIndex = logIndices[logID] else { continue }
                out.append("<tr class=\"group-occurrence\" data-log=\"\(h(logID))\"><td>\(h(occurrence.droneName))</td><td><a href=\"#log-\(logIndex)\" data-open-log=\"log-\(logIndex)\">\(h(logs[logIndex].fileName)) · \(h(occurrence.date))</a></td><td class=\"occurrence-message-count\">\(byLog[logID]!.count)</td></tr>")
            }
            out.append("</tbody></table></div></noscript><div class=\"lazy-occurrence-table\" hidden></div></div></details>")
        }
        if hasOtherGroups { out.append("</div></details>") }
        out.append("</div></section><section id=\"history\"><div class=\"section-heading\"><div><p class=\"eyebrow\">REMONTÉE AUX SOURCES</p><h2>L’historique des drones</h2><p>Les détails complets restent dans ce fichier, y compris les messages informatifs.</p></div><button type=\"button\" id=\"expand-logs\" hidden>Déplier les logs visibles</button></div><div class=\"empty-state\" id=\"logs-empty\" \(logs.isEmpty ? "" : "hidden")>Aucun log dans ce périmètre.</div>")
        for drone in snapshot.drones {
            if isCancelled() { return "" }
            out.append("<section class=\"drone-section\" data-drone=\"\(h(drone.id))\"><h2>\(h(drone.name))</h2><p class=\"drone-meta mono\">\(h(drone.id))</p>")
            for log in drone.logs {
                if isCancelled() { return "" }
                guard let index = logIndices[log.id] else { continue }
                out.append("<details class=\"log-card\" data-log=\"\(h(log.id))\" id=\"log-\(index)\"><summary><span class=\"log-title\"><strong>\(h(log.fileName))</strong><small>\(h(log.date.isEmpty ? "Date inconnue" : log.date))</small></span><span class=\"log-meta\">\(number(log.durationSeconds / 60)) min enregistrées · <span class=\"visible-message-count\">\(log.messages.count) message\(log.messages.count > 1 ? "s" : "")</span></span><span class=\"log-assessment \(h(log.assessment.tone))\" title=\"\(h(log.assessment.help))\">\(h(log.assessment.label))</span><span class=\"log-status\" title=\"\(h(LibraryHelp.analysisQuality))\">\(h(log.analysisQualityLabel))</span></summary><div class=\"log-body\"><div class=\"detail-grid\"><div class=\"detail-box\"><h3>Identité et provenance</h3><p>Nom source : \(h(log.droneName)). Numéro attribué manuellement : \(h(log.stockNumber ?? "non renseigné")).</p><p>Identité de l’annotation : <code>\(h(log.annotationKey))</code>.</p>")
                if let warning = log.annotationWarning { out.append("<p class=\"notice\">Identité à vérifier : \(h(warning))</p>") }
                if log.metadata["gcsUUID"] == nil && log.annotationKey.hasPrefix("gcs:") { out.append("<p class=\"muted\">Lien GCS local établi à partir des autres logs du même contrôleur. Cet UUID n’a pas été observé dans ce fichier ; les métadonnées source sont conservées.</p>") }
                let identityLabel = manifest.unavailableSections.contains("identity") ? "Identifiant anonymisé" : "SHA256"
                out.append("<p>\(identityLabel) : <code>\(h(log.id))</code></p><ul class=\"coverage-list mono\">\(items(log.sourcePaths))</ul></div><div class=\"detail-box\"><h3>Contexte de l’enregistrement</h3>\(help("Durées de l’enregistrement", LibraryHelp.flightDuration))<p>Durée enregistrée : \(number(log.durationSeconds)) s. Temps déclaré en vol par le détecteur (landed=false) : \(log.flightSeconds.flatMap { $0.isFinite && $0 >= 0 && log.status != "error" ? number($0) + " s" : nil } ?? "non calculable").</p><p>Date issue de : \(h(log.dateSource)). Failsafe observé : \(log.failsafeObserved ? "oui" : "non repéré").</p><p class=\"muted\">Les durées et mesures portent sur la portion enregistrée.</p></div></div>")
                if !log.issues.isEmpty { out.append("<div class=\"notice\"><h3>Qualité du fichier</h3><ul>\(items(log.issues))</ul></div>") }
                out.append("<div class=\"detail-box assessment-detail\"><div class=\"heading-with-help\"><h3>Signaux dans ce log</h3>\(help("Signaux du log", LibraryHelp.assessment))</div><p class=\"assessment-description\">\(h(log.assessment.help))</p><p class=\"assessment-primary raw\">\(h(log.assessment.reason))</p><p class=\"muted assessment-counts\">\(log.assessment.occurrenceCount) occurrences de signaux · \(log.assessment.eventCount) événements observés · \(log.assessment.untranslatedEventCount) sans traduction.</p></div>")
                out.append("<h3>Mesures disponibles</h3><div class=\"table-wrap\"><table><thead><tr><th>Mesure</th><th>Valeur</th><th>Méthode / portée</th></tr></thead><tbody>")
                for metric in log.metrics { out.append("<tr><td>\(h(metric.label))</td><td>\(number(metric.value)) \(h(metric.unit))</td><td>\(h(metric.detail))</td></tr>") }
                out.append("</tbody></table></div><h3>Couverture et limites</h3><ul class=\"coverage-list\">\(items(log.coverage))</ul><details class=\"technical\"><summary>Métadonnées et topics</summary><div class=\"table-wrap\"><table><tbody>\(log.metadata.keys.sorted().map { "<tr><th>\(h($0))</th><td class=\"raw\">\(h(log.metadata[$0] ?? ""))</td></tr>" }.joined())</tbody></table></div><p class=\"raw\">\(log.topics.map(h).joined(separator: ", "))</p></details><h3>Messages texte</h3><p class=\"muted\">Temps relatif au début du log. Une valeur négative indique un message mis en tampon avant l’ouverture. Les filtres ne modifient pas les données embarquées.</p><noscript class=\"message-fallback\"><div class=\"table-wrap\"><table class=\"message-table\"><thead><tr><th>t (s)</th><th>Niveau</th><th>Famille</th><th>Message source</th></tr></thead><tbody>")
                for (messageIndex, message) in log.messages.enumerated() {
                    if isCancelled() { return "" }
                    let family = h(message.family) + (message.sourceFamily.map { "<small>Manuelle · détectée : \(h($0))</small>" } ?? "")
                    out.append("<tr class=\"message-row\" data-index=\"\(messageIndex)\"><td class=\"mono\">\(number(message.timestampSeconds))</td><td>\(severity(message.level))</td><td>\(family)</td><td class=\"raw\">\(h(message.text))</td></tr>")
                }
                out.append("</tbody></table></div></noscript><div class=\"lazy-message-table\" hidden></div>")
                out.append(detailedSections(log, escape: h, number: number, isCancelled: isCancelled))
                out.append("</div></details>")
            }
            out.append("</section>")
        }
        out.append("""
        </section><section id="sources" class="panel"><div class="section-heading"><div><p class="eyebrow">TRAÇABILITÉ</p><div class="heading-with-help"><h2 title="\(h(LibraryHelp.provenance))">Sources et méthode</h2>\(help("Sources", LibraryHelp.provenance))</div></div><span class="pill">\(snapshot.sourceFolders.count) dossier\(snapshot.sourceFolders.count > 1 ? "s" : "")</span></div><ul class="coverage-list mono">\(items(snapshot.sourceFolders))</ul><p class="muted">\(h(LibraryHelp.provenance))</p><p>\(h(identityMethod))</p><p>Les graphiques concernent les données sélectionnées. Les messages INFO/DEBUG restent disponibles. Les dates GPS sont en UTC ; une date issue du chemin ne fournit pas de fuseau horaire. Les familles peuvent se recouper : leurs valeurs ne s’additionnent pas pour calculer un total de pannes.</p><p>Ce document inclut les données exportées, indépendamment de la disponibilité de la GCS. Les filtres sont locaux et aucun fichier source n’est modifié.</p></section><footer class="report-footer"><span>kataLOG · Rapport de flotte</span><span>Généré le \(h(exportedAt)) · Données conservées dans ce document</span></footer></main>
        """)
        // All source rows remain in the noscript fallback. The bounded visible
        // tables are built on opening a detail, using this complete projection.
        let dashboardLogs: [[String: Any]] = logs.map { log in
            let assessment = (try? JSONEncoder().encode(log.assessment)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
            return ["id": log.id, "droneID": log.droneID, "droneName": log.displayName,
             "sourceName": log.droneName, "fileName": log.fileName, "date": log.date, "dateSource": log.dateSource,
             "status": log.status, "durationSeconds": log.durationSeconds.isFinite ? log.durationSeconds : 0,
             "flightSeconds": log.flightSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } as Any? ?? NSNull(),
             "identityProvisional": log.isProvisionalIdentity,
             "signalAssessment": assessment,
             "failsafeObserved": log.failsafeObserved,
             "selectionIncludesFailsafe": log.selectionIncludesFailsafe ?? true,
             "selectionIncludesEvents": log.selectionIncludesEvents ?? log.selectionIncludesFailsafe ?? true,
             "messages": log.messages.enumerated().map { index, m -> [String: Any] in
                 var value: [String: Any] = ["index": index, "id": m.id, "groupKey": m.groupKey, "level": m.level,
                  "family": m.family, "title": m.title, "text": m.text, "isAlert": m.isAlert,
                  "timeSeconds": m.timestampSeconds.isFinite ? m.timestampSeconds as Any : NSNull()]
                 if let source = m.sourceFamily { value["sourceFamily"] = source }
                 return value
             }]
        }
        var enhancement = ""
        let manifestObject = (try? JSONEncoder().encode(manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let data = try? JSONSerialization.data(withJSONObject: ["logs": dashboardLogs, "manifest": manifestObject ?? [:]], options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let safe = json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
                .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            enhancement = "<script id=\"report-data\" type=\"application/json\">\(safe)</script><script>\(ReportInteraction.script)</script>"
        }
        if isCancelled() { return "" }
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>KataLog · Rapport de flotte</title><style>\(ReportStyle.css)</style></head><body>
        \(out.joined(separator: "\n"))
        <noscript><p class="notice">JavaScript est désactivé : le rapport complet reste lisible. Les filtres et graphiques interactifs nécessitent JavaScript.</p></noscript>
        \(enhancement)
        </body></html>
        """
    }

    private static func detailedSections(_ log: FlightLog, escape h: (String) -> String,
                                         number: (Double) -> String, isCancelled: () -> Bool) -> String {
        var sections: [String] = []
        if let parameters = log.parameters {
            sections.append("<details class=\"technical parameters-detail\"><summary>Paramètres initiaux · \(parameters.count)</summary>")
            if parameters.isEmpty { sections.append("<p>Aucun paramètre initial enregistré.</p>") }
            else {
                sections.append("<div class=\"table-wrap\"><table><thead><tr><th>Paramètre</th><th>Valeur source</th></tr></thead><tbody>")
                for name in parameters.keys.sorted() {
                    if isCancelled() { return "" }
                    sections.append("<tr><td class=\"mono\">\(h(name))</td><td class=\"raw\">\(h(parameters[name] ?? ""))</td></tr>")
                }
                sections.append("</tbody></table></div>")
            }
            sections.append("</details>")
        }
        if let changes = log.parameterChanges {
            sections.append("<details class=\"technical parameter-changes-detail\"><summary>Changements de paramètres · \(changes.count)</summary>")
            if changes.isEmpty { sections.append("<p>Aucun changement de paramètre enregistré.</p>") }
            else {
                sections.append("<div class=\"table-wrap\"><table><thead><tr><th>t (s)</th><th>Paramètre</th><th>Valeur source</th></tr></thead><tbody>")
                for change in changes {
                    if isCancelled() { return "" }
                    sections.append("<tr><td>\(number(change.timeSeconds))</td><td class=\"mono\">\(h(change.name))</td><td class=\"raw\">\(h(change.value))</td></tr>")
                }
                sections.append("</tbody></table></div>")
            }
            sections.append("</details>")
        }
        if let topics = log.topicDetails {
            sections.append("<details class=\"technical topics-detail\"><summary>Topics : instances et champs · \(topics.count)</summary><div class=\"table-wrap\"><table><thead><tr><th>Topic</th><th>Instance</th><th>Échantillons</th><th>Champs et unités</th></tr></thead><tbody>")
            for topic in topics {
                if isCancelled() { return "" }
                let fields = topic.fields.map { field in h(field) + " · " + h(topic.fieldUnits?[field] ?? "unité non renseignée") }.joined(separator: "<br>")
                sections.append("<tr><td class=\"mono\">\(h(topic.name))</td><td>\(topic.instance)</td><td>\(topic.sampleCount)</td><td class=\"raw\">\(fields)</td></tr>")
            }
            sections.append("</tbody></table></div></details>")
        }
        let recorded: [(String, JSONValue?)] = [
            ("Informations enregistrées et provenance", log.metadataDetails),
            ("Paramètres typés et changements", log.parameterDetails),
            ("Batteries par instance · numéro de série du pack", log.batteryDetails),
            ("GNSS par récepteur", log.gnssDetails),
            ("Interruptions de journalisation", log.dropouts.map(JSONValue.array))
        ]
        for (title, value) in recorded {
            if let value {
                if isCancelled() { return "" }
                sections.append("<details class=\"technical recorded-detail\"><summary>\(h(title))</summary><pre style=\"white-space:pre-wrap;overflow-wrap:anywhere\">\(h(value.description))</pre></details>")
            }
        }
        if let events = log.events {
            sections.append("<details class=\"technical events-detail\"><summary>Événements enregistrés · \(events.count)</summary><p class=\"muted\">Les valeurs brutes sont conservées. Une définition absente reste inconnue.</p><div class=\"table-wrap\"><table><thead><tr><th>t (s)</th><th>ID événement</th><th>Niveau</th><th>Message / provenance</th><th>Arguments bruts</th></tr></thead><tbody>")
            for event in events {
                if isCancelled() { return "" }
                sections.append("<tr><td>\(event.timeSeconds.map(number) ?? "—")</td><td>\(h(event.eventID.description))</td><td>\(h(event.level))</td><td class=\"raw\">\(h(event.message ?? "Définition non disponible"))<small>\(h(event.definitionSource ?? "Provenance non disponible"))</small></td><td class=\"raw\">\(h(event.argumentsHex))</td></tr>")
            }
            sections.append("</tbody></table></div></details>")
        }
        if let telemetry = log.telemetry {
            sections.append("<details class=\"technical telemetry-detail\"><summary>Séries de mesures disponibles · \(telemetry.count)</summary><p class=\"muted\">Ces relevés peuvent être réduits. Ils restent distincts des échantillons originaux du fichier ULog ; les segments séparent les interruptions.</p>")
            for series in telemetry {
                if isCancelled() { return "" }
                sections.append("<details class=\"technical\"><summary>\(h(series.label)) · \(series.points.count) / \(series.originalSampleCount) points</summary><p>Unité : \(h(series.unit)). Source : \(h(series.source)).</p>\(TelemetryReport.svg(series))<div class=\"table-wrap\"><table><thead><tr><th>t (s)</th><th>Valeur</th><th>Segment</th></tr></thead><tbody>")
                for point in series.points {
                    if isCancelled() { return "" }
                    sections.append("<tr><td>\(number(point.timeSeconds))</td><td>\(number(point.value))</td><td>\(point.segment)</td></tr>")
                }
                sections.append("</tbody></table></div></details>")
            }
            sections.append("</details>")
        }
        return sections.joined()
    }
}
