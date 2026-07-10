import { createServer, type Server } from "node:http";
import type { IngressService } from "./ingressService.js";
import type { UserAuthenticator } from "./ports.js";
import { bearerToken, empty, handleError, json, readBody, readJson } from "./http.js";
import { parseBeginEnrollment, parseCompleteEnrollment, parseCreateUpload } from "./requestParsers.js";

export interface IngressServerOptions { jsonBodyLimit: number; evidenceBodyLimit: number }

export function createIngressServer(service: IngressService, authenticator: UserAuthenticator, options: IngressServerOptions): Server {
  return createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", "http://localhost");
      if (request.method === "GET" && (url.pathname === "/healthz" || url.pathname === "/readyz")) return json(response, 200, { status: "ok" });
      const identity = await authenticator.authenticate(bearerToken(request));
      if (request.method === "POST" && url.pathname === "/v1/enroll/begin") {
        return json(response, 200, await service.beginEnrollment(identity.uid, parseBeginEnrollment(await readJson(request, options.jsonBodyLimit))));
      }
      if (request.method === "POST" && url.pathname === "/v1/enroll/complete") {
        await service.completeEnrollment(identity.uid, parseCompleteEnrollment(await readJson(request, options.jsonBodyLimit)));
        return empty(response);
      }
      if (request.method === "POST" && url.pathname === "/v1/evidence-uploads") {
        return json(response, 201, await service.createUpload(identity.uid, parseCreateUpload(await readJson(request, options.jsonBodyLimit))));
      }
      const uploadMatch = /^\/v1\/evidence-uploads\/([A-Za-z0-9._:-]+)$/.exec(url.pathname);
      if (request.method === "PUT" && uploadMatch?.[1] !== undefined) {
        return json(response, 200, await service.upload(identity.uid, uploadMatch[1], await readBody(request, options.evidenceBodyLimit)));
      }
      return json(response, 404, { error: { code: "not_found", message: "Route was not found", retryable: false } });
    } catch (error) {
      handleError(response, error);
    }
  });
}
