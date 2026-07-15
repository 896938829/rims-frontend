import '../../../../core/result/failure.dart';

enum TerminalSessionRevocationStatus {
  completed,
  remoteRejected,
  terminalWithCleanupDebt,
}

final class TerminalSessionRevocationResult {
  const TerminalSessionRevocationResult.completed()
    : status = TerminalSessionRevocationStatus.completed,
      failure = null;

  const TerminalSessionRevocationResult.remoteRejected(this.failure)
    : status = TerminalSessionRevocationStatus.remoteRejected;

  const TerminalSessionRevocationResult.cleanupDebt(this.failure)
    : status = TerminalSessionRevocationStatus.terminalWithCleanupDebt;

  final TerminalSessionRevocationStatus status;
  final Failure? failure;

  bool get isTerminal =>
      status != TerminalSessionRevocationStatus.remoteRejected;
}
