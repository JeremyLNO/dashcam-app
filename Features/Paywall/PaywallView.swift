import StoreKit
import SwiftUI

/// The subscription screen.
///
/// Every price on it comes from StoreKit. Nothing about money is written in this file —
/// not a number, not a currency, not a discount percentage that could go stale the day
/// pricing changes in App Store Connect.
struct PaywallView: View {
    enum Context {
        case general
        /// Reached by tapping Export during the free trial.
        case export

        var subtitleKey: String {
            switch self {
            case .general: return "paywall.subtitle"
            case .export: return "paywall.subtitle.export"
            }
        }
    }

    let context: Context

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selectedPlanID: String?
    @State private var isPurchasing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if subscriptions.plans.isEmpty {
                        loadingOrError
                    } else {
                        plans
                        trialNote
                        purchaseButton
                    }
                    legalLinks
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(key: "common.close") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await subscriptions.restore() }
                    } label: {
                        Text(key: "paywall.restore")
                    }
                    .accessibilityIdentifier("restoreButton")
                }
            }
            .task {
                if subscriptions.plans.isEmpty { await subscriptions.loadProducts() }
                selectedPlanID = selectedPlanID ?? subscriptions.plans.last?.id
            }
            .onChange(of: subscriptions.state.canExport) { _, canExport in
                if canExport { dismiss() }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(key: "paywall.title")
                .font(Theme.title)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(key: context.subtitleKey)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var plans: some View {
        VStack(spacing: 10) {
            ForEach(subscriptions.plans) { plan in
                PlanRow(
                    plan: plan,
                    isSelected: selectedPlanID == plan.id,
                    isBest: plan.period == .yearly
                )
                .onTapGesture { selectedPlanID = plan.id }
            }
        }
    }

    @ViewBuilder
    private var trialNote: some View {
        if subscriptions.isEligibleForIntroductoryOffer,
           let plan = selectedPlan,
           let offer = plan.introductoryOffer,
           offer.paymentMode == .freeTrial {
            VStack(spacing: 4) {
                Text(verbatim: L10n.t("paywall.trial", offer.localizedPeriodDescription))
                    .font(Theme.headline)
                    .foregroundStyle(Theme.positive)
                Text(verbatim: L10n.t("paywall.then_price", plan.displayPrice))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                // Stated up front, because it is the one rule people would otherwise be
                // surprised by after signing up.
                Text(key: "paywall.trial.export_note")
                    .font(Theme.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .dashcamCard()
        }
    }

    private var purchaseButton: some View {
        VStack(spacing: 10) {
            Button {
                Task { await purchase() }
            } label: {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(key: subscriptions.isEligibleForIntroductoryOffer ? "paywall.cta.trial" : "paywall.cta")
                }
            }
            .buttonStyle(DriverButtonStyle(fill: Theme.accent))
            .disabled(isPurchasing || selectedPlan == nil)
            .accessibilityIdentifier("subscribeButton")

            if let message {
                Text(verbatim: message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var loadingOrError: some View {
        VStack(spacing: 10) {
            if subscriptions.isLoadingProducts {
                ProgressView().tint(Theme.textSecondary)
            } else {
                Text(key: "paywall.unavailable")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await subscriptions.loadProducts() }
                } label: {
                    Text(key: "common.retry")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var legalLinks: some View {
        VStack(spacing: 12) {
            Button {
                if let url = environment.configuration.manageSubscriptionsURL { openURL(url) }
            } label: {
                Text(key: "paywall.manage")
            }
            HStack(spacing: 18) {
                Button {
                    if let url = environment.configuration.termsURL { openURL(url) }
                } label: {
                    Text(key: "paywall.terms")
                }
                Button {
                    if let url = environment.configuration.privacyURL { openURL(url) }
                } label: {
                    Text(key: "paywall.privacy")
                }
            }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 6)
    }

    // MARK: -

    private var selectedPlan: SubscriptionPlan? {
        subscriptions.plans.first { $0.id == selectedPlanID } ?? subscriptions.plans.last
    }

    private func purchase() async {
        guard let plan = selectedPlan else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        switch await subscriptions.purchase(plan) {
        case .purchased:
            message = nil
            dismiss()
        case .pending:
            // Ask to Buy, or a bank confirmation. Not an error, just not done yet.
            message = L10n.t("paywall.pending")
        case .cancelled:
            message = nil
        case .failed(let detail):
            message = detail
        }
    }
}

/// One selectable plan. The yearly row carries the "best value" flag as required.
private struct PlanRow: View {
    let plan: SubscriptionPlan
    let isSelected: Bool
    let isBest: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(key: plan.period.titleKey)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if isBest {
                        Text(key: "paywall.best_value")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.positive.opacity(0.2)))
                            .foregroundStyle(Theme.positive)
                    }
                }
                Text(verbatim: plan.product.description)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(verbatim: plan.displayPrice)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("plan-\(plan.period.rawValue)")
    }
}
