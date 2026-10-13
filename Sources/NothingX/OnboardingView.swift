import SwiftUI

/// Content of the main window: the dashboard, with the first-run tour painted over it while it is presented.
struct OnboardingRoot: View {
    private let controller = OnboardingController.shared

    var body: some View {
        ZStack {
            ContentView()
                .disabled(controller.isPresented)
                .accessibilityHidden(controller.isPresented)
            if controller.isPresented {
                OnboardingView().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: controller.isPresented)
    }
}

/// The first-run tour, inside the 900×700 main window. It holds the pure `OnboardingFlow` and is the only
/// glue between it and the model and services: link state in, `startLink()` and the outcome out.
struct OnboardingView: View {
    @Environment(HeadphoneModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let service = NotificationService.shared

    @State private var flow = OnboardingFlow(bluetooth: Self.seed(BluetoothGate.current))
    /// The pending 0.8 s pause before an automatic `.next`; cancelled on step change and disappearance.
    @State private var beat: Task<Void, Never>?
    /// The notification permission request in flight.
    @State private var notificationRequest: Task<Void, Never>?
    @State private var requestingNotifications = false

    /// The permission as known before the link runs. A preflight: it never prompts and never blocks.
    private static func seed(_ gate: BluetoothGate) -> OnboardingFlow.Bluetooth {
        switch gate {
        case .pending: .notAsked
        case .denied: .denied
        case .allowed: .allowed
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, 32)
                .padding(.top, 34)       // sits below the traffic-light buttons
                .frame(height: 64, alignment: .top)
            VStack(alignment: .leading, spacing: 28) {
                hero.frame(height: 120, alignment: .bottomLeading)
                ZStack(alignment: .topLeading) {
                    stepContent
                        .id(flow.step)
                        .transition(stepTransition)
                }
                .animation(.easeOut(duration: 0.3), value: flow.step)
            }
            .frame(width: 560, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 20)
            .padding(.horizontal, 32)
            bottomRow
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
        .frame(width: 900, height: 700)
        .background(NTColor.background)
        .contentShape(Rectangle())          // nothing reaches the dashboard underneath
        .foregroundStyle(NTColor.primary)
        .onChange(of: model.connection, initial: true) { forwardConnection() }
        .onChange(of: model.linkStarted) { forwardConnection() }
        .onChange(of: flow.linkShouldRun, initial: true) {
            if flow.linkShouldRun { model.startLink() }
        }
        .onChange(of: flow.autoAdvances, initial: true) {
            if flow.autoAdvances { scheduleNext(from: .bluetooth) } else { cancelBeat() }
        }
        .onChange(of: flow.step) {
            cancelBeat()
            if flow.autoAdvances { scheduleNext(from: .bluetooth) }
        }
        .onChange(of: flow.outcome) {
            guard let outcome = flow.outcome else { return }
            model.startLink()
            OnboardingController.shared.finish(outcome)
        }
        .onDisappear {
            cancelBeat()
            notificationRequest?.cancel()
            notificationRequest = nil
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Text("Nothing X").ntLabel()
            Spacer()
            Button { flow.handle(.skip) } label: {
                Text("[Skip]").ntLabel(NTColor.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Skip the welcome tour"))
        }
    }

    // MARK: Hero

    @ViewBuilder private var hero: some View {
        if flow.step == .welcome {
            DotXMark()
        } else if flow.step == .connect, model.connection == .connected {
            if let level = model.battery {
                DotMatrixText(text: "\(level)%", dot: 8)
            } else {
                DotMatrixText(text: "--", dot: 8, color: NTColor.disabled)
            }
        } else {
            DotMatrixText(text: String(format: "%02d", flow.step.rawValue + 1), dot: 8, color: NTColor.disabled)
        }
    }

    // MARK: Step content

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .welcome: WelcomeStep()
        case .bluetooth: BluetoothStep(state: flow.bluetooth)
        case .connect: ConnectStep()
        case .notifications: NotificationsStep()
        case .macAnchor: MacAnchorStep()
        case .done: DoneStep()
        }
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(alignment: .center, spacing: 24) {
            OnboardingProgress(step: flow.step, completed: flow.completedSteps)
            Spacer(minLength: 0)
            actions.fixedSize()
        }
    }

    /// At most one `.defaultAction` button at a time: the step's primary action, when it has one.
    @ViewBuilder private var actions: some View {
        HStack(spacing: 24) {
            switch flow.step {
            case .welcome:
                primary("[Continue]") { next(from: .welcome) }
            case .bluetooth:
                switch flow.bluetooth {
                case .notAsked:
                    primary("[Allow Bluetooth]") { flow.handle(.allowBluetooth) }
                case .denied:
                    secondary("[Open Bluetooth settings]") { BluetoothGate.openSettings() }
                case .waiting, .allowed:
                    EmptyView()
                }
            case .connect:
                if model.connection == .connected {
                    primary("[Continue]") { next(from: .connect) }
                } else {
                    secondary("[Pair in System Settings]") { OnboardingLinks.openBluetoothPairing() }
                    primary("[Later]", color: NTColor.secondary) { next(from: .connect) }
                }
            case .notifications:
                notificationActions
            case .macAnchor:
                primary("[Got it]") { next(from: .macAnchor) }
            case .done:
                primary("[Start]") { next(from: .done) }
            }
        }
    }

    @ViewBuilder private var notificationActions: some View {
        switch service.authorization {
        case .notDetermined:
            secondary("[Not now]") { next(from: .notifications) }
            primary("[Allow notifications]") { requestNotifications() }
                .disabled(requestingNotifications)
                .opacity(requestingNotifications ? 0.4 : 1)
        case .denied:
            secondary("[Open System Settings]") { service.openSystemSettings() }
            primary("[Continue]") { next(from: .notifications) }
        case .allowed, .unsupported:
            primary("[Continue]") { next(from: .notifications) }
        }
    }

    private func primary(_ title: LocalizedStringKey, color: Color = NTColor.primary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).ntLabel(color) }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).ntLabel(NTColor.secondary) }
            .buttonStyle(.plain)
    }

    // MARK: Glue

    /// `.next`, only if the flow is still on `step`: a late timer or a double press never skips a step.
    private func next(from step: OnboardingStep) {
        guard flow.step == step else { return }
        flow.handle(.next)
    }

    /// Link state → flow, only once the link runs: before that `connection` is just its `.searching` default
    /// and says nothing about the permission.
    private func forwardConnection() {
        guard model.linkStarted else { return }
        let state: OnboardingFlow.Bluetooth
        switch model.connection {
        case .permissionPending: state = .waiting
        case .permissionDenied: state = .denied
        case .searching, .connecting, .connected: state = .allowed
        }
        if state != flow.bluetooth { flow.handle(.bluetoothChanged(state)) }
    }

    /// Moves on from `step` after a short beat that lets the "allowed" line be read.
    private func scheduleNext(from step: OnboardingStep) {
        beat?.cancel()
        beat = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            if step == .bluetooth, !flow.autoAdvances { return }
            next(from: step)
        }
    }

    private func cancelBeat() {
        beat?.cancel()
        beat = nil
    }

    private func requestNotifications() {
        guard !requestingNotifications else { return }
        requestingNotifications = true
        notificationRequest = Task {
            let ok = await service.requestAuthorization()
            requestingNotifications = false
            guard !Task.isCancelled, ok else { return }      // refused: the denied state renders
            scheduleNext(from: .notifications)
        }
    }
}
