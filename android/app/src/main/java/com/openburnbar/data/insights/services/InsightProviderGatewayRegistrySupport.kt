package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import java.time.Instant

internal fun registerCredentialBackedInsightGateways(
    credentials: AndroidInsightCredentialStore,
    gateways: MutableList<InsightAnalysisModelGateway>,
    injectedHermes: InsightAnalysisModelGateway?,
) {
    registerOpenAIInsightGateway(credentials, gateways)
    registerAnthropicInsightGateway(credentials, gateways)
    registerMiniMaxInsightGateway(credentials, gateways)
    registerZaiInsightGateway(credentials, gateways)
    registerKimiInsightGateway(credentials, gateways)
    registerLegacyHermesEndpointGateway(credentials, gateways, injectedHermes)
}

private fun registerOpenAIInsightGateway(credentials: AndroidInsightCredentialStore, gateways: MutableList<InsightAnalysisModelGateway>) {
    credentials.credential("openai")?.let { key ->
        gateways +=
            OpenAICompatibleInsightAnalysisGateway(
                providerKey = "openai",
                displayName = "OpenAI / Codex",
                apiKey = key,
                baseURL = credentials.endpoint("openai") ?: "https://api.openai.com",
                models =
                listOf(
                    insightGatewayTag("openai", "gpt-5.5", "Codex / GPT-5.5"),
                    insightGatewayTag("openai", "gpt-5.4", "Codex / GPT-5.4"),
                    insightGatewayTag("openai", "gpt-4.1", "GPT-4.1"),
                ),
            )
    }
}

private fun registerAnthropicInsightGateway(credentials: AndroidInsightCredentialStore, gateways: MutableList<InsightAnalysisModelGateway>) {
    credentials.credential("anthropic", listOf("claude"))?.let { key ->
        gateways += AnthropicInsightAnalysisGateway(apiKey = key)
    }
}

private fun registerMiniMaxInsightGateway(credentials: AndroidInsightCredentialStore, gateways: MutableList<InsightAnalysisModelGateway>) {
    credentials.credential("minimax")?.let { key ->
        gateways +=
            OpenAICompatibleInsightAnalysisGateway(
                providerKey = "minimax",
                displayName = "MiniMax",
                apiKey = key,
                baseURL = credentials.endpoint("minimax") ?: "https://api.minimax.io",
                models = listOf(insightGatewayTag("minimax", "minimax-m1", "MiniMax M1")),
            )
    }
}

private fun registerZaiInsightGateway(credentials: AndroidInsightCredentialStore, gateways: MutableList<InsightAnalysisModelGateway>) {
    credentials.credential("zai", listOf("z.ai", "zhipu"))?.let { key ->
        gateways +=
            OpenAICompatibleInsightAnalysisGateway(
                providerKey = "zai",
                displayName = "Z.ai",
                apiKey = key,
                baseURL = credentials.endpoint("zai") ?: "https://open.bigmodel.cn",
                path = "/api/paas/v4/chat/completions",
                models = listOf(insightGatewayTag("zai", "glm-4.6", "GLM 4.6")),
            )
    }
}

private fun registerKimiInsightGateway(credentials: AndroidInsightCredentialStore, gateways: MutableList<InsightAnalysisModelGateway>) {
    credentials.credential("kimi", listOf("moonshot"))?.let { key ->
        gateways +=
            OpenAICompatibleInsightAnalysisGateway(
                providerKey = "kimi",
                displayName = "Kimi",
                apiKey = key,
                baseURL = credentials.endpoint("kimi") ?: "https://api.moonshot.ai",
                models = listOf(insightGatewayTag("kimi", "kimi-k2", "Kimi K2")),
            )
    }
}

private fun registerLegacyHermesEndpointGateway(
    credentials: AndroidInsightCredentialStore,
    gateways: MutableList<InsightAnalysisModelGateway>,
    injectedHermes: InsightAnalysisModelGateway?,
) {
    if (injectedHermes != null) return
    credentials.endpoint("hermes")?.let { endpoint ->
        gateways +=
            OpenAICompatibleInsightAnalysisGateway(
                providerKey = "hermes",
                displayName = "Hermes",
                apiKey = credentials.credential("hermes"),
                baseURL = endpoint,
                models = listOf(insightGatewayTag("hermes", "hermes-agent", "Hermes gateway", InsightEgressTier.USER_RELAY)),
            )
    }
}

internal fun insightGatewayTag(
    providerKey: String,
    modelID: String,
    displayName: String,
    egressTier: InsightEgressTier = InsightEgressTier.USER_KEY,
): InsightModelTag = InsightModelTag(
    providerKey = providerKey,
    modelID = modelID,
    displayName = displayName,
    egressTier = egressTier,
    stampedAt = Instant.now().toString(),
)
