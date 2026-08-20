import { bytesToBase64, sha256Hex } from '../shared/binary';
import type { BrowserAPI } from '../shared/browser';
import { SafariExtensionError } from '../shared/errors';
import {
  SAFARI_BRIDGE_CHUNK_BYTES,
  SAFARI_BRIDGE_PROTOCOL_VERSION,
  createNativeRequest,
  parseBridgeCompleteResult,
  parseBridgeHelloResult,
  parseBridgePollResult,
  parseBridgePopupActionResult,
  parseNativeResponse,
  unwrapNativeResponse,
  type BridgeCompleteParams,
  type BridgeHelloParams,
  type BridgeHelloResult,
  type BridgeMethod,
  type BridgePollParams,
  type BridgePollResult,
  type BridgePopupActionParams,
  type BridgePopupActionResult,
  type PageState,
  type SafariExtensionCapabilities,
  type SafariTabSnapshot
} from '../shared/protocol';

export const OPENBURNBAR_NATIVE_APPLICATION_ID = 'com.openburnbar.app';

export interface NativeMessagingAdapter {
  send(message: unknown): Promise<unknown>;
}

export class BrowserNativeMessagingAdapter implements NativeMessagingAdapter {
  constructor(
    private readonly browserAPI: BrowserAPI,
    private readonly applicationId = OPENBURNBAR_NATIVE_APPLICATION_ID
  ) {}

  send(message: unknown): Promise<unknown> {
    return this.browserAPI.runtime.sendNativeMessage(this.applicationId, message);
  }
}

interface NativeBridgeOptions {
  adapter: NativeMessagingAdapter;
  extensionVersion: string;
  sessionId?: string;
  maxInlineBytes?: number;
  idFactory?: () => string;
  textEncoder?: TextEncoder;
}

export class NativeBridge {
  readonly extensionInstanceId: string;
  private readonly adapter: NativeMessagingAdapter;
  private readonly extensionVersion: string;
  private readonly maxInlineBytes: number;
  private readonly idFactory: () => string;
  private readonly textEncoder: TextEncoder;
  private attachedSessionId?: string;

  constructor(options: NativeBridgeOptions) {
    this.adapter = options.adapter;
    this.extensionVersion = options.extensionVersion;
    this.extensionInstanceId = options.sessionId ?? crypto.randomUUID();
    this.maxInlineBytes = options.maxInlineBytes ?? SAFARI_BRIDGE_CHUNK_BYTES;
    this.idFactory = options.idFactory ?? (() => crypto.randomUUID());
    this.textEncoder = options.textEncoder ?? new TextEncoder();
  }

  get sessionId(): string | undefined {
    return this.attachedSessionId;
  }

  async hello(
    activePage: PageState | undefined,
    capabilities: SafariExtensionCapabilities
  ): Promise<BridgeHelloResult> {
    const params: BridgeHelloParams = {
      extensionInstanceId: this.extensionInstanceId,
      clientName: `OpenBurnBar Safari WebExtension/${this.extensionVersion}`,
      supportedProtocolVersions: [SAFARI_BRIDGE_PROTOCOL_VERSION],
      capabilities,
      ...(activePage === undefined ? {} : { activePage })
    };
    const result = parseBridgeHelloResult(await this.request('bridge.hello', params));
    this.attachedSessionId = result.sessionId;
    return result;
  }

  async poll(activePage: PageState | undefined, knownTabs: SafariTabSnapshot[]): Promise<BridgePollResult> {
    const sessionId = this.requireSessionId();
    const params: BridgePollParams = {
      sessionId,
      knownTabs,
      ...(activePage === undefined ? {} : { activePage })
    };
    return parseBridgePollResult(await this.request('bridge.poll', params));
  }

  async complete(params: Omit<BridgeCompleteParams, 'sessionId'>): Promise<void> {
    const result = parseBridgeCompleteResult(
      await this.request('bridge.complete', {
        sessionId: this.requireSessionId(),
        ...params
      })
    );
    if (!result.accepted) {
      throw new SafariExtensionError('command_completion_rejected', 'The daemon rejected the Safari command result.');
    }
  }

  async popupAction(action: string, payload: Record<string, unknown>): Promise<BridgePopupActionResult> {
    const sessionId = this.requireSessionId();
    const params: BridgePopupActionParams = {
      sessionId,
      action,
      payload: {
        safariSessionId: sessionId,
        ...payload
      }
    };
    return parseBridgePopupActionResult(await this.request('bridge.popupAction', params));
  }

  private requireSessionId(): string {
    if (!this.attachedSessionId) {
      throw new SafariExtensionError('safari_session_detached', 'The Safari extension is not attached to OpenBurnBar.');
    }
    return this.attachedSessionId;
  }

  async request<_TResult = unknown>(
    method: Exclude<BridgeMethod, `bridge.chunk.${string}`>,
    params: Record<string, unknown>
  ): Promise<unknown> {
    const requestId = this.idFactory();
    const envelope = createNativeRequest(requestId, method, params);
    const encoded = this.textEncoder.encode(JSON.stringify(envelope));
    if (encoded.byteLength <= this.maxInlineBytes) {
      return this.sendEnvelope(envelope);
    }
    return this.sendChunked(method, encoded);
  }

  private async sendEnvelope(envelope: ReturnType<typeof createNativeRequest>): Promise<unknown> {
    let rawResponse: unknown;
    try {
      rawResponse = await this.adapter.send(envelope);
    } catch (error) {
      throw new SafariExtensionError(
        'native_bridge_unavailable',
        'OpenBurnBar could not reach its native Safari handler.',
        {
          retryable: true,
          details: error
        }
      );
    }
    const response = parseNativeResponse(rawResponse, envelope.id);
    return unwrapNativeResponse(response);
  }

  private async sendChunked(
    originalMethod: Exclude<BridgeMethod, `bridge.chunk.${string}`>,
    encodedEnvelope: Uint8Array
  ): Promise<unknown> {
    const transferId = this.idFactory();
    const chunkCount = Math.ceil(encodedEnvelope.byteLength / this.maxInlineBytes);
    const digest = await sha256Hex(encodedEnvelope);
    await this.sendEnvelope(
      createNativeRequest(this.idFactory(), 'bridge.chunk.begin', {
        transferId,
        originalMethod,
        byteLength: encodedEnvelope.byteLength,
        chunkCount,
        sha256: digest
      })
    );
    for (let index = 0; index < chunkCount; index += 1) {
      const start = index * this.maxInlineBytes;
      const bytes = encodedEnvelope.subarray(start, Math.min(start + this.maxInlineBytes, encodedEnvelope.byteLength));
      await this.sendEnvelope(
        createNativeRequest(this.idFactory(), 'bridge.chunk.append', {
          transferId,
          index,
          data: bytesToBase64(bytes)
        })
      );
    }
    return this.sendEnvelope(
      createNativeRequest(this.idFactory(), 'bridge.chunk.commit', {
        transferId
      })
    );
  }
}

export function protocolVersion(): number {
  return SAFARI_BRIDGE_PROTOCOL_VERSION;
}
