using System;
using System.Reflection;
using OpenBurnBar.CloudSync.AppCheck.Windows;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Windows.Tests;

public sealed class NCryptInteropContractTests
{
    [Fact]
    public void Platform_claim_nonce_buffer_matches_the_Windows_SDK_ABI()
    {
        Type native = NativeType();
        FieldInfo pcrMaskBufferType = native.GetField(
            "NCRYPTBUFFER_TPM_PLATFORM_CLAIM_PCR_MASK",
            BindingFlags.Static | BindingFlags.NonPublic)!;
        FieldInfo nonceBufferType = native.GetField(
            "NCRYPTBUFFER_TPM_PLATFORM_CLAIM_NONCE",
            BindingFlags.Static | BindingFlags.NonPublic)!;

        Assert.Equal(80, pcrMaskBufferType.GetRawConstantValue());
        Assert.Equal(81, nonceBufferType.GetRawConstantValue());
    }

    [Fact]
    public void Platform_claim_key_creation_exposes_the_AIK_usage_policy_contract()
    {
        Type native = NativeType();

        Assert.Equal(
            "PCP_KEY_USAGE_POLICY",
            native.GetField("NCRYPT_PCP_KEY_USAGE_POLICY_PROPERTY", BindingFlags.Static | BindingFlags.NonPublic)!
                .GetRawConstantValue());
        Assert.Equal(
            0x00000008,
            native.GetField("NCRYPT_PCP_IDENTITY_KEY", BindingFlags.Static | BindingFlags.NonPublic)!
                .GetRawConstantValue());
        Assert.NotNull(native.GetMethod("NCryptSetProperty", BindingFlags.Static | BindingFlags.NonPublic));
        Assert.NotNull(native.GetMethod("NCryptDeleteKey", BindingFlags.Static | BindingFlags.NonPublic));
    }

    [Fact]
    public void VerifyClaim_requires_a_real_output_descriptor_and_has_a_matching_free_api()
    {
        Type native = NativeType();
        MethodInfo verify = native.GetMethod(
            "NCryptVerifyClaim",
            BindingFlags.Static | BindingFlags.NonPublic)!;

        ParameterInfo output = verify.GetParameters()[6];
        Assert.True(output.ParameterType.IsByRef);
        Assert.Equal("NCryptBufferDesc", output.ParameterType.GetElementType()?.Name);
        Assert.NotNull(native.GetMethod("NCryptFreeBuffer", BindingFlags.Static | BindingFlags.NonPublic));
    }

    private static Type NativeType() => typeof(TpmPlatformClaimVerifier).Assembly.GetType(
        "OpenBurnBar.CloudSync.AppCheck.Windows.Interop.NCryptNative",
        throwOnError: true)!;
}
