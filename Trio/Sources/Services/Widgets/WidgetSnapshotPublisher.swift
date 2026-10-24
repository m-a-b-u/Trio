import Combine
import CoreData
import Foundation
import Swinject
import WidgetKit

/// Publishes a local display snapshot independently of Live Activities and the AI bridge.
final class WidgetSnapshotPublisher: Injectable, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!

    private let queue = DispatchQueue(label: "Trio.WidgetSnapshotPublisher")
    private var subscriptions = Set<AnyCancellable>()
    private let store = TrioStatusSnapshotStore.configured()
    private var lastSnapshot: TrioStatusSnapshot?

    init(resolver: Resolver) {
        injectServices(resolver)
        broadcaster.register(SettingsObserver.self, observer: self)
        CoreDataStack.shared.entityChangePublisher
            .debounce(for: .seconds(1), scheduler: queue)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &subscriptions)
        queue.async { [weak self] in self?.publish() }
    }

    func settingsDidChange(_: TrioSettings) {
        queue.async { [weak self] in self?.publish() }
    }

    private func publish() {
        guard let store else { return }
        let unit: TrioStatusUnit = settingsManager.settings.units == .mgdL ? .mgdL : .mmolL
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "WidgetSnapshotPublisher"
        do {
            let snapshot = try context.performAndWait {
                let glucoseRequest = GlucoseStored.fetchRequest() as NSFetchRequest<GlucoseStored>
                glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                glucoseRequest.fetchLimit = 1
                let glucose = try context.fetch(glucoseRequest).first
                let determinationRequest = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
                determinationRequest.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
                determinationRequest.fetchLimit = 1
                let determination = try context.fetch(determinationRequest).first
                // Never stamp old measurements with the time this display file was written.
                let glucoseDate = glucose?.date
                let determinationDate = determination?.deliverAt
                return try TrioStatusSnapshot(
                    glucoseMgdl: glucoseDate == nil ? nil : glucose.map { Double($0.glucose) },
                    glucoseDate: glucoseDate,
                    unit: unit,
                    trend: glucoseDate == nil ? nil : glucose?.directionEnum.flatMap { TrioStatusTrend(rawValue: $0.rawValue) },
                    iob: determinationDate == nil ? nil : determination?.iob?.doubleValue,
                    cob: determinationDate == nil ? nil : determination.map { Double($0.cob) },
                    determinationDate: determinationDate
                )
            }
            guard snapshot != lastSnapshot else { return }
            try store.save(snapshot)
            lastSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: TrioStatusSnapshotStore.widgetKind)
        } catch {
            // A failed refresh must not leave a previous configuration looking current.
            lastSnapshot = nil
            try? store.remove()
            WidgetCenter.shared.reloadTimelines(ofKind: TrioStatusSnapshotStore.widgetKind)
            warning(.default, "Could not refresh the local status widget.")
        }
    }
}
