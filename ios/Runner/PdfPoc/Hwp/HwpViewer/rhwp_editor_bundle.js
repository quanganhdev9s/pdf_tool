// Gộp từ @rhwp/editor 0.8.4 (MIT) — transport.js + index.js.
//
// Gộp vì trang chủ được nạp bằng `loadHTMLString` với baseURL https, nên nó
// không có chỗ nào để phục vụ `./transport.js`: một `import` tương đối sẽ bay
// thẳng ra Internet. Cả hai `export` bị gỡ; script chạy trong global scope và
// `createEditor` hiện ra trên `window`.
const PROTOCOL_VERSION = 1;
const CAPABILITIES = [
  'transferable-array-buffer',
  'hml-export',
  'renderer-diagnostics-v1',
  'notify-saved-v1',
];
const LONG_RUNNING_METHODS = new Set([
  'loadFile', 'exportHwp', 'exportHwpVerify', 'exportHwpx', 'exportHml',
]);

function requestTimeoutFor(method, configuredTimeout) {
  if (configuredTimeout != null) return configuredTimeout;
  return LONG_RUNNING_METHODS.has(method) ? 60000 : 10000;
}

function sessionId() {
  const secureRandom = globalThis.crypto;
  if (typeof secureRandom?.randomUUID === 'function') return secureRandom.randomUUID();
  if (typeof secureRandom?.getRandomValues !== 'function') {
    throw new Error('Secure random generation is unavailable');
  }
  const bytes = secureRandom.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function copiedBinary(value) {
  if (value instanceof ArrayBuffer) return new Uint8Array(value).slice();
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
  }
  return null;
}

function prepareParams(params) {
  const data = copiedBinary(params?.data);
  if (!data) return { params, transfer: [] };
  return { params: { ...params, data }, transfer: [data.buffer] };
}

function isResponseEnvelope(message, legacy, sessionId) {
  if (message?.type !== 'rhwp-response' || !Number.isSafeInteger(message.id)) return false;
  if (legacy) return true;
  if (message.version !== PROTOCOL_VERSION || message.sessionId !== sessionId) return false;
  const hasResult = Object.prototype.hasOwnProperty.call(message, 'result');
  const hasError = Object.prototype.hasOwnProperty.call(message, 'error');
  if (hasResult === hasError) return false;
  return !hasError || (typeof message.error?.code === 'string'
    && typeof message.error?.message === 'string');
}

class EditorTransport {
  constructor(iframe, studioUrl, options = {}) {
    this._iframe = iframe;
    const targetUrl = new URL(studioUrl, globalThis.location?.href);
    if (targetUrl.protocol !== 'http:' && targetUrl.protocol !== 'https:') {
      throw new Error('studioUrl must use HTTP(S)');
    }
    this._targetOrigin = targetUrl.origin;
    this._window = options.window || window;
    this._requestTimeoutMs = options.requestTimeoutMs;
    this._handshakeTimeoutMs = options.handshakeTimeoutMs ?? 1000;
    this._sessionId = sessionId();
    this._nextId = 0;
    this._pending = new Map();
    this._port = null;
    this._peerCapabilities = new Set();
    this._legacy = false;
    this._destroyed = false;
    this._onLegacyMessage = (event) => this._handleLegacyMessage(event);
  }

  connect() {
    if (this._destroyed) return Promise.reject(new Error('Editor destroyed'));
    const channel = new MessageChannel();
    this._port = channel.port1;
    this._port.onmessage = (event) => this._handlePortMessage(event.data);
    this._port.start();
    return new Promise((resolve, reject) => {
      this._connectResolve = resolve;
      this._connectReject = reject;
      this._connectTimer = setTimeout(() => this._useLegacy(), this._handshakeTimeoutMs);
      this._iframe.contentWindow.postMessage({
        type: 'rhwp-connect', version: PROTOCOL_VERSION, sessionId: this._sessionId,
        capabilities: CAPABILITIES,
      }, this._targetOrigin, [channel.port2]);
    });
  }

  request(method, params = {}) {
    if (this._destroyed) return Promise.reject(new Error('Editor destroyed'));
    const id = ++this._nextId;
    const prepared = prepareParams(params);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`Request timeout: ${method}`));
      }, requestTimeoutFor(method, this._requestTimeoutMs));
      this._pending.set(id, { resolve, reject, timeout });
      try {
        this._send({
          type: 'rhwp-request', version: PROTOCOL_VERSION,
          sessionId: this._sessionId, id, method, params: prepared.params,
        }, prepared.transfer);
      } catch (error) {
        clearTimeout(timeout);
        this._pending.delete(id);
        reject(error);
      }
    });
  }

  supports(capability) {
    return this._peerCapabilities.has(capability);
  }

  destroy() {
    if (this._destroyed) return;
    this._destroyed = true;
    clearTimeout(this._connectTimer);
    this._port && (this._port.onmessage = null);
    this._port?.close();
    this._rejectConnect(new Error('Editor destroyed'));
    this._window.removeEventListener('message', this._onLegacyMessage);
    for (const pending of this._pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error('Editor destroyed'));
    }
    this._pending.clear();
  }

  _send(message, transfer) {
    if (this._legacy) {
      const { version, sessionId: ignored, ...legacyMessage } = message;
      this._iframe.contentWindow.postMessage(legacyMessage, this._targetOrigin, transfer);
      return;
    }
    this._port.postMessage(message, transfer);
  }

  _handlePortMessage(message) {
    if (message?.type === 'rhwp-connected'
        && message.version === PROTOCOL_VERSION
        && message.sessionId === this._sessionId
        && message.capabilities?.includes('transferable-array-buffer')) {
      clearTimeout(this._connectTimer);
      this._peerCapabilities = new Set(message.capabilities);
      const resolve = this._connectResolve;
      this._connectResolve = null;
      this._connectReject = null;
      resolve?.();
      return;
    }
    if (message?.type === 'rhwp-connect-error'
        && message.version === PROTOCOL_VERSION
        && message.sessionId === this._sessionId
        && typeof message.error?.message === 'string') {
      const error = new Error(message.error.message);
      error.code = message.error.code;
      error.supportedVersions = message.error.supportedVersions;
      this._rejectConnect(error);
      return;
    }
    this._handleResponse(message);
  }

  _handleLegacyMessage(event) {
    if (event.source !== this._iframe.contentWindow || event.origin !== this._targetOrigin) return;
    this._handleResponse(event.data, true);
  }

  _handleResponse(message, legacy = false) {
    if (legacy) {
      if (!isResponseEnvelope(message, true, this._sessionId)) return;
    } else if (message?.type !== 'rhwp-response'
        || !Number.isSafeInteger(message.id)
        || message.sessionId !== this._sessionId) {
      return;
    }
    const pending = this._pending.get(message.id);
    if (!pending) return;
    if (!legacy && Number.isSafeInteger(message.version)
        && message.version !== PROTOCOL_VERSION) {
      this._rejectPendingResponse(message.id, pending, 'UNSUPPORTED_VERSION',
        `Unsupported embed protocol version: ${message.version}`, [PROTOCOL_VERSION]);
      return;
    }
    if (!isResponseEnvelope(message, legacy, this._sessionId)) {
      setTimeout(() => this._rejectPendingResponse(
        message.id, pending, 'INVALID_RESPONSE', 'Invalid response envelope',
      ), 0);
      return;
    }
    this._pending.delete(message.id);
    clearTimeout(pending.timeout);
    if (message.error) {
      const error = new Error(message.error.message || message.error);
      if (message.error.code) error.code = message.error.code;
      pending.reject(error);
    }
    else pending.resolve(message.result);
  }

  _rejectPendingResponse(id, pending, code, message, supportedVersions) {
    if (this._pending.get(id) !== pending) return;
    this._pending.delete(id);
    clearTimeout(pending.timeout);
    const error = new Error(message);
    error.code = code;
    if (supportedVersions) error.supportedVersions = supportedVersions;
    pending.reject(error);
  }

  _rejectConnect(error) {
    if (!this._connectReject) return;
    clearTimeout(this._connectTimer);
    this._port && (this._port.onmessage = null);
    this._port?.close();
    this._port = null;
    const reject = this._connectReject;
    this._connectResolve = null;
    this._connectReject = null;
    reject(error);
  }

  _useLegacy() {
    if (this._destroyed || !this._connectResolve) return;
    this._port && (this._port.onmessage = null);
    this._port?.close();
    this._port = null;
    this._legacy = true;
    this._peerCapabilities.clear();
    this._window.addEventListener('message', this._onLegacyMessage);
    const resolve = this._connectResolve;
    this._connectResolve = null;
    this._connectReject = null;
    resolve();
  }
}

/**
 * @rhwp/editor — HWP 에디터를 iframe으로 임베드
 *
 * 사용법:
 *   import { createEditor } from '@rhwp/editor';
 *   const editor = await createEditor('#container');
 *   await editor.loadFile(buffer, 'document.hwp');
 *
 * 본 제품은 한글과컴퓨터의 한글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
 */


const DEFAULT_STUDIO_URL = 'https://edwardkim.github.io/rhwp/';

/**
 * HWP 에디터를 생성하여 지정된 컨테이너에 마운트합니다.
 *
 * @param container - CSS 셀렉터 또는 HTMLElement
 * @param options - 에디터 옵션
 * @returns RhwpEditor 인스턴스
 *
 * @example
 * ```javascript
 * const editor = await createEditor('#editor');
 * await editor.loadFile(hwpBuffer, 'sample.hwp');
 * console.log(await editor.pageCount());
 * ```
 */
async function createEditor(container, options = {}) {
  const el = typeof container === 'string'
    ? document.querySelector(container)
    : container;

  if (!el) {
    throw new Error(`Container not found: ${container}`);
  }

  let studioUrl = options.studioUrl || DEFAULT_STUDIO_URL;
  if (options.renderer !== undefined) {
    if (!['auto', 'canvas2d', 'canvaskit'].includes(options.renderer)) {
      throw new TypeError(`Unsupported renderer: ${options.renderer}`);
    }
    const resolvedStudioUrl = new URL(studioUrl, document.baseURI);
    resolvedStudioUrl.searchParams.set('renderer', options.renderer);
    studioUrl = resolvedStudioUrl.href;
  }

  // iframe 생성
  const iframe = document.createElement('iframe');
  iframe.src = studioUrl;
  iframe.style.width = options.width || '100%';
  iframe.style.height = options.height || '100%';
  iframe.style.border = 'none';
  iframe.allow = 'clipboard-read; clipboard-write';
  el.appendChild(iframe);

  // iframe 로드 대기
  await new Promise((resolve) => {
    iframe.addEventListener('load', resolve, { once: true });
  });

  // WASM 초기화 대기 (ready 메서드로 확인)
  let transport;
  try {
    transport = new EditorTransport(iframe, studioUrl, {
      requestTimeoutMs: options.requestTimeoutMs,
      handshakeTimeoutMs: options.handshakeTimeoutMs,
    });
    await transport.connect();
    const editor = new RhwpEditor(iframe, transport);
    await editor._waitReady();
    return editor;
  } catch (error) {
    transport?.destroy();
    iframe.remove();
    throw error;
  }
}

/**
 * HWP 에디터 인스턴스
 *
 * iframe 내부의 rhwp-studio와 postMessage로 통신합니다.
 */
class RhwpEditor {
  constructor(iframe, transport) {
    this._iframe = iframe;
    this._transport = transport;
  }

  /**
   * iframe에 요청을 보내고 응답을 기다립니다.
   * @internal
   */
  _request(method, params = {}) {
    return this._transport.request(method, params);
  }

  /** WASM 초기화 완료 대기 @internal */
  async _waitReady() {
    for (let i = 0; i < 30; i++) {
      try {
        const result = await this._request('ready');
        if (result) return;
      } catch {
        // 아직 준비 안 됨 — 재시도
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error('Editor initialization timeout');
  }

  /**
   * HWP 파일을 로드합니다.
   *
   * @param data - HWP 파일의 ArrayBuffer 또는 Uint8Array
   * @param fileName - 파일 이름 (선택)
   * @param options - 로드 옵션 (선택)
   * @param options.skipUnsavedGuard - 미저장 변경 확인 없이 문서 교체
   * @param options.suppressDialogs - 로드 후 안내창(HWPX 검증, 로컬 글꼴 감지) 없이 열기.
   *   임베드 환경에서 안내창의 사용자 선택을 기다리느라 loadFile 응답이 지연/교착되는
   *   것을 방지한다. 검증 경고는 '그대로 열기'로 처리되고, 글꼴은 웹 대체 글꼴로 표시된다.
   * @returns { pageCount: number }
   *
   * @example
   * ```javascript
   * const resp = await fetch('document.hwp');
   * const buffer = await resp.arrayBuffer();
   * const result = await editor.loadFile(buffer, 'document.hwp');
   * console.log(`${result.pageCount}페이지`);
   * ```
   */
  async loadFile(data, fileName = 'document.hwp', options = {}) {
    return this._request('loadFile', {
      data,
      fileName,
      skipUnsavedGuard: options.skipUnsavedGuard === true,
      suppressDialogs: options.suppressDialogs === undefined || options.suppressDialogs === true,
    });
  }

  /**
   * 현재 문서의 페이지 수를 반환합니다.
   * @returns 페이지 수
   */
  async pageCount() {
    return this._request('pageCount');
  }

  /**
   * 특정 페이지를 SVG 문자열로 렌더링합니다.
   * @param page - 0부터 시작하는 페이지 번호
   * @returns SVG 문자열
   */
  async getPageSvg(page = 0) {
    return this._request('getPageSvg', { page });
  }

  /**
   * 선택된 renderer와 페이지별 CanvasKit readiness 진단을 반환합니다.
   * @param page - 0부터 시작하는 페이지 번호
   */
  async getRendererDiagnostics(page = 0) {
    if (!Number.isSafeInteger(page) || page < 0) {
      throw new TypeError('page must be a non-negative safe integer');
    }
    if (!this._transport.supports('renderer-diagnostics-v1')) {
      throw new Error('Renderer diagnostics v1 is not supported by this Studio');
    }
    const result = await this._request('getRendererDiagnostics', { page });
    if (result?.schemaVersion !== 1 || result?.page?.index !== page) {
      throw new Error('Studio returned invalid renderer diagnostics v1');
    }
    return result;
  }

  /**
   * 현재 문서를 HWP 바이너리로 내보냅니다.
   * @returns {Promise<Uint8Array>} HWP 파일 bytes
   */
  async exportHwp() {
    const result = await this._request('exportHwp');
    return result instanceof Uint8Array ? result : new Uint8Array(result || []);
  }

  /**
   * 현재 문서를 HWPX(ZIP+XML) 바이너리로 내보냅니다.
   * @returns {Promise<Uint8Array>} HWPX 파일 bytes
   */
  async exportHwpx() {
    const result = await this._request('exportHwpx');
    return result instanceof Uint8Array ? result : new Uint8Array(result || []);
  }

  /** 현재 문서를 HML(XML) 바이너리로 내보냅니다. */
  async exportHml() {
    const result = await this._request('exportHml');
    return result instanceof Uint8Array ? result : new Uint8Array(result || []);
  }

  /** 현재 문서의 HML 저장 가능 여부와 blocker를 반환합니다. */
  async getHmlSaveState() {
    return this._request('getHmlSaveState');
  }

  /**
   * HWP 직렬화 + 자기 재로드 검증 메타데이터를 반환합니다 (#178).
   *
   * 검증 메타데이터만 반환하며, 실제 HWP bytes 가 필요하면 `exportHwp()` 를 별도 호출하세요.
   *
   * @returns {Promise<{bytesLen: number, pageCountBefore: number, pageCountAfter: number, recovered: boolean}>}
   */
  async exportHwpVerify() {
    return this._request('exportHwpVerify');
  }

  /**
   * 내보내기 바이트의 영속화(업로드/핸드오프) 완료를 스튜디오에 통지합니다.
   *
   * dirty 상태를 해제하고 자동복구 draft의 IndexedDB 삭제 "완료"까지 기다린 뒤
   * resolve합니다 — resolve 이후 창을 닫아도 안전합니다. 업로드 실패 시에는
   * 호출하지 마세요(백업 draft가 보존되어야 합니다).
   *
   * 스튜디오가 `notify-saved-v1` capability를 광고하지 않으면(구버전 또는
   * legacy 폴백 연결) 요청을 보내지 않고 명시적으로 실패합니다.
   *
   * @param fileName - 호스트가 저장에 사용한 파일 이름 (선택)
   * @returns {Promise<{ ok: true, wasDirty: boolean }>}
   */
  async notifySaved(fileName) {
    if (!this._transport.supports('notify-saved-v1')) {
      throw new Error('notifySaved is not supported by this Studio');
    }
    const params = typeof fileName === 'string' && fileName.length > 0 ? { fileName } : {};
    return this._request('notifySaved', params);
  }

  /**
   * iframe 엘리먼트를 반환합니다.
   */
  get element() {
    return this._iframe;
  }

  /**
   * 에디터를 제거합니다.
   */
  destroy() {
    this._transport.destroy();
    this._iframe.remove();
  }
}
