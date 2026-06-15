import { endpointAuthorizationCatalog } from "./endpointAuthorizationCatalog.generated.js";
import type { EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export const endpointAuthorizationMatrix: EndpointAuthorizationEntry[] = endpointAuthorizationCatalog.sort((left, right) =>
  left.exportedName.localeCompare(right.exportedName),
);
