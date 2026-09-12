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
                VStack(spacing: 18) {
                    header
                    benefits
                    if subscriptions.plans.isEmpty {
                        loadingOrError
                    } else {
                        plans
                        trialNote
                        purchaseButton
                    }
                    legalLinks
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 26)
            }
            .scrollIndicators(.hidden)
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
            Text(key: "paywall.title")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            Text(key: context.subtitleKey)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            PaywallIllustration()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// What the subscription is for, in three words each. Recording is free and says so
    /// elsewhere; these are the three things the money buys.
    private var benefits: some View {
        HStack(spacing: 10) {
            benefit(titleKey: "paywall.benefit.record", systemImage: "video.fill", accent: .coral)
            benefit(titleKey: "paywall.benefit.protect", systemImage: "checkmark.shield.fill", accent: .blue)
            benefit(titleKey: "paywall.benefit.export", systemImage: "square.and.arrow.up.fill", accent: .teal)
        }
    }

    private func benefit(titleKey: String, systemImage: String, accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(systemImage: systemImage, accent: accent, size: 40)
            Text(key: titleKey)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(accent, padding: 14)
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
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: "gift.fill", accent: .blue, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: L10n.t("paywall.trial", offer.localizedPeriodDescription))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: L10n.t("paywall.then_price", plan.displayPrice))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    // Stated up front, because it is the one rule people would otherwise
                    // be surprised by after signing up.
                    Text(key: "paywall.trial.export_note")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .pastelCard(.blue, padding: 14)
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
            .buttonStyle(PrimaryButtonStyle(fill: Theme.coral, height: 72))
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

/// One selectable plan. The yearly row carries the "best value" flag as required, and
/// the selected row is outlined in coral — the only outline in the app, because this is
/// the one place where a choice has to be visible from across the screen.
private struct PlanRow: View {
    let plan: SubscriptionPlan
    let isSelected: Bool
    let isBest: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(isSelected ? Theme.coral : Theme.separator, lineWidth: 2)
                    .frame(width: 26, height: 26)
                if isSelected {
                    Circle().fill(Theme.coral).frame(width: 14, height: 14)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(key: plan.period.titleKey)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if isBest {
                        Text(key: "paywall.best_value")
                            .font(.system(size: 11, weight: .heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.coral))
                            .foregroundStyle(.white)
                    }
                }
                Text(verbatim: plan.product.description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(verbatim: plan.displayPrice)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? Theme.coralSoft : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? Theme.coral : Color.clear, lineWidth: 2)
        )
        .softShadow()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("plan-\(plan.period.rawValue)")
    }
}

/// A phone in a windscreen cradle, filming. Shapes only — nothing to re-export.
struct PaywallIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.orangeSoft)
                .frame(width: 210, height: 150)
                .blur(radius: 0.5)

            VStack(spacing: 0) {
                // The cradle arm.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hex: 0x2C3440))
                    .frame(width: 74, height: 18)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(hex: 0x2C3440))
                    .frame(width: 14, height: 10)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Theme.blue.opacity(0.8), Theme.orange.opacity(0.9)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 200, height: 108)
                    .overlay(alignment: .bottom) {
                        Trapezoid().fill(Color(hex: 0x3A3F4B)).frame(height: 52)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.coral).frame(width: 7, height: 7)
                            Text(key: "rec.on")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(hex: 0x08264A).opacity(0.7)))
                        .padding(8)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(hex: 0x2C3440), lineWidth: 5)
                    )
                    .softShadow()
            }
        }
        .frame(height: 170)
        .accessibilityHidden(true)
    }
}
