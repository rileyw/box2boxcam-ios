import SwiftUI
import UIKit
import AVKit

/// « Réglages avancés »: every setting, mode, diagnostic and manual control of the former single screen.
@MainActor
struct AdvancedSettingsView: View {
    @ObservedObject var model: DockKitModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var benchmark = ModelBenchmark()

    var body: some View { settings }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Caméra") {
                    Picker("Modèle de détection", selection: Binding(get: { model.camera.detectorProfile },
                        set: { model.setDetectorProfile($0) })) {
                        ForEach(BallDetectorProfile.allCases) { profile in Text(profile.title).tag(profile) }
                    }
                    LabeledContent("Vitesse maximale", value: String(format: "%.2f rad/s", model.speed))
                    Slider(value: $model.speed, in: 0.05...0.30, step: 0.01)
                    LabeledContent("Zoom", value: String(format: "×%.1f", model.camera.zoomFactor))
                    Button(model.camera.facing == .back ? "Passer à la caméra avant" : "Passer à la caméra arrière") {
                        Task { await model.setCameraFacing(model.camera.facing == .back ? .front : .back) }
                    }.disabled(model.isRecordingMatch || model.isChangingCamera || model.camera.isZooming)
                }
                Section("Suivi") {
                    Text(model.detectionPerformance).font(.caption.monospacedDigit())
                    Text(model.detectionSummary).font(.caption)
                    if !model.recordingMessage.isEmpty { Text(model.recordingMessage).font(.caption) }
                    Text("Pince l’image à deux doigts pour zoomer. Le suivi passe en pause pendant le réglage ; touche Suivre pour reprendre.").font(.caption)
                    Toggle("Hybride : ballon + joueurs", isOn: $model.useHybrid)
                    Text(model.camera.detectorProfile.description).font(.caption)
                    Toggle("Fenêtre locale autour du ballon", isOn: $model.useLocalSearchWindow)
                    Text("Expérimental, non validé sur iPhone. Analyse 960 × 960 px natifs autour du ballon suivi ; image entière une analyse sur 5 et après 2 analyses locales sans ballon.").font(.caption)
                    Toggle("Ignorer les objets immobiles", isOn: $model.ignoreStaticCandidates)
                    Text("Expérimental, non validé sur iPhone. Ignore une détection restée plus de 0,5 s au même endroit du décor (projecteur, marque, ballon ou sac au bord du terrain), en tenant compte du mouvement de la caméra. Un ballon arrêté pour un coup de pied arrêté est ignoré jusqu’à ce qu’il bouge.").font(.caption)
                    Toggle("Exposition courte", isOn: $model.useShortExposure)
                    Text("Expérimental, non validé sur iPhone. Limite l’exposition automatique à 1/250 s pour réduire le flou du ballon ; l’image peut être plus sombre ou plus bruitée la nuit.").font(.caption)
                    Toggle("Fiabilité pondérée par le score", isOn: $model.hybridConfidenceWeighting)
                    Text("Expérimental, non validé sur iPhone, mode hybride seulement. Multiplie la fiabilité du ballon par le score moyen du détecteur sur la piste (0 à 25 %, plein à 60 %) : un objet détecté en continu avec un score moyen ne prend plus la main ; un ballon déjà suivi tolère une baisse passagère du score.").font(.caption)
                    Toggle("Rester avec le groupe", isOn: $model.hybridStayWithGroup)
                    Text("Expérimental, non validé sur iPhone, mode hybride seulement. Quand les joueurs guident, réduit l’avance si une partie du groupe sort du cadre et revient vers le groupe s’il n’en reste qu’une poignée.").font(.caption)
                    Toggle("Zoom automatique", isOn: $model.useAutoZoom)
                    Text("Expérimental, non validé sur iPhone, mode hybride et suivi actif seulement. Resserre lentement (jusqu’à 2 fois le zoom choisi) quand le ballon est suivi de façon fiable et stable depuis 0,8 s, tient le zoom sur une brève perte et élargit vite quand le ballon est perdu ; sinon cadre prudemment le groupe de joueurs visible. Pincer l’image reprend la main : le nouveau zoom devient le cadrage large.").font(.caption)
                    Text(model.useHybrid ? (model.hybridDecision?.reason ?? "Analyse hybride en attente…") : model.ballMessage).font(.caption)
                    if let blocker = model.followStartBlocker, !model.isFollowing { Text(blocker).font(.caption).foregroundStyle(.secondary) }
                    Toggle("Repère et trace du ballon", isOn: $model.showBallTrail)
                    if model.useHybrid {
                        LabeledContent("Acquérir une piste", value: "\(Int(model.hybridAcquire * 100)) % de fiabilité")
                        Slider(value: $model.hybridAcquire, in: 0.50...0.95, step: 0.05)
                        LabeledContent("Abandonner une piste", value: "\(Int(model.hybridRetain * 100)) % de fiabilité")
                        Slider(value: $model.hybridRetain, in: 0.10...0.40, step: 0.05)
                        Text("La fiabilité mesure la continuité et la cohérence de la piste. Les propositions YOLO sont admises à partir de 10 %. Les joueurs prennent le relais pendant les pertes.").font(.caption)
                    } else {
                    Toggle("Anticiper le mouvement", isOn: $model.anticipateBall)
                    if model.anticipateBall {
                        LabeledContent("Avance", value: "\(Int(model.anticipationSeconds * 1000)) ms")
                        Slider(value: $model.anticipationSeconds, in: 0...0.06, step: 0.01)
                    }
                    LabeledContent("Confiance minimale", value: "\(Int(model.confidenceThreshold * 100)) %")
                    Slider(value: $model.confidenceThreshold, in: 0.15...0.75, step: 0.05)
                    }
                    LabeledContent("Tolérance au centre", value: String(format: "%.1f %%", model.deadZone * 100))
                    Slider(value: $model.deadZone, in: 0...0.05, step: 0.005)
                    if model.selectionLocation != nil { Button("Choix automatique du ballon") { model.clearBallSelection() } }
                    Text("Touche le ballon dans l’image pour le choisir.").font(.caption)
                }
                Section("Limite d’angle") {
                    Toggle("Limite d’angle", isOn: $model.useAngleLimits)
                    Text("Expérimental, non validé sur l’Osmo. Le suivi ne tourne jamais au-delà des limites enregistrées et ralentit dans les 5° qui les précèdent ; le retour vers le terrain reste libre. Oriente l’Osmo avec les flèches du contrôle manuel, puis enregistre chaque limite. Les limites sont effacées à chaque connexion de l’Osmo.").font(.caption)
                    if model.useAngleLimits {
                        Button("Définir la limite gauche") { model.setAngleLimit(.left) }.disabled(model.standPosition == nil)
                        Button("Définir la limite droite") { model.setAngleLimit(.right) }.disabled(model.standPosition == nil)
                        Button("Définir la limite basse") { model.setAngleLimit(.low) }.disabled(model.standPosition == nil)
                        if model.leftYawLimit != nil || model.rightYawLimit != nil || model.lowPitchLimit != nil {
                            Button("Effacer les limites", role: .destructive) { model.clearAngleLimits() }
                        }
                        Text(angleLimitsSummary).font(.caption.monospacedDigit())
                    }
                }
                Section("Moments à revoir") {
                    Toggle("Repérage automatique des moments", isOn: $model.autoHighlights)
                    Text("Pendant l’enregistrement, marque au plus un moment toutes les 8 s : ballon rapide pendant 0,5 s, ou ballon retrouvé de façon fiable après 3 s de perte. Le bouton « À revoir » marque un moment à la main. Les repères sont dans events.jsonl et highlights.json, à côté de la vidéo.").font(.caption)
                }
                Section("Diagnostic visuel") {
                    Toggle("Boîtes et scores YOLO", isOn: $model.showDetectionBoxes)
                    Toggle("Squelettes des joueurs", isOn: $model.showSkeletons)
                    Toggle("Orientations corporelles", isOn: $model.showBodyOrientations)
                    Toggle("Cible choisie et cible joueurs", isOn: $model.showDecisionTarget)
                    Text(model.hybridPerformance).font(.caption)
                    if let decision = model.hybridDecision {
                        Text(decision.reason).font(.caption)
                        Text(String(format: "Continuité %.0f %% · poids ballon %.0f %% · %d corps alignés",
                            decision.reliability * 100, decision.ballWeight * 100, decision.orientationSupport)).font(.caption)
                        if let inView = decision.groupInView, let peak = decision.groupPeak {
                            Text("\(decision.mode) · \(inView) joueurs visibles · pic récent \(peak)").font(.caption)
                        }
                        Text(decision.motionCompensated ? "Déplacement de l’image compensé" : "Recalage de l’image en attente")
                            .font(.caption)
                    }
                    Text("Jaune : ballon suivi (anneau plein), trace et orientations retenues. Blanc : ballon incertain, squelettes, orientations ambiguës (pâles), cible choisie (croix) et cible joueurs (losange). Pointillés : propositions YOLO. Les scores YOLO et la continuité de piste sont distincts.").font(.caption)
                }
                Section("Banc d’essai des modèles") {
                    Text("Mesure la latence de chaque modèle (ballon, joueurs, poses) seul, sur une image de synthèse, avec le Neural Engine, le GPU et le CPU. La caméra est coupée pendant la mesure (2 à 5 min). Partage le rapport JSON pour comparer les iPhone.").font(.caption)
                    Button(benchmark.isRunning ? "Mesure en cours…" : "Mesurer la latence des modèles") {
                        Task { await benchmark.run(camera: model.camera) }
                    }.disabled(benchmark.isRunning || model.isRecordingMatch || model.isChangingCamera)
                    if !benchmark.progress.isEmpty { Text(benchmark.progress).font(.caption.monospacedDigit()) }
                    if let report = benchmark.report {
                        Text(report.markdownTable).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    if let url = benchmark.reportURL {
                        ShareLink(item: url) { Label("Partager le rapport", systemImage: "square.and.arrow.up") }
                    }
                }
                Section("Connexion") {
                    Text(model.connectionMessage)
                    Button("Reconnecter l’Osmo") { model.reconnect() }.disabled(model.isRecordingMatch)
                    Text(model.camera.message).font(.caption)
                }
                Section {
                    DisclosureGroup("Contrôle manuel et axes") {
                        HStack {
                            direction("arrow.left", .left)
                            direction("arrow.up", .up)
                            direction("arrow.down", .down)
                            direction("arrow.right", .right)
                        }
                        LabeledContent("Durée d’impulsion", value: String(format: "%.1f s", model.pulseSeconds))
                        Slider(value: $model.pulseSeconds, in: 0.1...1, step: 0.1)
                        Toggle("Inverser gauche / droite", isOn: $model.invertYaw)
                        Toggle("Inverser haut / bas", isOn: $model.invertPitch)
                        Button("Contrôle manuel") { model.prepareManualControl() }
                        Button("Suivi Apple") { model.enableSystemTracking() }
                    }
                    DisclosureGroup("Journal et diagnostic") {
                        Text(model.telemetry).font(.caption.monospaced())
                        Text(model.detectionDiagnostic).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: model.diagnosticText) { Label("Partager le journal", systemImage: "square.and.arrow.up") }
                        Button("Capturer l’image analysée") { Task { await model.captureDiagnosticFrame() } }
                            .disabled(model.isRecordingMatch || model.isCapturing || !model.camera.isRunning)
                        if let snapshot = model.diagnosticSnapshot {
                            ShareLink(items: [snapshot.imageURL, snapshot.reportURL]) { Text("Partager la capture") }
                        }
                        ForEach(model.logs.suffix(12).reversed()) { entry in
                            Text(entry.message).font(.caption2).textSelection(.enabled)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PL.ground)
            .navigationTitle("Réglages avancés")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }
        .tint(PL.neon)
        .preferredColorScheme(.dark)
    }

    private var angleLimitsSummary: String {
        func degrees(_ value: Double?) -> String { value.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "—" }
        let current = model.standPosition.map { String(format: "Osmo : lacet %.1f° · inclinaison %.1f°", $0.yaw * 180 / .pi, $0.pitch * 180 / .pi) }
            ?? "Position de l’Osmo inconnue (télémétrie en attente)"
        var text = "Gauche \(degrees(model.leftYawLimit)) · droite \(degrees(model.rightYawLimit)) · basse \(degrees(model.lowPitchLimit))\n\(current)"
        if (model.leftYawLimit == nil) != (model.rightYawLimit == nil) { text += "\nDéfinis les deux limites latérales pour activer la limite de lacet." }
        return text
    }

    private func direction(_ symbol: String, _ value: DockKitModel.Direction) -> some View {
        Button { model.move(value) } label: { Image(systemName: symbol).frame(minWidth: 44, minHeight: 44) }
            .disabled(!model.canMove)
    }
}

@MainActor
struct RecordingLibrary: View {
    let recordings: [MatchRecording]
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var saving = false
    /// Saved during this visit; older saves are read from each recording's marker file.
    @State private var savedNow: Set<String> = []
    var body: some View {
        NavigationStack {
            List {
                if !message.isEmpty { Text(message).font(.caption) }
                if recordings.isEmpty {
                    ContentUnavailableView("Aucune vidéo", systemImage: "film", description: Text("Touche Filmer pour enregistrer un match."))
                }
                ForEach(recordings) { recording in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            RecordedMatchPlayer(url: recording.videoURL)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                                if let label = recording.sessionLabel { Text(label).plLabel(11, tracking: 0.1) }
                                Text(String(format: "%d min %02d s · %@", Int(recording.durationSeconds) / 60, Int(recording.durationSeconds) % 60,
                                            recording.hasAudio ? "avec son" : "sans son")).font(.caption)
                            }
                        }
                        if recording.interrupted { Text("Enregistrement interrompu ; fichiers conservés.").font(.caption).foregroundStyle(.orange) }
                        // Borderless: in a List row, plain buttons all fire when the row is tapped,
                        // so opening a video used to add it to Photos again each time.
                        HStack {
                            ShareLink(items: recording.shareURLs) { Label("Vidéo + logs", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                            Spacer()
                            if savedNow.contains(recording.id) || recording.isSavedToPhotos {
                                Label("Dans Photos", systemImage: "checkmark").foregroundStyle(.secondary)
                            } else {
                                Button("Photos", systemImage: "photo") {
                                    saving = true
                                    Task {
                                        do {
                                            try await recording.saveToPhotos()
                                            savedNow.insert(recording.id)
                                            message = "Vidéo ajoutée aux Photos."
                                        } catch { message = error.localizedDescription }
                                        saving = false
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(saving)
                            }
                        }.font(.caption)
                    }.padding(.vertical, 6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PL.ground)
            .navigationTitle("Matchs enregistrés")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }
        .tint(PL.neon)
        .preferredColorScheme(.dark)
    }
}

@MainActor
private struct RecordedMatchPlayer: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
            .navigationTitle("Vidéo du match").navigationBarTitleDisplayMode(.inline)
    }
}

// Observes the model at analysis rate: only the preview and its small diagnostic line live here.
// The video extends under safe areas; the text uses SwiftUI's safe area.
@MainActor
struct LivePreviewLayer: View {
    @ObservedObject var model: DockKitModel
    /// Distance from the top safe edge, below the HUD's top rows.
    var diagnosticTop: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(session: model.camera.session, ballBox: model.ballBox,
                ballConfidence: model.ballConfidence, proposalBoxes: model.proposalBoxes,
                selectionLocation: model.selectionLocation, onSelectBall: model.handlePreviewTap,
                trail: model.ballTrail, anticipatedTarget: model.anticipatedTarget,
                showTrail: model.showBallTrail, imageSize: model.camera.imageSize,
                following: model.isFollowing, onRotation: model.camera.setPreviewRotation,
                onInterfaceOrientation: { _ in }, ballConfirmed: model.ballDrivesCamera, hybrid: model.useHybrid ? model.hybridDecision : nil,
                scoredProposals: model.scoredProposals, showDetections: model.showDetectionBoxes,
                showSkeletons: model.showSkeletons, showOrientations: model.showBodyOrientations,
                showDecision: model.showDecisionTarget, zoomFactor: model.camera.zoomFactor,
                onZoom: model.zoomCamera, pitchLines: model.pitchLines)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "×%.1f", model.camera.zoomFactor * (model.camera.isUltraWide ? 0.5 : 1))).plLabel(11, tracking: 0.1)
                if model.showDecisionTarget {
                    Text(visualDiagnostic).font(.caption2.monospacedDigit()).lineLimit(2)
                }
            }
            .foregroundStyle(PL.paper)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(PL.ground.opacity(0.55))
            .padding(.top, diagnosticTop).padding(.horizontal, 20)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var visualDiagnostic: String {
        if model.camera.isZooming { return "Zoom manuel · suivi moteur en pause" }
        guard model.detectorReady else { return model.ballMessage }
        if model.detectionPerformance == "Analyses interrompues" { return model.detectionPerformance }
        guard model.useHybrid, let decision = model.hybridDecision else { return model.detectionSummary }
        let ball = decision.selectedBall.map { String(format:" · score %.0f %%",$0.confidence*100) } ?? ""
        return String(format:"%@%@ · continuité %.0f %% · poids ballon %.0f %%",
            decision.mode,ball,decision.reliability*100,decision.ballWeight*100)
    }
}
