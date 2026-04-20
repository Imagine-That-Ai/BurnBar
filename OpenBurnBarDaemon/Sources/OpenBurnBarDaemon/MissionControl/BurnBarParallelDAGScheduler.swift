import OpenBurnBarCore
import Foundation

/// Errors that can occur during parallel DAG scheduling.
public enum BurnBarParallelSchedulerError: Error, LocalizedError {
    case dagIsEmpty
    case dagValidationFailed(String)
    case circularDependencyDetected
    case nodeNotFound(BurnBarDAGNodeID)
    case nodeAlreadyRunning(BurnBarDAGNodeID)
    case nodeNotReady(BurnBarDAGNodeID)
    case schedulerAlreadyRunning(BurnBarMissionID)
    case schedulerNotRunning(BurnBarMissionID)

    public var errorDescription: String? {
        switch self {
        case .dagIsEmpty:
            return "Cannot schedule an empty DAG."
        case .dagValidationFailed(let reason):
            return "DAG validation failed: \(reason)"
        case .circularDependencyDetected:
            return "Circular dependency detected in DAG."
        case .nodeNotFound(let nodeID):
            return "Node not found: \(nodeID.rawValue)"
        case .nodeAlreadyRunning(let nodeID):
            return "Node is already running: \(nodeID.rawValue)"
        case .nodeNotReady(let nodeID):
            return "Node is not ready to start (dependencies not satisfied): \(nodeID.rawValue)"
        case .schedulerAlreadyRunning(let missionID):
            return "Scheduler already running for mission: \(missionID.rawValue)"
        case .schedulerNotRunning(let missionID):
            return "Scheduler not running for mission: \(missionID.rawValue)"
        }
    }
}

/// Callback interface for the parallel DAG scheduler to dispatch node execution.
public protocol BurnBarDAGSchedulerDispatch: Sendable {
    /// Called when a node should start execution.
    func schedulerDidScheduleNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        prompt: String,
        metadata: [String: BurnBarJSONValue]
    ) async

    /// Called when a node completes successfully.
    func schedulerDidCompleteNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        result: String
    ) async

    /// Called when a node fails.
    func schedulerDidFailNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        error: String
    ) async
}

// MARK: - VAL-EXEC-010: Reconciler Winner Selection

/// Metrics for a node outcome used in winner selection.
/// Higher scores indicate better outcomes for reconciliation.
public struct BurnBarDAGNodeOutcomeMetrics: Sendable {
    /// Evidence completeness score (0.0 - 1.0): tests passed, artifacts produced, required outputs satisfied.
    public let evidenceCompleteness: Double
    /// Risk residual score (0.0 - 1.0): lower is better.
    public let riskResidual: Double
    /// Normalized cost penalty (0.0 - 1.0): lower is better.
    public let costPenalty: Double
    /// Normalized latency penalty (0.0 - 1.0): lower is better.
    public let latencyPenalty: Double
    /// Sequence number for ordering (lower is earlier).
    public let sequenceNumber: Int
    /// Whether the outcome was successful.
    public let isSuccessful: Bool

    public init(
        evidenceCompleteness: Double = 0.5,
        riskResidual: Double = 0.5,
        costPenalty: Double = 0.5,
        latencyPenalty: Double = 0.5,
        sequenceNumber: Int = 0,
        isSuccessful: Bool = true
    ) {
        self.evidenceCompleteness = evidenceCompleteness
        self.riskResidual = riskResidual
        self.costPenalty = costPenalty
        self.latencyPenalty = latencyPenalty
        self.sequenceNumber = sequenceNumber
        self.isSuccessful = isSuccessful
    }
}

/// Protocol for providing node outcome metrics during winner selection.
/// Implement this to customize how the reconciler scores outcomes.
public protocol BurnBarDAGReconcilerMetricsProvider: Sendable {
    /// Returns outcome metrics for a node. Return nil if metrics are unavailable.
    func metrics(for nodeID: BurnBarDAGNodeID) -> BurnBarDAGNodeOutcomeMetrics?
}

/// Actor that manages parallel DAG execution with dependency gating and critical path tracking.
///
/// The scheduler enforces that:
/// - DAG nodes never start before their dependencies succeed
/// - Independent ready nodes may execute concurrently (up to maxConcurrency)
/// - Critical path is computed and updated as execution progresses
/// - VAL-EXEC-010: When multiple parallel paths complete, winner selection is deterministic and replay-stable
public actor BurnBarParallelDAGScheduler {
    /// Default maximum concurrent node execution.
    public static let defaultMaxConcurrency = 4

    /// Tracks all active schedulers by mission ID.
    private static var activeSchedulers: [BurnBarMissionID: BurnBarParallelDAGScheduler] = [:]

    /// The mission this scheduler is managing.
    public let missionID: BurnBarMissionID

    /// The DAG being executed.
    private let dag: BurnBarDAGContract

    /// Callback for dispatching node execution.
    private let dispatch: any BurnBarDAGSchedulerDispatch

    /// VAL-EXEC-010: Provider for node outcome metrics used in winner selection.
    private let metricsProvider: (any BurnBarDAGReconcilerMetricsProvider)?

    /// Maximum concurrent node execution.
    private let maxConcurrency: Int

    /// Logger for debugging.
    private let logger: BurnBarDaemonLogger

    /// Current scheduler state.
    private var state: BurnBarDAGSchedulerState

    /// Node metadata (title, detail) keyed by node ID.
    private let nodeMetadata: [BurnBarDAGNodeID: (title: String, detail: String)]

    /// Pending node completions keyed by node ID.
    private var pendingCompletions: [BurnBarDAGNodeID: Bool] = [:]

    /// Creates a new parallel DAG scheduler for a mission.
    public init(
        missionID: BurnBarMissionID,
        dag: BurnBarDAGContract,
        dispatch: any BurnBarDAGSchedulerDispatch,
        metricsProvider: (any BurnBarDAGReconcilerMetricsProvider)? = nil,
        maxConcurrency: Int = BurnBarParallelDAGScheduler.defaultMaxConcurrency,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "parallel-dag-scheduler")
    ) {
        self.missionID = missionID
        self.dag = dag
        self.dispatch = dispatch
        self.metricsProvider = metricsProvider
        self.maxConcurrency = maxConcurrency
        self.logger = logger

        // Build node metadata map
        var metadata: [BurnBarDAGNodeID: (title: String, detail: String)] = [:]
        for node in dag.nodes {
            metadata[node.id] = (title: node.title, detail: node.detail)
        }
        self.nodeMetadata = metadata

        // Initialize state
        var initialStatuses: [String: BurnBarDAGNodeStatus] = [:]
        for node in dag.nodes {
            initialStatuses[node.id.rawValue] = node.status
        }

        // Calculate initial critical path from DAG structure
        let initialCriticalPath = Self.computeInitialCriticalPath(
            dag: dag,
            missionID: missionID
        )

        self.state = BurnBarDAGSchedulerState(
            missionID: missionID,
            phase: .idle,
            nodeStatuses: initialStatuses,
            runningNodes: [],
            readyNodes: dag.nodes.filter { $0.dependsOn.isEmpty }.map { $0.id },
            completedNodes: [],
            failedNodes: [],
            criticalPath: initialCriticalPath,
            maxConcurrency: maxConcurrency,
            updatedAt: Date()
        )
    }

    /// Returns the current scheduler state.
    public func currentState() -> BurnBarDAGSchedulerState {
        state
    }

    /// Starts the scheduler and begins executing ready nodes.
    public func start() async throws {
        guard state.phase == .idle else {
            if state.phase == .running {
                throw BurnBarParallelSchedulerError.schedulerAlreadyRunning(missionID)
            }
            return
        }

        // Validate the DAG
        do {
            try dag.validate()
        } catch {
            throw BurnBarParallelSchedulerError.dagValidationFailed(error.localizedDescription)
        }

        guard !dag.nodes.isEmpty else {
            throw BurnBarParallelSchedulerError.dagIsEmpty
        }

        state.phase = .running
        state.updatedAt = Date()

        // Start as many ready nodes as allowed by concurrency
        await dispatchReadyNodes()
    }

    /// Reports that a node has completed successfully.
    public func reportNodeCompleted(_ nodeID: BurnBarDAGNodeID) async {
        await handleNodeCompletion(nodeID, success: true)
    }

    /// Reports that a node has failed.
    public func reportNodeFailed(_ nodeID: BurnBarDAGNodeID) async {
        await handleNodeCompletion(nodeID, success: false)
    }

    /// Manually marks a node as completed (for external completion tracking).
    public func markNodeCompleted(_ nodeID: BurnBarDAGNodeID, success: Bool) async {
        await handleNodeCompletion(nodeID, success: success)
    }

    /// Pauses the scheduler.
    public func pause() {
        guard state.phase == .running else { return }
        state.phase = .paused
        state.updatedAt = Date()
    }

    /// Resumes the scheduler.
    public func resume() async {
        guard state.phase == .paused else { return }
        state.phase = .running
        state.updatedAt = Date()
        await dispatchReadyNodes()
    }

    /// Cancels the scheduler and all running nodes.
    public func cancel() {
        state.phase = .failed
        state.errorMessage = "Cancelled by user"
        state.updatedAt = Date()
    }

    // MARK: - Private Methods

    /// Handles node completion and updates the scheduler state.
    private func handleNodeCompletion(_ nodeID: BurnBarDAGNodeID, success: Bool) async {
        guard var nodeStatus = state.nodeStatuses[nodeID.rawValue] else {
            logger.warning("completion_for_unknown_node", metadata: ["nodeID": nodeID.rawValue])
            return
        }

        // Reject completion/failure for nodes that are not currently running.
        // This prevents out-of-order state advancement that could corrupt
        // dependency satisfaction tracking.
        guard nodeStatus == .running else {
            logger.warning("completion_rejected_for_non_running_node", metadata: [
                "nodeID": nodeID.rawValue,
                "currentStatus": String(describing: nodeStatus)
            ])
            return
        }

        // Update node status
        nodeStatus = success ? .completed : .failed
        state.nodeStatuses[nodeID.rawValue] = nodeStatus

        // Update running/completed/failed node lists
        state.runningNodes.removeAll { $0 == nodeID }
        if success {
            state.completedNodes.append(nodeID)
        } else {
            state.failedNodes.append(nodeID)
        }

        // Update critical path
        await updateCriticalPath(nodeID: nodeID, success: success)

        // Check if DAG is complete
        let allTerminal = dag.nodes.allSatisfy { node in
            guard let status = state.nodeStatuses[node.id.rawValue] else { return false }
            return status == .completed || status == .failed
        }

        if allTerminal {
            state.phase = state.failedNodes.isEmpty ? .completed : .failed
            state.errorMessage = state.failedNodes.isEmpty ? nil : "Some nodes failed"
            // VAL-EXEC-010: Perform winner selection when all nodes complete
            await performWinnerSelection()
        } else if state.phase == .running {
            // Dispatch newly ready nodes
            await dispatchReadyNodes()
        }

        state.updatedAt = Date()
    }

    /// Dispatches as many ready nodes as allowed by concurrency.
    private func dispatchReadyNodes() async {
        while state.canStartMoreNodes {
            guard let nextNode = findNextReadyNode() else { break }
            await startNode(nextNode)
        }
    }

    /// Finds the next ready node that has all dependencies satisfied.
    private func findNextReadyNode() -> BurnBarDAGNodeID? {
        // First, filter to nodes that are pending (not yet started)
        let pendingNodes = dag.nodes.filter { node in
            guard let status = state.nodeStatuses[node.id.rawValue],
                  status == .pending || status == .ready else {
                return false
            }
            return true
        }

        // Among pending nodes, find those with all dependencies completed
        for node in pendingNodes {
            let depsSatisfied = node.dependsOn.allSatisfy { depID in
                guard let status = state.nodeStatuses[depID.rawValue] else { return false }
                return status == .completed
            }

            if depsSatisfied {
                return node.id
            }
        }

        return nil
    }

    // MARK: - VAL-EXEC-010: Reconciler Winner Selection

    /// Performs winner selection when the DAG completes with multiple terminal outcomes.
    /// Uses deterministic, replay-stable selection based on the winner selection precedence.
    private func performWinnerSelection() async {
        // Find terminal nodes that can be candidates for winner selection
        let terminalNodes = dag.nodes.filter { node in
            guard let status = state.nodeStatuses[node.id.rawValue] else { return false }
            return status == .completed || status == .failed
        }

        // If only one candidate or no conflict, no reconciliation needed
        if terminalNodes.count <= 1 {
            if let singleNode = terminalNodes.first {
                state.reconciliationArtifact = BurnBarDAGReconciliationArtifact(
                    missionID: missionID,
                    winnerNodeID: singleNode.id,
                    candidateNodeIDs: [singleNode.id],
                    winnerReasonCode: .noReconciliationNeeded,
                    winnerRationale: "Single terminal node - no reconciliation needed",
                    winnerScore: 1.0,
                    candidateScores: [singleNode.id.rawValue: 1.0],
                    reconciledAt: Date()
                )
            }
            return
        }

        // Score all candidates using the metrics provider or defaults
        var candidateScores: [BurnBarDAGNodeID: (score: Double, metrics: BurnBarDAGNodeOutcomeMetrics)] = [:]

        for node in terminalNodes {
            let metrics: BurnBarDAGNodeOutcomeMetrics
            if let provider = metricsProvider, let provided = provider.metrics(for: node.id) {
                metrics = provided
            } else {
                // Use default metrics based on success/failure
                metrics = BurnBarDAGNodeOutcomeMetrics(
                    evidenceCompleteness: 0.5,
                    riskResidual: state.nodeStatuses[node.id.rawValue] == .completed ? 0.3 : 0.7,
                    costPenalty: 0.5,
                    latencyPenalty: 0.5,
                    sequenceNumber: terminalNodes.firstIndex(where: { $0.id == node.id }) ?? 0,
                    isSuccessful: state.nodeStatuses[node.id.rawValue] == .completed
                )
            }

            // Calculate composite score using winner selection precedence:
            // 1. Policy-valid and dependency-complete candidates (all terminal nodes satisfy this)
            // 2. Successful terminal outcomes over failed outcomes (+2.0 for success)
            // 3. Higher evidence completeness (0-1 scale, multiplier 1.0)
            // 4. Lower risk residual (invert: 1 - riskResidual, multiplier 1.0)
            // 5. Lower normalized cost/latency penalty (invert both, multiplier 0.5 each)
            // 6. Earliest terminal sequence number (invert: 1 / (1 + sequenceNumber))
            // 7. Lexical tie-break: handled by stable sort
            let successBonus = metrics.isSuccessful ? 2.0 : 0.0
            let evidenceScore = metrics.evidenceCompleteness * 1.0
            let riskScore = (1.0 - metrics.riskResidual) * 1.0
            let costScore = (1.0 - metrics.costPenalty) * 0.5
            let latencyScore = (1.0 - metrics.latencyPenalty) * 0.5
            let sequenceScore = 1.0 / Double(1 + metrics.sequenceNumber)

            let compositeScore = successBonus + evidenceScore + riskScore + costScore + latencyScore + sequenceScore

            candidateScores[node.id] = (compositeScore, metrics)
        }

        // Sort candidates by score (descending), then by lexical ID (ascending) for tie-breaking
        let sortedCandidates = terminalNodes.sorted { nodeA, nodeB in
            let scoreA = candidateScores[nodeA.id]?.score ?? 0
            let scoreB = candidateScores[nodeB.id]?.score ?? 0
            if scoreA != scoreB {
                return scoreA > scoreB  // Higher score wins
            }
            return nodeA.id.rawValue < nodeB.id.rawValue  // Lexical tie-break
        }

        guard let winner = sortedCandidates.first else { return }

        // Determine the winner reason code based on what made the difference
        let winnerScore = candidateScores[winner.id]?.score ?? 0
        let winnerMetrics = candidateScores[winner.id]?.metrics

        var winnerReasonCode: BurnBarReconcilerWinnerReasonCode = .noReconciliationNeeded
        var rationale = "Winner selected by deterministic reconciliation"

        if terminalNodes.count == 1 {
            winnerReasonCode = .onlyCandidate
            rationale = "Only candidate node - winner is the only terminal outcome"
        } else if let wMetrics = winnerMetrics {
            // Check if winner won due to success over failure
            let hasFailedCandidates = sortedCandidates.dropFirst().contains { node in
                guard let m = candidateScores[node.id]?.metrics else { return false }
                return !m.isSuccessful
            }
            if wMetrics.isSuccessful && hasFailedCandidates {
                winnerReasonCode = .successOverFailure
                rationale = "Winner succeeded while other candidates failed"
            }
            // Check if winner won due to higher evidence completeness
            else if wMetrics.evidenceCompleteness > 0.5 {
                winnerReasonCode = .higherEvidenceCompleteness
                rationale = String(format: "Winner had higher evidence completeness (%.2f)", wMetrics.evidenceCompleteness)
            }
            // Check if winner won due to lower risk
            else if wMetrics.riskResidual < 0.5 {
                winnerReasonCode = .lowerRiskResidual
                rationale = String(format: "Winner had lower risk residual (%.2f)", wMetrics.riskResidual)
            }
            // Check if winner won due to lower cost/latency
            else if wMetrics.costPenalty < 0.5 || wMetrics.latencyPenalty < 0.5 {
                winnerReasonCode = .lowerCostLatencyPenalty
                rationale = String(format: "Winner had lower cost/latency (cost=%.2f, latency=%.2f)",
                                   wMetrics.costPenalty, wMetrics.latencyPenalty)
            }
            // Check if winner won due to earliest sequence
            else if wMetrics.sequenceNumber == 0 {
                winnerReasonCode = .earliestSequenceNumber
                rationale = "Winner had earliest terminal sequence number"
            }
            else {
                winnerReasonCode = .lexicalTieBreak
                rationale = "Winner selected by lexical tie-break on candidate ID"
            }
        }

        // Build candidate scores map for the artifact
        var artifactCandidateScores: [String: Double] = [:]
        for node in terminalNodes {
            artifactCandidateScores[node.id.rawValue] = candidateScores[node.id]?.score ?? 0
        }

        state.reconciliationArtifact = BurnBarDAGReconciliationArtifact(
            missionID: missionID,
            winnerNodeID: winner.id,
            candidateNodeIDs: terminalNodes.map { $0.id },
            winnerReasonCode: winnerReasonCode,
            winnerRationale: rationale,
            winnerScore: winnerScore,
            candidateScores: artifactCandidateScores,
            reconciledAt: Date()
        )

        logger.info("winner_selected", metadata: [
            "winnerNodeID": winner.id.rawValue,
            "reasonCode": winnerReasonCode.rawValue,
            "winnerScore": String(winnerScore),
            "candidateCount": String(terminalNodes.count)
        ])
    }

    /// Starts a node by dispatching it.
    private func startNode(_ nodeID: BurnBarDAGNodeID) async {
        guard let node = dag.nodes.first(where: { $0.id == nodeID }) else { return }

        // Update state
        state.nodeStatuses[nodeID.rawValue] = .running
        state.runningNodes.append(nodeID)
        state.readyNodes.removeAll { $0 == nodeID }
        state.updatedAt = Date()

        // Update critical path timing
        updateNodeTiming(nodeID, startedAt: Date())

        // Dispatch to callback
        let metadata: [String: BurnBarJSONValue] = [
            "node_title": .string(node.title),
            "node_detail": .string(node.detail),
            "depends_on": .array(node.dependsOn.map { .string($0.rawValue) })
        ]

        await dispatch.schedulerDidScheduleNode(
            nodeID,
            missionID: missionID,
            prompt: buildNodePrompt(node),
            metadata: metadata
        )
    }

    /// Builds the execution prompt for a node.
    private func buildNodePrompt(_ node: BurnBarDAGNode) -> String {
        """
        Execute DAG node: \(node.title)

        \(node.detail)

        Dependencies: \(node.dependsOn.isEmpty ? "None" : node.dependsOn.map { $0.rawValue }.joined(separator: ", "))
        """
    }

    /// Updates the critical path based on current execution state.
    private func updateCriticalPath(nodeID: BurnBarDAGNodeID, success: Bool) async {
        var criticalPath = state.criticalPath ?? BurnBarCriticalPathArtifact(missionID: missionID)

        // Update node timing
        var updatedTimings = criticalPath.nodeTimings

        if let existingTiming = updatedTimings[nodeID.rawValue] {
            let updatedTiming = BurnBarDAGNodeTiming(
                nodeID: nodeID,
                scheduledAt: existingTiming.scheduledAt,
                startedAt: existingTiming.startedAt,
                completedAt: Date(),
                estimatedDuration: existingTiming.estimatedDuration,
                actualDuration: existingTiming.durationIfCompleted ?? existingTiming.actualDuration
            )
            updatedTimings[nodeID.rawValue] = updatedTiming
        }

        // Recompute critical path
        let newCriticalPathNodes = Self.computeCurrentCriticalPath(
            dag: dag,
            state: state,
            missionID: missionID
        )

        // Calculate estimated remaining duration
        let estimatedRemaining = Self.estimateRemainingDuration(
            dag: dag,
            state: state,
            criticalPathNodes: newCriticalPathNodes
        )

        let allComplete = dag.nodes.allSatisfy { node in
            guard let status = state.nodeStatuses[node.id.rawValue] else { return false }
            return status == .completed || status == .failed
        }

        let updatedCriticalPath = BurnBarCriticalPathArtifact(
            missionID: missionID,
            dagSchemaVersion: dag.schemaVersion,
            criticalPathNodes: criticalPath.criticalPathNodes,
            estimatedTotalDuration: criticalPath.estimatedTotalDuration,
            currentCriticalPathNodes: newCriticalPathNodes,
            estimatedRemainingDuration: estimatedRemaining,
            nodeTimings: updatedTimings,
            updatedAt: Date(),
            isComplete: allComplete
        )

        state.criticalPath = updatedCriticalPath
    }

    /// Updates the timing for a node when it starts.
    private func updateNodeTiming(_ nodeID: BurnBarDAGNodeID, startedAt: Date) {
        var criticalPath = state.criticalPath ?? BurnBarCriticalPathArtifact(missionID: missionID)
        var updatedTimings = criticalPath.nodeTimings

        let existingTiming = updatedTimings[nodeID.rawValue]
        let updatedTiming = BurnBarDAGNodeTiming(
            nodeID: nodeID,
            scheduledAt: existingTiming?.scheduledAt ?? Date(),
            startedAt: startedAt,
            completedAt: nil,
            estimatedDuration: nil,
            actualDuration: nil
        )
        updatedTimings[nodeID.rawValue] = updatedTiming

        let updatedCriticalPath = BurnBarCriticalPathArtifact(
            missionID: missionID,
            dagSchemaVersion: dag.schemaVersion,
            criticalPathNodes: criticalPath.criticalPathNodes,
            estimatedTotalDuration: criticalPath.estimatedTotalDuration,
            currentCriticalPathNodes: criticalPath.currentCriticalPathNodes,
            estimatedRemainingDuration: criticalPath.estimatedRemainingDuration,
            nodeTimings: updatedTimings,
            updatedAt: Date(),
            isComplete: false
        )

        state.criticalPath = updatedCriticalPath
    }

    // MARK: - Critical Path Computation

    /// Computes the initial critical path from DAG structure.
    private static func computeInitialCriticalPath(
        dag: BurnBarDAGContract,
        missionID: BurnBarMissionID
    ) -> BurnBarCriticalPathArtifact {
        // Get topologically sorted nodes
        guard let topoOrder = dag.topologicalSort() else {
            return BurnBarCriticalPathArtifact(missionID: missionID)
        }

        // Build adjacency list and in-degree map
        var inDegree: [BurnBarDAGNodeID: Int] = [:]
        var adjacency: [BurnBarDAGNodeID: [BurnBarDAGNodeID]] = [:]

        for node in dag.nodes {
            inDegree[node.id] = node.dependsOn.count
            adjacency[node.id] = []
        }

        for node in dag.nodes {
            for depID in node.dependsOn {
                adjacency[depID, default: []].append(node.id)
            }
        }

        // Find the longest path using dynamic programming
        // dist[nodeID] = longest path ending at nodeID
        var dist: [BurnBarDAGNodeID: TimeInterval] = [:]
        var predecessor: [BurnBarDAGNodeID: BurnBarDAGNodeID?] = [:]
        var pathNodes: [BurnBarDAGNodeID: [BurnBarDAGNodeID]] = [:]

        for nodeID in topoOrder.map(\.id) {
            dist[nodeID] = 0
            predecessor[nodeID] = nil
            pathNodes[nodeID] = [nodeID]
        }

        // Process in topological order
        for nodeID in topoOrder.map(\.id) {
            guard let neighbors = adjacency[nodeID] else { continue }
            for neighbor in neighbors {
                // Assume each node takes ~1 unit of time for initial estimate
                let newDist = dist[nodeID]! + 1.0
                if newDist > dist[neighbor]! {
                    dist[neighbor] = newDist
                    predecessor[neighbor] = nodeID
                    pathNodes[neighbor] = pathNodes[nodeID]! + [neighbor]
                }
            }
        }

        // Find node with maximum distance (end of critical path)
        guard let (endNode, maxDist) = dist.max(by: { $0.value < $1.value }),
              let path = pathNodes[endNode] else {
            return BurnBarCriticalPathArtifact(missionID: missionID)
        }

        // Build node timings for initial path
        var nodeTimings: [String: BurnBarDAGNodeTiming] = [:]
        for nodeID in path {
            nodeTimings[nodeID.rawValue] = BurnBarDAGNodeTiming(
                nodeID: nodeID,
                estimatedDuration: 1.0
            )
        }

        return BurnBarCriticalPathArtifact(
            missionID: missionID,
            dagSchemaVersion: dag.schemaVersion,
            criticalPathNodes: path,
            estimatedTotalDuration: maxDist,
            currentCriticalPathNodes: path,
            estimatedRemainingDuration: maxDist,
            nodeTimings: nodeTimings,
            updatedAt: Date(),
            isComplete: false
        )
    }

    /// Computes the current critical path based on execution state.
    private static func computeCurrentCriticalPath(
        dag: BurnBarDAGContract,
        state: BurnBarDAGSchedulerState,
        missionID: BurnBarMissionID
    ) -> [BurnBarDAGNodeID] {
        // Build completion map
        let completedSet = Set(state.completedNodes)

        // Build adjacency and in-degree
        var inDegree: [BurnBarDAGNodeID: Int] = [:]
        var adjacency: [BurnBarDAGNodeID: [BurnBarDAGNodeID]] = [:]

        for node in dag.nodes {
            // Only count non-completed dependencies
            let activeDeps = node.dependsOn.filter { !completedSet.contains($0) }
            inDegree[node.id] = activeDeps.count
            adjacency[node.id] = []
        }

        for node in dag.nodes {
            for depID in node.dependsOn where !completedSet.contains(depID) {
                adjacency[depID, default: []].append(node.id)
            }
        }

        // Find longest path among remaining nodes
        var dist: [BurnBarDAGNodeID: TimeInterval] = [:]
        var predecessor: [BurnBarDAGNodeID: BurnBarDAGNodeID?] = [:]
        var pathNodes: [BurnBarDAGNodeID: [BurnBarDAGNodeID]] = [:]

        for node in dag.nodes where !completedSet.contains(node.id) {
            dist[node.id] = 0
            predecessor[node.id] = nil
            pathNodes[node.id] = [node.id]
        }

        // Kahn's algorithm to get topological order of remaining nodes
        var queue: [BurnBarDAGNodeID] = []
        for (nodeID, degree) in inDegree where degree == 0 && !completedSet.contains(nodeID) {
            queue.append(nodeID)
        }

        var topoOrder: [BurnBarDAGNodeID] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            topoOrder.append(current)

            for neighbor in adjacency[current] ?? [] {
                if !completedSet.contains(neighbor) {
                    inDegree[neighbor]! -= 1
                    if inDegree[neighbor] == 0 {
                        queue.append(neighbor)
                    }
                }
            }
        }

        // Process in topological order
        for nodeID in topoOrder {
            guard let neighbors = adjacency[nodeID] else { continue }
            for neighbor in neighbors where !completedSet.contains(neighbor) {
                // Use actual duration if available, else estimate
                let nodeDuration: TimeInterval
                if let timing = state.criticalPath?.nodeTimings[neighbor.rawValue],
                   let actual = timing.actualDuration {
                    nodeDuration = actual
                } else if let timing = state.criticalPath?.nodeTimings[neighbor.rawValue],
                          let estimated = timing.estimatedDuration {
                    nodeDuration = estimated
                } else {
                    nodeDuration = 1.0
                }

                let newDist = dist[nodeID]! + nodeDuration
                if newDist > dist[neighbor]! {
                    dist[neighbor] = newDist
                    predecessor[neighbor] = nodeID
                    pathNodes[neighbor] = pathNodes[nodeID]! + [neighbor]
                }
            }
        }

        // Find max distance
        guard let (endNode, _) = dist.max(by: { $0.value < $1.value }),
              let path = pathNodes[endNode] else {
            return state.criticalPath?.currentCriticalPathNodes ?? []
        }

        return path
    }

    /// Estimates remaining duration based on current state and critical path.
    private static func estimateRemainingDuration(
        dag: BurnBarDAGContract,
        state: BurnBarDAGSchedulerState,
        criticalPathNodes: [BurnBarDAGNodeID]
    ) -> TimeInterval {
        var remaining: TimeInterval = 0

        for nodeID in criticalPathNodes {
            guard let status = state.nodeStatuses[nodeID.rawValue] else { continue }

            if status == .pending || status == .ready {
                // Node not started - add estimated duration
                if let timing = state.criticalPath?.nodeTimings[nodeID.rawValue],
                   let estimated = timing.estimatedDuration {
                    remaining += estimated
                } else {
                    remaining += 1.0 // Default estimate
                }
            } else if status == .running {
                // Node is running - add remaining estimated time
                if let timing = state.criticalPath?.nodeTimings[nodeID.rawValue],
                   let started = timing.startedAt {
                    let elapsed = Date().timeIntervalSince(started)
                    let estimated = timing.estimatedDuration ?? 1.0
                    remaining += max(0, estimated - elapsed)
                } else {
                    remaining += 1.0
                }
            }
            // Completed nodes contribute 0 remaining time
        }

        return remaining
    }
}

// MARK: - Convenience Factory

extension BurnBarParallelDAGScheduler {
    /// Creates and registers a scheduler for a mission.
    public static func create(
        missionID: BurnBarMissionID,
        dag: BurnBarDAGContract,
        dispatch: any BurnBarDAGSchedulerDispatch,
        metricsProvider: (any BurnBarDAGReconcilerMetricsProvider)? = nil,
        maxConcurrency: Int = BurnBarParallelDAGScheduler.defaultMaxConcurrency
    ) -> BurnBarParallelDAGScheduler {
        let scheduler = BurnBarParallelDAGScheduler(
            missionID: missionID,
            dag: dag,
            dispatch: dispatch,
            metricsProvider: metricsProvider,
            maxConcurrency: maxConcurrency
        )
        activeSchedulers[missionID] = scheduler
        return scheduler
    }

    /// Retrieves the active scheduler for a mission if one exists.
    public static func activeScheduler(for missionID: BurnBarMissionID) -> BurnBarParallelDAGScheduler? {
        activeSchedulers[missionID]
    }
}
