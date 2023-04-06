//
//  SKQueueManager.swift
//  Adapty
//
//  Created by Aleksei Valiano on 25.10.2022
//

import StoreKit

protocol VariationIdStorage {
    func getVariationsIds() -> [String: String]
    func setVariationsIds(_: [String: String])
}

extension Adapty {
    /// Call this method to have StoreKit present a sheet enabling the user to redeem codes provided by your app.
    public static func presentCodeRedemptionSheet() {
        let logName = "present_code_redemption_sheet"
        #if swift(>=5.3) && os(iOS) && !targetEnvironment(macCatalyst)
            async(nil, logName: logName) { _, completion in
                if #available(iOS 14.0, *) {
                    SKPaymentQueue.default().presentCodeRedemptionSheet()
                } else {
                    Log.error("Presenting code redemption sheet is available only for iOS 14 and higher.")
                }
                completion(nil)
            }
        #else
            let stamp = Log.stamp
            Adapty.logSystemEvent(AdaptySDKMethodRequestParameters(methodName: logName, callId: stamp))
            Adapty.logSystemEvent(AdaptySDKMethodResponseParameters(methodName: logName, callId: stamp, error: "not available"))
        #endif
    }
}

final class SKQueueManager: NSObject {
    let queue: DispatchQueue

    var purchaseValidator: PurchaseValidator!

    var makePurchasesCompletionHandlers = [String: [AdaptyResultCompletion<AdaptyProfile>]]()
    var makePurchasesProduct = [String: AdaptyProduct]()

    var storage: VariationIdStorage
    var skProductsManager: SKProductsManager

    var variationsIds: [String: String] {
        didSet {
            storage.setVariationsIds(variationsIds)
        }
    }

    init(queue: DispatchQueue, storage: VariationIdStorage, skProductsManager: SKProductsManager) {
        self.queue = queue
        self.storage = storage
        variationsIds = storage.getVariationsIds()
        self.skProductsManager = skProductsManager
        super.init()
    }

    static func canMakePayments() -> Bool {
        SKPaymentQueue.canMakePayments()
    }

    func startObserving(purchaseValidator: PurchaseValidator) {
        self.purchaseValidator = purchaseValidator
        SKPaymentQueue.default().add(self)

        NotificationCenter.default.addObserver(forName: Application.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            if let self = self { SKPaymentQueue.default().remove(self) }
        }
    }
}

extension SKQueueManager: SKPaymentTransactionObserver {
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        transactions.forEach { transaction in
            switch transaction.transactionState {
            case .purchased:
                receivedPurchasedTransaction(transaction)

            case .failed:
                receivedFailedTransaction(transaction)

            case .restored:
                if !Adapty.Configuration.observerMode {
                    SKPaymentQueue.default().finishTransaction(transaction)
                    Log.verbose("SKQueueManager: finish restored transaction \(transaction)")
                }
            case .deferred, .purchasing: break
            @unknown default: break
            }
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
        func paymentQueue(_ queue: SKPaymentQueue, shouldAddStorePayment payment: SKPayment, for product: SKProduct) -> Bool {
            guard let delegate = Adapty.delegate else { return true }

            let deferredProduct = AdaptyDeferredProduct(skProduct: product, payment: payment)
            return delegate.shouldAddStorePayment(for: deferredProduct, defermentCompletion: { [weak self] completion in
                self?.makePurchase(payment: payment, product: deferredProduct) { result in
                    completion?(result)
                }
            })
        }
    #endif

    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        Log.verbose("SKQueueManager: Restore сompleted transactions finished.")
    }

    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        Log.error("SKQueueManager: Restore сompleted transactions failed with error: \(error)")
    }

    func paymentQueue(_ queue: SKPaymentQueue, didRevokeEntitlementsForProductIdentifiers productIdentifiers: [String]) {
        // TODO: validate receipt
    }
}
