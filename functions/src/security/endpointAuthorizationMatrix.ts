import { endpointAuthorizationCatalog } from "./endpointAuthorizationCatalog.generated.js";
import type { EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export type { BolaCoverageKind, BolaCoverageRef, EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export const endpointAuthorizationMatrix: EndpointAuthorizationEntry[] = endpointAuthorizationCatalog.sort((left, right) =>
  left.exportedName.localeCompare(right.exportedName),
);

export function endpointAuthorizationByName(): Map<string, EndpointAuthorizationEntry> {
  return new Map(endpointAuthorizationMatrix.map((entry) => [entry.exportedName, entry]));
}