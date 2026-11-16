import Foundation
import Observation
import os

/// A run of questions that `QuestionSequence` asks one alert at a time.
protocol SequencedQuestions {
    associatedtype Question: Equatable
    /// How many questions have an answer: the one to ask next is at this step.
    var step: Int { get }
    /// Every question has an answer.
    var isAnswered: Bool { get }
    /// The question at `step`.
    var question: Question { get }
}

/// Asks a run of questions one alert at a time, as Extract's conflict questions on iOS
/// (`ScreenState`), and hands over from each answered question to the next. The next question is
/// published only once the answered one's alert has gone (`alertDidGo`, which the view calls when
/// the alert's condition goes false) and `settle` has passed: published while UIKit is still
/// taking the old alert down, SwiftUI drops the new presentation and, its condition staying true,
/// never retries it (iPad, "no question 4 of 4"). Should the alert's going never be reported,
/// `fallback` after the answer goes on without it. Every hand-off names the run and the step it
/// was scheduled for, so one that comes late, for a step already taken or a run that has ended,
/// does nothing. Everything runs on the main actor.
@MainActor @Observable
final class QuestionSequence<Run: SequencedQuestions> {
    /// One step of one run: what a hand-off is for.
    struct Token: Hashable, Sendable {
        let run: UUID
        let step: Int
    }

    /// The hand-off scheduled now: for which step, and what it waits for.
    struct Waiting: Equatable, Sendable {
        enum Wait: Equatable, Sendable {
            /// The alert's going (`alertDidGo`), or, without it, `fallback` (if any).
            case alert
            /// `settle`, after the alert has gone.
            case settle
        }

        let token: Token
        let wait: Wait
    }

    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    /// The run being asked; nil when none.
    private(set) var run: Run?
    /// The question its alert shows; nil between an answer and the next question.
    private(set) var question: Run.Question?

    /// How long the next question waits once the answered one's alert has gone. Most tests set it to zero.
    @ObservationIgnored var settle: Duration
    /// How long after an answer the hand-off goes on without `alertDidGo`; nil: never.
    @ObservationIgnored var fallback: Duration?
    /// The hand-off scheduled now, if any.
    @ObservationIgnored private(set) var waiting: Waiting?
    /// The task running the last hand-off scheduled: its wait, then the next question or `finish`.
    /// Let go of once `finish` starts, so no later hand-off can cancel the operation. Tests read it
    /// right after scheduling and await its value.
    @ObservationIgnored private(set) var next: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var finish: (@MainActor (Run) async -> Void)?
    /// How the waits sleep: `Task.sleep`. Tests put in one they drive.
    @ObservationIgnored var sleep: Sleep
    @ObservationIgnored private let logger: Logger

    init(settle: Duration, fallback: Duration?, logger: Logger,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.settle = settle
        self.fallback = fallback
        self.logger = logger
        self.sleep = sleep
    }

    /// Where the run stands: what a hand-off scheduled now is for. nil when no run is asked.
    var token: Token? {
        run.map { Token(run: runID, step: $0.step) }
    }

    /// Starts asking `run`'s questions; `finish` gets the run once every question has an answer.
    /// Nothing while another run is asked, or for a run without a question to ask.
    @discardableResult
    func start(_ run: Run, finish: @escaping @MainActor (Run) async -> Void) -> Bool {
        guard self.run == nil, !run.isAnswered else { return false }
        runID = UUID()
        self.run = run
        self.finish = finish
        question = run.question
        logger.info("publish \(self.short, privacy: .public) step \(run.step): first question")
        return true
    }

    /// An answer to the question at `step`: `record` writes it into the run and moves `step` past
    /// every question it answers. The question goes at once; the next comes after `alertDidGo`
    /// and `settle`, or `fallback` after now without it. An answer to any other question than the
    /// one asked, or one that answers nothing, does nothing.
    @discardableResult
    func answer(at step: Int, _ record: (inout Run) -> Void) -> Bool {
        guard var run, question != nil, run.step == step else {
            logger.info("answer at step \(step) dropped: not the question asked")
            return false
        }
        record(&run)
        guard run.step > step else { return false }
        self.run = run
        question = nil
        logger.info("answer \(self.short, privacy: .public) step \(step) -> \(run.step)")
        schedule(.alert, for: Token(run: runID, step: run.step))
        return true
    }

    /// The alert has gone: its condition went false. After an answer, the next question once
    /// `settle` has passed, or after the last answer `finish`. Nothing while a question is still
    /// asked (something else took the screen; its alert comes back), or when the hand-off for this
    /// step already waits for `settle` (a duplicate signal).
    func alertDidGo() {
        guard question == nil else {
            logger.info("didGo \(self.short, privacy: .public) ignored: the question is still asked")
            return
        }
        guard let token else {
            logger.info("didGo ignored: no run")
            return
        }
        guard waiting != Waiting(token: token, wait: .settle) else {
            logger.info("didGo \(self.short, privacy: .public) step \(token.step) ignored: already settling")
            return
        }
        logger.info("didGo \(self.short, privacy: .public) step \(token.step): settling")
        schedule(.settle, for: token)
    }

    /// Ends the run: a hand-off still waiting is cancelled, and nothing more is asked or finished.
    /// A `finish` already under way runs on: that is the operation's own (its progress sheet).
    func cancel() {
        if waiting != nil {
            next?.cancel()
            logger.info("cancel \(self.short, privacy: .public): hand-off cancelled")
        }
        waiting = nil
        run = nil
        question = nil
        finish = nil
    }

    /// The hand-off `token` names: the run's next question, or, every question answered, the end of
    /// the run and `finish`. Nothing when the run has moved past that step or ended, or a question
    /// is asked. Internal for tests; the scheduled task calls it.
    func handOff(to token: Token) async {
        guard question == nil, let run, self.token == token else {
            logger.info("hand-off for step \(token.step) dropped: stale")
            return
        }
        waiting = nil
        guard run.isAnswered else {
            question = run.question
            logger.info("publish \(self.short, privacy: .public) step \(run.step)")
            return
        }
        self.run = nil
        let finish = finish
        self.finish = nil
        // From here the task is the operation's: a later run's hand-off must not cancel it.
        next = nil
        logger.info("finish \(self.short, privacy: .public) after step \(run.step)")
        await finish?(run)
    }

    /// Schedules the hand-off for `token` after `wait`, in place of the one scheduled before.
    private func schedule(_ wait: Waiting.Wait, for token: Token) {
        next?.cancel()
        waiting = Waiting(token: token, wait: wait)
        guard let delay = wait == .settle ? settle : fallback else {
            next = nil
            return
        }
        next = Task { [weak self, sleep] in
            if delay > .zero { try? await sleep(delay) }
            guard !Task.isCancelled else { return }
            await self?.handOff(to: token)
        }
    }

    /// The run's id, short, for the log.
    private var short: String { String(runID.uuidString.prefix(8)) }
}
