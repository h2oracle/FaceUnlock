import Foundation

/// The guided-setup steps, in order.
public enum SetupStep: Int, CaseIterable, Comparable, Sendable {
    case camera, accessibility, password, enrol, test, turnOn, lockTest

    public static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    /// Steps 1–6 must be done for face unlock to work; the lock-screen test
    /// (7) is a final check.
    public var isRequired: Bool { self != .lockTest }
}

/// What the app currently knows about one step.
public enum StepCondition: Equatable, Sendable {
    case done
    case notDone
    /// Needs attention (e.g. permission denied, template tampered with).
    case problem
}

/// How a step is shown: its icon (satisfied / problem / pending) and
/// whether its controls are usable. A step is only enabled once every step
/// before it is satisfied.
public struct StepState: Equatable, Sendable {
    public var condition: StepCondition
    public var isEnabled: Bool

    public var isSatisfied: Bool { condition == .done }
}

public struct SetupProgress: Equatable, Sendable {
    public let conditions: [SetupStep: StepCondition]

    /// Missing entries count as `.notDone`.
    public init(conditions: [SetupStep: StepCondition]) {
        self.conditions = conditions
    }

    public func condition(of step: SetupStep) -> StepCondition {
        conditions[step] ?? .notDone
    }

    public func state(of step: SetupStep) -> StepState {
        let earlierDone = SetupStep.allCases.filter { $0 < step }.allSatisfy { condition(of: $0) == .done }
        return StepState(condition: condition(of: step), isEnabled: earlierDone)
    }

    /// First step that isn't done (nil when everything is).
    public var currentStep: SetupStep? {
        SetupStep.allCases.first { condition(of: $0) != .done }
    }

    /// Steps 1–6 done: face unlock can work.
    public var requiredComplete: Bool {
        SetupStep.allCases.filter(\.isRequired).allSatisfy { condition(of: $0) == .done }
    }

    /// Everything done, including a successful lock-screen test.
    public var allComplete: Bool {
        SetupStep.allCases.allSatisfy { condition(of: $0) == .done }
    }
}
