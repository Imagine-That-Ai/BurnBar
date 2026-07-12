export function describeLocalCertificationHost({ platform, release, architecture, cpuModel, ramBytes }) {
  if (platform === "win32") {
    return {
      label: "Windows native host (physicality not attested)",
      evidenceScope: "Windows-native automated evidence",
      device: {
        kind: "windows-native-unattested",
        manufacturer: "unattested",
        model: cpuModel,
        architecture,
        osBuild: `${platform} ${release}`,
        tpm: "not-inspected",
        cpu: cpuModel,
        ramBytes,
      },
    };
  }

  if (platform === "darwin") {
    return {
      label: "macOS authoring host",
      evidenceScope: "macOS-reachable evidence",
      device: {
        kind: "macos-authoring-host",
        manufacturer: "Apple",
        model: cpuModel,
        architecture,
        osBuild: `${platform} ${release}`,
        tpm: "not-applicable",
        cpu: cpuModel,
        ramBytes,
      },
    };
  }

  return {
    label: `${platform} authoring host`,
    evidenceScope: `${platform}-reachable automated evidence`,
    device: {
      kind: `${platform}-authoring-host`,
      manufacturer: "unattested",
      model: cpuModel,
      architecture,
      osBuild: `${platform} ${release}`,
      tpm: "not-inspected",
      cpu: cpuModel,
      ramBytes,
    },
  };
}
