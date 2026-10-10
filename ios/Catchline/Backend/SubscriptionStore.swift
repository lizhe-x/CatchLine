import Foundation
import Observation
import StoreKit

/// StoreKit 2: products, purchases, and the current entitlement.
///
/// The app never decides access on its own — it forwards the signed
/// transaction (JWS) to the server, which verifies it against Apple's root
/// certificate and applies the quota. Local state here only drives the UI.
@Observable
final class SubscriptionStore {
    private(set) var products: [Product] = []
    private(set) var activeTransaction: Transaction?
    private(set) var activeJWS: String?
    /// Whether this Apple ID can still get the monthly plan's free trial.
    private(set) var trialEligible = false
    /// A product request has completed (successfully or not).
    private(set) var productsLoaded = false
    private(set) var loadError: String?

    private var updatesTask: Task<Void, Never>?

    var monthly: Product? { products.first { $0.id == AppConfig.monthlyProductID } }
    var yearly: Product? { products.first { $0.id == AppConfig.yearlyProductID } }
    var isSubscribed: Bool { activeTransaction != nil }

    init() {
        // Renewals, refunds, Ask to Buy, purchases on other devices.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case let .verified(transaction) = update { await transaction.finish() }
                await self?.refreshEntitlement()
            }
        }
    }

    func load() async {
        do {
            products = try await Product.products(for: AppConfig.productIDs)
                .sorted { $0.price > $1.price }
            loadError = nil
            print("[store] loaded \(products.count) products")
        } catch {
            loadError = error.localizedDescription
            print("[store] products failed:", error)
        }
        productsLoaded = true
        if let monthly { trialEligible = await monthly.subscription?.isEligibleForIntroOffer ?? false }
        await refreshEntitlement()
    }

    enum PurchaseOutcome { case purchased, pending, cancelled, failed(String) }

    /// Purchase options: tie the transaction to our anonymous user id.
    var purchaseOptions: Set<Product.PurchaseOption> { [.appAccountToken(UserIdentity.current)] }

    /// Processes the result of SwiftUI's `PurchaseAction` (which presents the
    /// confirmation sheet on the right window scene).
    func handle(_ result: Product.PurchaseResult) async -> PurchaseOutcome {
        switch result {
        case let .success(.verified(transaction)):
            print("[store] purchased \(transaction.productID) offer=\(String(describing: transaction.offer?.type))")
            await transaction.finish()
            await refreshEntitlement()
            return .purchased
        case let .success(.unverified(_, error)):
            print("[store] unverified purchase:", error)
            return .failed(error.localizedDescription)
        case .pending:
            print("[store] purchase pending (Ask to Buy / SCA)")
            return .pending
        case .userCancelled:
            print("[store] purchase cancelled")
            return .cancelled
        @unknown default:
            return .failed("unknown")
        }
    }

    /// Returns true if an active subscription was found.
    func restore() async throws -> Bool {
        try await AppStore.sync()
        await refreshEntitlement()
        print("[store] restore finished, subscribed=\(isSubscribed)")
        return isSubscribed
    }

    func refreshEntitlement() async {
        var best: (Transaction, String)?
        for await entitlement in Transaction.currentEntitlements {
            guard case let .verified(transaction) = entitlement,
                  AppConfig.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil
            else { continue }
            // Prefer the plan that expires last (e.g. yearly after an upgrade).
            if best == nil || (transaction.expirationDate ?? .distantPast) > (best!.0.expirationDate ?? .distantPast) {
                best = (transaction, entitlement.jwsRepresentation)
            }
        }
        activeTransaction = best?.0
        activeJWS = best?.1
        if let monthly { trialEligible = await monthly.subscription?.isEligibleForIntroOffer ?? false }
    }
}
