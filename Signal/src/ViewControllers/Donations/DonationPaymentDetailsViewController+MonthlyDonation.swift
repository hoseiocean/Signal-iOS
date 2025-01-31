//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalMessaging

extension DonationPaymentDetailsViewController {
    /// Make a monthly donation.
    ///
    /// See also: code for other payment methods, such as Apple Pay.
    func monthlyDonation(
        with validForm: FormState.ValidForm,
        newSubscriptionLevel: SubscriptionLevel,
        priorSubscriptionLevel: SubscriptionLevel?,
        subscriberID existingSubscriberId: Data?
    ) {
        let currencyCode = self.donationAmount.currencyCode

        Logger.info("[Donations] Starting monthly card donation")

        DonationViewsUtil.wrapPromiseInProgressView(
            from: self,
            promise: firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<Void> in
                if let existingSubscriberId {
                    Logger.info("[Donations] Cancelling existing subscription")

                    return SubscriptionManagerImpl.cancelSubscription(for: existingSubscriberId)
                } else {
                    Logger.info("[Donations] No existing subscription to cancel")

                    return Promise.value(())
                }
            }.then(on: DispatchQueue.sharedUserInitiated) { () -> Promise<Data> in
                Logger.info("[Donations] Preparing new monthly subscription with card")

                return SubscriptionManagerImpl.prepareNewSubscription(currencyCode: currencyCode)
            }.then(on: DispatchQueue.sharedUserInitiated) { subscriberId -> Promise<(Data, SubscriptionManagerImpl.RecurringSubscriptionPaymentType)> in
                firstly { () -> Promise<String> in
                    Logger.info("[Donations] Creating Signal payment method for new monthly subscription with card")

                    return Stripe.createSignalPaymentMethodForSubscription(subscriberId: subscriberId)
                }.then(on: DispatchQueue.sharedUserInitiated) { clientSecret -> Promise<SubscriptionManagerImpl.RecurringSubscriptionPaymentType> in
                    Logger.info("[Donations] Authorizing payment for new monthly subscription with card")

                    return Stripe.setupNewSubscription(
                        clientSecret: clientSecret,
                        paymentMethod: validForm.stripePaymentMethod
                    ).then(on: DispatchQueue.sharedUserInitiated) { confirmedIntent in
                        if let redirectToUrl = confirmedIntent.redirectToUrl {
                            return self.show3DS(for: redirectToUrl)
                                .map(on: DispatchQueue.sharedUserInitiated) { _ in
                                    return confirmedIntent
                                }
                        } else {
                            return Promise.value(confirmedIntent)
                        }
                    }.map { confirmedIntent in
                        switch validForm {
                        case .card:
                            return .creditOrDebitCard(paymentMethodId: confirmedIntent.paymentMethodId)
                        case .sepa:
                            return .sepa(paymentMethodId: confirmedIntent.paymentMethodId)
                        case .ideal:
                            return .ideal(setupIntentId: confirmedIntent.setupIntentId)
                        }
                    }
                }.map(on: DispatchQueue.sharedUserInitiated) { paymentType -> (Data, SubscriptionManagerImpl.RecurringSubscriptionPaymentType) in
                    (subscriberId, paymentType)
                }
            }.then(on: DispatchQueue.sharedUserInitiated) { (subscriberId, paymentType) in
                return DonationViewsUtil.finalizeAndRedeemSubscription(
                    subscriberId: subscriberId,
                    paymentType: paymentType,
                    newSubscriptionLevel: newSubscriptionLevel,
                    priorSubscriptionLevel: priorSubscriptionLevel,
                    currencyCode: currencyCode
                )
            }
        ).done(on: DispatchQueue.main) { [weak self] in
            Logger.info("[Donations] Monthly card donation finished")
            self?.onFinished(nil)
        }.catch(on: DispatchQueue.main) { [weak self] error in
            Logger.info("[Donations] Monthly card donation failed")
            self?.onFinished(error)
        }
    }
}
