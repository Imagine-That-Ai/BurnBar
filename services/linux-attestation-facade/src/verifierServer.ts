import { createServer, type Server } from "node:http";
import { parseVerifyRequest } from "./contracts.js";
import { bearerToken, handleError, json, readJson } from "./http.js";
import type { ServiceAuthenticator } from "./ports.js";
import type { VerifierService } from "./verifierService.js";

export function createVerifierServer(service: VerifierService, authenticator: ServiceAuthenticator, jsonBodyLimit: number): Server {
  return createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", "http://localhost");
      if (request.method === "GET" && (url.pathname === "/healthz" || url.pathname === "/readyz")) return json(response, 200, { status: "ok" });
      if (request.method !== "POST" || url.pathname !== "/v1/verify") {
        return json(response, 404, { error: { code: "not_found", message: "Route was not found", retryable: false } });
      }
      await authenticator.authenticate(bearerToken(request));
      return json(response, 200, await service.verify(parseVerifyRequest(await readJson(request, jsonBodyLimit))));
    } catch (error) {
      handleError(response, error);
    }
  });
}
