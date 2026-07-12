namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// G4: memory approve/reject is Mac-only; Windows surfaces are read-only on review actions.
/// </summary>
public sealed class MemoryReviewMacOnlyException : Exception
{
    public MemoryReviewMacOnlyException()
        : base("Approve and reject are available on your Mac. This Windows device can review the inbox read-only.")
    {
    }
}