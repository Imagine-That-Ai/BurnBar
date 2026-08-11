const threadSendLeases = new Map<string, string>();

export function acquireChatThreadSendLease(threadID: string, controllerID: string): boolean {
  const owner = threadSendLeases.get(threadID);
  if (owner && owner !== controllerID) return false;
  threadSendLeases.set(threadID, controllerID);
  return true;
}

export function releaseChatThreadSendLease(threadID: string, controllerID: string): void {
  if (threadSendLeases.get(threadID) === controllerID) {
    threadSendLeases.delete(threadID);
  }
}

export function releaseChatControllerLeases(controllerID: string): void {
  for (const [threadID, owner] of threadSendLeases.entries()) {
    if (owner === controllerID) threadSendLeases.delete(threadID);
  }
}

export function resetChatRuntimeForTests(): void {
  threadSendLeases.clear();
}
