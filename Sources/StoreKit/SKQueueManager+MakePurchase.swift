//
//  SKQueueManager+MakePurchase.swift
//  Adapty
//
//  Created by Aleksei Valiano on 25.10.2022
//

import StoreKit

extension SKQueueManager {
    func makePurchase<T: AdaptyProduct>(payment: SKPayment, product: T, _ completion: @escaping AdaptyResultCompletion<AdaptyPurchasedInfo>) {
        queue.async { [weak self] in
            let productId = payment.productIdentifier
            guard let self = self else { return }

            if let productVariationId = (product as? AdaptyPaywallProduct)?.variationId {
                self.setVariationId(productVariationId, for: productId)
            }

            self.makePurchasesProduct[productId] = product

            if let handlers = self.makePurchasesCompletionHandlers[productId] {
                self.makePurchasesCompletionHandlers[productId] = handlers + [completion]
                return
            }

            self.makePurchasesCompletionHandlers[productId] = [completion]
            SKPaymentQueue.default().add(payment)
            Adapty.logSystemEvent(AdaptyAppleRequestParameters(methodName: "add_payment", params: [
                "product_id": .value(payment.productIdentifier),
            ]))
        }
    }

    func receivedFailedTransaction(_ transaction: SKPaymentTransaction) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if !Adapty.Configuration.observerMode {
                SKPaymentQueue.default().finishTransaction(transaction)
                Adapty.logSystemEvent(AdaptyAppleRequestParameters(methodName: "finish_transaction", params: transaction.logParams))
                Log.verbose("SKQueueManager: finish failed transaction \(transaction)")
            }

            let productId = transaction.payment.productIdentifier

            self.removeVariationId(for: productId)
            self.makePurchasesProduct.removeValue(forKey: productId)

            let error = SKManagerError.productPurchaseFailed(transaction.error).asAdaptyError

            self.callMakePurchasesCompletionHandlers(productId, .failure(error))
        }
    }

    func receivedPurchasedTransaction(_ transaction: SKPaymentTransaction) {
        func fetchPurchaseProductInfo(manager: SKQueueManager,
                                      _ productId: String,
                                      variationId: String?,
                                      persistentVariationId: String?,
                                      _ transaction: SKPaymentTransaction,
                                      _ completion: @escaping ((PurchaseProductInfo) -> Void)) {
            if let product = manager.makePurchasesProduct[productId] {
                completion(PurchaseProductInfo(product, variationId, persistentVariationId, transaction))
                return
            }

            manager.skProductsManager.fetchSK1Product(productIdentifier: productId, fetchPolicy: .returnCacheDataElseLoad) { result in
                switch result {
                case let .failure(error):
                    Log.error("SKQueueManager: fetch product \(productId) error: \(error)")
                    completion(PurchaseProductInfo(nil, variationId, persistentVariationId, transaction))
                    return
                case let .success(skProduct):
                    guard let skProduct = skProduct else {
                        Log.error("SKQueueManager: unknown product \(productId)")
                        completion(PurchaseProductInfo(nil, variationId, persistentVariationId, transaction))
                        return
                    }
                    completion(PurchaseProductInfo(skProduct, variationId, persistentVariationId, transaction))
                    return
                }
            }
        }

        queue.async { [weak self] in

            guard let self = self else { return }
            let productId = transaction.payment.productIdentifier
            fetchPurchaseProductInfo(manager: self,
                                     productId,
                                     variationId: self.variationsIds[productId],
                                     persistentVariationId: self.persistentVariationsIds[productId],
                                     transaction) { [weak self] purchaseProductInfo in
                self?.purchaseValidator.validatePurchase(info: purchaseProductInfo) { result in
                    guard let self = self else { return }
                    if result.error == nil {
                        self.removeVariationId(for: productId)
                        self.makePurchasesProduct.removeValue(forKey: productId)

                        if !Adapty.Configuration.observerMode {
                            SKPaymentQueue.default().finishTransaction(transaction)
                            Adapty.logSystemEvent(AdaptyAppleRequestParameters(methodName: "finish_transaction", params: transaction.logParams))
                            Log.info("SKQueueManager: finish purchased transaction \(transaction)")
                        }
                    }
                    self.callMakePurchasesCompletionHandlers(productId, result.map {
                        AdaptyPurchasedInfo(profile: $0.value, transaction: transaction)})
                }
            }
        }
    }

    func callMakePurchasesCompletionHandlers(_ productId: String,
                                             _ result: AdaptyResult<AdaptyPurchasedInfo>) {
        queue.async { [weak self] in
            guard let self = self else { return }

            switch result {
            case let .failure(error):
                Log.error("Failed to purchase product: \(productId) \(error.localizedDescription)")
            case .success:
                Log.info("Successfully purchased product: \(productId).")
            }

            guard let handlers = self.makePurchasesCompletionHandlers.removeValue(forKey: productId) else {
                Log.error("Not found makePurchasesCompletionHandlers for \(productId)")
                return
            }

            for completion in handlers { completion(result) }
        }
    }
}
