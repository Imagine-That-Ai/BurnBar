package com.openburnbar.ui.burn

import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot

fun matchingQuotaAccounts(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>
): List<ProviderAccount> {
    val accountMatches = snapshot.accountId
        ?.takeIf { it.isNotBlank() }
        ?.let { id -> accounts.filter { it.id == id } }
        .orEmpty()
    if (accountMatches.isNotEmpty()) return accountMatches

    val providerKeys = setOfNotNull(
        snapshot.provider.takeIf { it.isNotBlank() },
        snapshot.providerId?.takeIf { it.isNotBlank() }
    )
    return accounts.filter { it.providerId in providerKeys }
}

fun quotaAccountName(snapshot: ProviderQuotaSnapshot, accounts: List<ProviderAccount>): String {
    val account = matchingQuotaAccounts(snapshot, accounts).firstOrNull()
    return account?.label?.takeIf { it.isNotBlank() }
        ?: snapshot.accountLabel?.takeIf { it.isNotBlank() }
        ?: account?.id?.takeIf { it.isNotBlank() }
        ?: snapshot.accountId?.takeIf { it.isNotBlank() }
        ?: "Account"
}

fun quotaAccountEmail(snapshot: ProviderQuotaSnapshot, accounts: List<ProviderAccount>): String? {
    return quotaAccountEmail(snapshot, accounts, fallbackEmail = null)
}

fun quotaAccountEmail(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    fallbackEmail: String?
): String? {
    val account = matchingQuotaAccounts(snapshot, accounts).firstOrNull()
    return firstEmailLike(
        account?.identityHint,
        account?.label,
        snapshot.accountLabel,
        account?.redactedLabel,
        fallbackEmail
    )
}

private fun firstEmailLike(vararg values: String?): String? {
    return values.firstOrNull { value ->
        value?.contains("@") == true && value.contains(".")
    }?.trim()
}
